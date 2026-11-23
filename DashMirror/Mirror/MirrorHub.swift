//
//  MirrorHub.swift
//  DashMirror
//
//  Zentrale der App: haelt den Empfang (Socket-Server + Pipeline), kennt das Autodisplay, die Fahrsperre
//  und die Einstellungen – und stellt alles beobachtbar fuer iPhone-Oberflaeche und Autodisplay bereit.
//  Wird beim App-Start UND beim Verbinden der CarPlay-Szene gestartet: Im Auto startet iOS die App oft
//  direkt fuer die CarPlay-Szene, ohne dass das iPhone-Fenster je erscheint.
//

import AVFoundation
import ImageIO
import Observation
import UIKit

/// Wie das gespiegelte Bild das Autodisplay fuellt.
enum MirrorFit: String, CaseIterable {
    case fit, fill, stretch

    var title: String {
        switch self {
        case .fit:     String(localized: "Fit", bundle: .ui)
        case .fill:    String(localized: "Fill (zoom)", bundle: .ui)
        case .stretch: String(localized: "Stretch", bundle: .ui)
        }
    }

    var gravity: AVLayerVideoGravity {
        switch self {
        case .fit:     .resizeAspect
        case .fill:    .resizeAspectFill
        case .stretch: .resize
        }
    }

    var next: MirrorFit {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

@Observable
final class MirrorHub {
    static let shared = MirrorHub()

    // MARK: Empfang
    private(set) var sourceConnected = false
    private(set) var source: MirrorSource?
    private(set) var framesPerSecond: Double = 0
    private(set) var megabitsPerSecond: Double = 0
    private(set) var droppedPerSecond: Double = 0
    private(set) var latencyMs: Double?
    private(set) var frameSize: CGSize = .zero
    private(set) var orientation: CGImagePropertyOrientation = .up
    private(set) var receiverError: String?

    // MARK: Auto
    private(set) var carConnected = false
    private(set) var carForeground = false
    private(set) var carPixelSize: CGSize = .zero

    // MARK: Einstellungen
    var fit = MirrorFit(rawValue: UserDefaults.standard.string(forKey: "mirrorFit") ?? "") ?? .fit {
        didSet { UserDefaults.standard.set(fit.rawValue, forKey: "mirrorFit") }
    }
    var frameRate = MirrorSettings.load().frameRate {
        didSet { if frameRate != oldValue { settingsChanged() } }
    }
    var bitrateMbps = MirrorSettings.load().bitrate / 1_000_000 {
        didSet { if bitrateMbps != oldValue { settingsChanged() } }
    }
    /// Schwarze Raender im iPhone-Bild abschneiden (macht die Erweiterung vor dem Kodieren).
    var autoCrop = MirrorSettings.load().autoCrop {
        didSet { if autoCrop != oldValue { settingsChanged() } }
    }

    /// Zoom im Auto (1 = Bildformat wie gewaehlt, bis 4). Reine Darstellung, aendert nichts am Strom.
    var zoom = UserDefaults.standard.object(forKey: "mirrorZoom") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(zoom, forKey: "mirrorZoom") }
    }
    /// Ausschnitt beim Zoomen, je Achse -1...1 (Anteil der moeglichen Verschiebung) – passt so auch nach
    /// Wechsel von Zoom, Bildformat oder Display.
    var panFraction = CGPoint(x: UserDefaults.standard.double(forKey: "mirrorPanX"),
                              y: UserDefaults.standard.double(forKey: "mirrorPanY")) {
        didSet {
            UserDefaults.standard.set(panFraction.x, forKey: "mirrorPanX")
            UserDefaults.standard.set(panFraction.y, forKey: "mirrorPanY")
        }
    }

    func resetZoom() {
        zoom = 1
        panFraction = .zero
    }

    private(set) var testPatternRunning = false
    let driving = DrivingLockMonitor()

    @ObservationIgnored let pipeline = MirrorPipeline()
    @ObservationIgnored private var receiver: MirrorReceiver?
    @ObservationIgnored private var testPattern: TestPattern?
    @ObservationIgnored private var statsTimer: Timer?
    @ObservationIgnored private var lastStats = CACurrentMediaTime()
    @ObservationIgnored private var reportSeconds: Double = 0
    /// Summen ueber das 10-s-Protokollfenster (die Anzeige oben zeigt nur die letzten 0,5 s).
    @ObservationIgnored private var reportTotals = MirrorPipeline.Stats()
    @ObservationIgnored private var started = false

    private init() {}

    /// Was der Encoder bekommt: Bildrate/Bitrate vom iPhone, Groesse vom Autodisplay (falls verbunden).
    var effectiveSettings: MirrorSettings {
        var settings = MirrorSettings.standard
        settings.frameRate = frameRate
        settings.bitrate = bitrateMbps * 1_000_000
        settings.autoCrop = autoCrop
        if carPixelSize.width > 0, carPixelSize.height > 0 {
            settings.maxLongSide = min(settings.maxLongSide, Int(max(carPixelSize.width, carPixelSize.height)))
            settings.maxShortSide = min(settings.maxShortSide, Int(min(carPixelSize.width, carPixelSize.height)))
        }
        return settings
    }

    func start() {
        guard !started else { return }
        started = true
        guard let path = Mirror.socketPath else {
            receiverError = String(format: String(localized: "App Group %@ missing", bundle: .ui), Mirror.appGroup)
            MirrorLog.write("FEHLER: \(receiverError!)")
            return
        }
        let receiver = MirrorReceiver(path: path)
        let pipeline = pipeline
        pipeline.requestKeyframe = { receiver.send(.requestKeyframe) }
        pipeline.onOrientation = { raw in
            Task { @MainActor in
                MirrorHub.shared.orientation = CGImagePropertyOrientation(rawValue: UInt32(raw)) ?? .up
                MirrorLog.write("Ausrichtung der Quelle: \(raw)")
            }
        }
        pipeline.onHello = { source in
            Task { @MainActor in MirrorHub.shared.sourceIdentified(source) }
        }
        pipeline.onDimensions = { width, height in
            Task { @MainActor in MirrorHub.shared.frameSize = CGSize(width: width, height: height) }
        }
        receiver.onMessage = { client, header, payload in
            pipeline.handle(client: client, header: header, payload: payload)
        }
        receiver.onClient = { client, connected in
            if connected { pipeline.reset(client: client) }
            Task { @MainActor in MirrorHub.shared.sourceChanged(connected: connected) }
        }
        receiverError = receiver.start()
        self.receiver = receiver
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { MirrorHub.shared.refreshStats() }
        }
        #if DEBUG
        // Test-Hilfe: `-MirrorTestPattern YES` startet das Testbild sofort (Simulator, CarPlay Simulator).
        if UserDefaults.standard.bool(forKey: "MirrorTestPattern") { setTestPattern(true) }
        #endif
    }

    // MARK: Anzeigen

    func attach(_ renderer: AVSampleBufferVideoRenderer) { pipeline.attach(renderer) }
    func detach(_ renderer: AVSampleBufferVideoRenderer) { pipeline.detach(renderer) }

    // MARK: Auto (von der CarPlay-Szene)

    func carDidConnect() {
        carConnected = true
        carForeground = true
        driving.acquire()
    }

    func carDidDisconnect() {
        carConnected = false
        carForeground = false
        carPixelSize = .zero
        driving.release()
        sendConfig()
    }

    func setCarForeground(_ foreground: Bool) {
        carForeground = foreground
    }

    /// Pixelgroesse der Spielflaeche im Auto – danach richtet die Erweiterung ihre Kodiergroesse aus.
    func setCarPixelSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != carPixelSize else { return }
        carPixelSize = size
        sendConfig()
    }

    // MARK: Testbild

    func setTestPattern(_ on: Bool) {
        if on, testPattern == nil {
            testPattern = TestPattern(settings: effectiveSettings)
            testPattern?.start()
        } else if !on, let testPattern {
            testPattern.stop()
            self.testPattern = nil
        }
        testPatternRunning = testPattern != nil
    }

    // MARK: Intern

    private func sourceIdentified(_ source: MirrorSource?) {
        self.source = source
        MirrorLog.write("Quelle meldet sich: \(source.map { "\($0)" } ?? "unbekannt")")
        // Sonst loesen sich Testbild und Bildschirm alle 0,5 s gegenseitig ab (beide verbinden sich neu).
        if source == .screen, testPatternRunning {
            MirrorLog.write("Bildschirm-Uebertragung loest das Testbild ab")
            setTestPattern(false)
        }
    }

    private func sourceChanged(connected: Bool) {
        sourceConnected = connected
        MirrorLog.write("Quelle \(connected ? "verbunden" : "getrennt")")
        if connected {
            sendConfig()
        } else {
            source = nil
            framesPerSecond = 0
            megabitsPerSecond = 0
            droppedPerSecond = 0
            latencyMs = nil
        }
    }

    private func settingsChanged() {
        var stored = MirrorSettings.load()
        stored.frameRate = frameRate
        stored.bitrate = bitrateMbps * 1_000_000
        stored.autoCrop = autoCrop
        stored.save()
        sendConfig()
    }

    private func sendConfig() {
        let settings = effectiveSettings
        receiver?.send(.configure, payload: settings.payload)
        MirrorLog.write("Vorgaben an die Quelle: \(settings)")
    }

    private func refreshStats() {
        let now = CACurrentMediaTime()
        let seconds = max(now - lastStats, 0.001)
        lastStats = now
        let stats = pipeline.takeStats()
        let fps = Double(stats.frames) / seconds
        let mbit = Double(stats.bytes) * 8 / seconds / 1_000_000
        let dropped = Double(stats.dropped) / seconds
        let latency = stats.latencySamples > 0
            ? Double(stats.latencyTotal) / Double(stats.latencySamples) / 1_000_000 : nil
        // Nur bei Aenderung zuweisen, sonst zeichnen iPhone und Auto zweimal pro Sekunde umsonst neu.
        if abs(fps - framesPerSecond) >= 0.5 { framesPerSecond = fps }
        if abs(mbit - megabitsPerSecond) >= 0.05 { megabitsPerSecond = mbit }
        if dropped != droppedPerSecond { droppedPerSecond = dropped }
        if let latency, abs(latency - (latencyMs ?? -100)) >= 1 { latencyMs = latency }

        reportSeconds += seconds
        reportTotals.frames += stats.frames
        reportTotals.bytes += stats.bytes
        reportTotals.dropped += stats.dropped
        reportTotals.latencyTotal += stats.latencyTotal
        reportTotals.latencySamples += stats.latencySamples
        if reportSeconds >= 10, sourceConnected {
            let totals = reportTotals
            let window = reportSeconds
            reportSeconds = 0
            reportTotals = MirrorPipeline.Stats()
            let averageLatency = totals.latencySamples > 0
                ? String(format: "%.0f ms", Double(totals.latencyTotal) / Double(totals.latencySamples) / 1_000_000) : "–"
            // ReplayKit liefert nur bei Bildaenderung – stiller Bildschirm = wenige Bilder, das ist kein Fehler.
            MirrorLog.write(String(format: "Empfang (10 s): %.1f B/s, %.1f Mbit/s, Latenz %@, verworfen %.1f/s, %@, "
                                   + "Auto %@, Fahrsperre %@",
                                   Double(totals.frames) / window, Double(totals.bytes) * 8 / window / 1_000_000,
                                   averageLatency, Double(totals.dropped) / window,
                                   "\(Int(frameSize.width))x\(Int(frameSize.height))",
                                   carConnected ? (carForeground ? "vorn" : "hinten") : "nein",
                                   driving.isLocked ? "AN" : "aus"))
        }
    }
}
