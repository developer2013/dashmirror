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
    var fit = MirrorFit(stored: UserDefaults.standard.string(forKey: "mirrorFit")) {
        didSet {
            guard fit != oldValue else { return }
            UserDefaults.standard.set(fit.rawValue, forKey: "mirrorFit")
            // Fuer die Auswertung von Testfahrten: welches Format bei welcher Bild-/Displaygroesse lief.
            MirrorLog.write("Bildformat: \(fit.rawValue) (Bild \(Int(frameSize.width))x\(Int(frameSize.height)), "
                            + "Auto \(Int(carPixelSize.width))x\(Int(carPixelSize.height)) px)")
        }
    }
    /// Format Zoom: hoechstens so viel abschneiden (0...0,15). Reine Darstellung im Auto, aendert nichts am Strom.
    /// Protokolliert wird erst beim Loslassen des Reglers (ContentView), sonst flutet der Regler das Protokoll.
    var zoomCrop = (UserDefaults.standard.object(forKey: "mirrorZoomCrop") as? Double ?? MirrorFit.defaultZoomCrop)
        .clamped(to: MirrorFit.zoomCropRange) {
        didSet { if zoomCrop != oldValue { UserDefaults.standard.set(zoomCrop, forKey: "mirrorZoomCrop") } }
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

    /// Unscharfer Hintergrund statt schwarzer Raender (zweite Anzeige im Auto, nur solange Raender sichtbar sind).
    var ambientBackground = UserDefaults.standard.object(forKey: "mirrorAmbient") as? Bool ?? true {
        didSet {
            guard ambientBackground != oldValue else { return }
            UserDefaults.standard.set(ambientBackground, forKey: "mirrorAmbient")
            MirrorLog.write("Unscharfer Hintergrund \(ambientBackground ? "an" : "aus")")
        }
    }

    /// Nachtmodus: Bild im Auto abdunkeln (NightMode.swift).
    var nightMode = NightMode(rawValue: UserDefaults.standard.string(forKey: "mirrorNight") ?? "") ?? .auto {
        didSet {
            guard nightMode != oldValue else { return }
            UserDefaults.standard.set(nightMode.rawValue, forKey: "mirrorNight")
            MirrorLog.write("Nachtmodus: \(nightMode.rawValue)")
        }
    }
    /// iPhone abdunkeln, waehrend die Spiegelung ins Auto laeuft und eine andere App vorn ist (PhoneDimmer.swift).
    var dimPhone = UserDefaults.standard.bool(forKey: "dimPhone") {
        didSet {
            guard dimPhone != oldValue else { return }
            UserDefaults.standard.set(dimPhone, forKey: "dimPhone")
            MirrorLog.write("iPhone abdunkeln: \(dimPhone ? "an" : "aus")")
        }
    }
    /// Wie stark abgedunkelt wird (Deckkraft der schwarzen Schicht).
    var nightStrength = UserDefaults.standard.object(forKey: "mirrorNightStrength") as? Double ?? 0.35 {
        didSet { UserDefaults.standard.set(nightStrength, forKey: "mirrorNightStrength") }
    }
    /// Tag/Nacht laut Auto (Erscheinungsbild des CarPlay-Fensters); nil = kein Auto verbunden.
    private(set) var carIsDark: Bool?

    var nightDimActive: Bool {
        switch nightMode {
        case .off: false
        case .always: true
        case .auto: carIsDark == true
        }
    }

    /// Hitzeschutz (ThermalPolicy.swift): bei heissem iPhone weniger Last fuer den Encoder.
    var heatProtection = UserDefaults.standard.object(forKey: "heatProtection") as? Bool ?? true {
        didSet {
            guard heatProtection != oldValue else { return }
            UserDefaults.standard.set(heatProtection, forKey: "heatProtection")
            MirrorLog.write("Hitzeschutz \(heatProtection ? "an" : "aus")")
            sendConfig()
        }
    }
    private(set) var thermalState = MirrorHub.currentThermalState()

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
    /// Sofort-Wiederholung (fuellt den Ringpuffer der Pipeline, speichert Clips).
    @ObservationIgnored let replay: ReplayRecorder
    @ObservationIgnored private var receiver: MirrorReceiver?
    @ObservationIgnored private var testPattern: TestPattern?
    @ObservationIgnored private var statsTimer: Timer?
    @ObservationIgnored private var lastStats = CACurrentMediaTime()
    @ObservationIgnored private var reportSeconds: Double = 0
    /// Summen ueber das 10-s-Protokollfenster (die Anzeige oben zeigt nur die letzten 0,5 s).
    @ObservationIgnored private var reportTotals = MirrorPipeline.Stats()
    @ObservationIgnored private var started = false

    private init() {
        replay = ReplayRecorder(buffer: pipeline.replay)
    }

    /// Was eingestellt ist: Bildrate/Bitrate vom iPhone, Groesse vom Autodisplay (falls verbunden).
    var requestedSettings: MirrorSettings {
        var settings = MirrorSettings.standard
        settings.frameRate = frameRate
        settings.bitrate = bitrateMbps * 1_000_000
        // Touch im Auto (Experiment): Die App erfaehrt nicht, wie viel die Erweiterung abschneidet – mit Zuschnitt
        // laegen die weitergeleiteten Tipps daneben. Solange weitergeleitet wird, deshalb das ganze iPhone-Bild.
        settings.autoCrop = autoCrop && !TouchForwarder.shared.enabled
        if carPixelSize.width > 0, carPixelSize.height > 0 {
            settings.maxLongSide = min(settings.maxLongSide, Int(max(carPixelSize.width, carPixelSize.height)))
            settings.maxShortSide = min(settings.maxShortSide, Int(min(carPixelSize.width, carPixelSize.height)))
        }
        return settings
    }

    /// Was der Encoder bekommt: das Eingestellte, bei heissem iPhone gesenkt.
    var effectiveSettings: MirrorSettings {
        heatProtection ? ThermalPolicy.adjust(requestedSettings, for: thermalState) : requestedSettings
    }

    /// Senkt der Hitzeschutz gerade etwas?
    var heatReducing: Bool { effectiveSettings != requestedSettings }

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
        // Test-Hilfe: `-MirrorReplayTest 12` speichert nach 12 s einen Clip (nur Datei, ohne Fotos).
        let replayDelay = UserDefaults.standard.double(forKey: "MirrorReplayTest")
        if replayDelay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + replayDelay) {
                Task { @MainActor in
                    let outcome = await MirrorHub.shared.replay.save()
                    MirrorLog.write("Test: Clip-Ergebnis \(outcome)")
                }
            }
        }
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
        carIsDark = nil
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

    /// Tag/Nacht des Autos (vom CarPlay-Fenster, bei jedem Wechsel des Erscheinungsbilds).
    func setCarDark(_ dark: Bool) {
        guard dark != carIsDark else { return }
        carIsDark = dark
        MirrorLog.write("Autodisplay: Auto meldet \(dark ? "Nacht (dunkel)" : "Tag (hell)")")
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

    /// Touch im Auto ein/aus: Der Zuschnitt der Raender haengt daran (requestedSettings) – neu an die Quelle.
    func touchForwardingChanged() {
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

        // Temperatur: billig abzufragen; die Mitteilung von iOS kaeme im Hintergrund nicht sicher an.
        let thermal = Self.currentThermalState()
        if thermal != thermalState {
            MirrorLog.write("Hitzeschutz: iPhone \(thermalState.logName) -> \(thermal.logName)"
                            + (heatProtection ? "" : " (Hitzeschutz aus)"))
            thermalState = thermal
            if heatProtection { sendConfig() }
        }

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
                                   + "Auto %@, Fahrsperre %@, iPhone %@",
                                   Double(totals.frames) / window, Double(totals.bytes) * 8 / window / 1_000_000,
                                   averageLatency, Double(totals.dropped) / window,
                                   "\(Int(frameSize.width))x\(Int(frameSize.height))",
                                   carConnected ? (carForeground ? "vorn" : "hinten") : "nein",
                                   // Bei Sperre die Messwerte dazu – so ist eine Testfahrt ohne Mac auswertbar.
                                   driving.isLocked ? "AN (\(driving.signals))" : "aus", thermalState.logName))
        }
    }

    private static func currentThermalState() -> ProcessInfo.ThermalState {
        #if DEBUG
        // Test-Hilfe: `-MirrorThermalTest serious` – der Simulator meldet sonst immer "normal".
        switch UserDefaults.standard.string(forKey: "MirrorThermalTest") {
        case "fair": return .fair
        case "serious": return .serious
        case "critical": return .critical
        default: break
        }
        #endif
        return ProcessInfo.processInfo.thermalState
    }
}
