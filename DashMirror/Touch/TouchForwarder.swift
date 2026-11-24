//
//  TouchForwarder.swift
//  DashMirror
//
//  Experiment "Touch im Auto": Beruehrungen auf dem Autodisplay steuern die App, die am iPhone vorn ist.
//  Weg (gemessen am 24.11.2026, iPhone 16 Pro, iOS 27.0.1, CarPlay Simulator per Kabel und BMW kabellos):
//  - Ueber LocalDevVPN (10.7.0.1) spricht DashMirror mit den Entwickler-Diensten des EIGENEN iPhones – wie
//    StikDebug. Geht mit WLAN oder bei ausgeschalteten mobilen Daten; mit mobilen Daten ohne WLAN scheitert der
//    Tunnel ("device socket io failed"), auch mit CarPlay per Kabel (Simulator). Kabelloses CarPlay zaehlt als
//    WLAN: Im BMW lief Touch mit mobilen Daten an (LTE in der CarPlay-Leiste).
//  - Der Dienst hid.universalhidservice (Developer-Image) nimmt echte Touchscreen-Berichte an, aber nur solange
//    ein Bildstrom des displayservice laeuft. Im BMW: Latenz Bildschirm -> Auto 17–21 ms (ohne Touch 12–21 ms).
//  Die eigentliche Arbeit macht die Rust-Bibliothek TouchBridge (TouchBridge/src/lib.rs) auf eigenem Thread.
//
//  Ohne gebaute Bibliothek (oder im Simulator) ist das hier ein leerer Platzhalter: isAvailable == false.
//  Standard: aus. Solange es aus ist, aendert sich an DashMirror nichts.
//
//  Neu verbinden geschieht von selbst: nach einem Abbruch mit wachsender Pause (3, 5, 10, 20, dann 30 s) und
//  sofort, sobald das Autofenster oder die App wieder vorn ist. Im BMW riss die Verbindung ab, waehrend die App
//  im Hintergrund lag (24.11.2026) – vorher musste man "Neu verbinden" tippen.
//

import Foundation
import Observation
import UIKit
#if TOUCHBRIDGE
import TouchBridge
#endif

@Observable
final class TouchForwarder {
    static let shared = TouchForwarder()

    enum Phase: Equatable {
        case off, connecting, ready, failed
    }

    /// LocalDevVPN leitet 10.7.0.1 an das iPhone selbst zurueck.
    static let host = "10.7.0.1"

    static var isAvailable: Bool {
        #if TOUCHBRIDGE
        true
        #else
        false
        #endif
    }

    /// Kopplungsdatei (Remote Pairing: public_key, private_key, identifier) – NIE ins Repo: Sie gibt vollen
    /// Entwickler-Zugriff auf dieses iPhone, auch aus demselben WLAN. Sie liegt in Application Support, nicht in
    /// Documents: Documents zeigt die Dateien-App (Clips, Logs), dort koennte sie jeder am entsperrten iPhone teilen.
    static var pairingFileURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Touch", isDirectory: true)
            .appendingPathComponent("pairingFile.plist")
    }

    /// Hier legt scripts/make-pairing-file.sh sie ab (dorthin darf devicectl schreiben). Beim naechsten Verbinden
    /// wird sie nach `pairingFileURL` verschoben – sie bleibt also nur bis zum naechsten Start sichtbar.
    static var incomingPairingFileURL: URL { URL.documentsDirectory.appendingPathComponent("pairingFile.plist") }

    var enabled = UserDefaults.standard.bool(forKey: "touchForwarding") {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: "touchForwarding")
            MirrorLog.write("Touch weiterleiten: \(enabled ? "an" : "aus")")
            if enabled {
                retryCount = 0
                connect()
            } else {
                stop()
            }
            // Raender abschneiden aendert die Lage des Bildes – siehe MirrorHub.requestedSettings.
            MirrorHub.shared.touchForwardingChanged()
        }
    }

    private(set) var phase: Phase = .off
    /// Anzeige am iPhone: uebersetzter Schritt plus Hinweis, bei Fehlern dazu die (englische) technische Meldung.
    private(set) var status = ""

    /// Gehen Beruehrungen gerade wirklich ans iPhone?
    var isActive: Bool { enabled && phase == .ready }

    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var retryCount = 0
    @ObservationIgnored private var searchedPort = false
    /// Laeuft gerade die Bonjour-Suche? Dann keinen zweiten Versuch dazwischenschieben (gemessen am 24.11.2026:
    /// Das "wieder vorn" beim App-Start startete sonst parallel einen Versuch auf dem alten Port).
    @ObservationIgnored private var discovering = false
    @ObservationIgnored private var lastLoggedFailure = ""
    /// Startargument `-TouchForwardingPort <n>` erzwingt einen Port; sonst 49152 bzw. was Bonjour findet.
    @ObservationIgnored private var port: UInt16 = {
        let forced = UserDefaults.standard.integer(forKey: "TouchForwardingPort")
        return (1...65535).contains(forced) ? UInt16(forced) : RemotePairingPort.standard
    }()

    private init() {
        // Autofenster oder iPhone-App wieder vorn: Verbindung pruefen (die Benachrichtigung kommt fuer beide Szenen).
        NotificationCenter.default.addObserver(forName: UIScene.willEnterForegroundNotification, object: nil,
                                               queue: .main) { _ in
            Task { @MainActor in TouchForwarder.shared.wake() }
        }
    }

    /// Beim App-Start: neue Kopplungsdatei sofort aus Documents holen (auch wenn der Schalter aus ist),
    /// und war der Schalter an, gleich verbinden.
    func resume() {
        Self.adoptIncomingPairingFile()
        if enabled { connect() }
    }

    /// Verschiebt eine per Skript abgelegte Kopplungsdatei aus Documents an ihren geschuetzten Platz:
    /// unsichtbar fuer die Dateien-App, Dateischutz bis zur ersten Entsperrung, nicht im Backup.
    private static func adoptIncomingPairingFile() {
        let fm = FileManager.default
        let incoming = incomingPairingFileURL
        guard fm.fileExists(atPath: incoming.path) else { return }
        var target = pairingFileURL
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: incoming, to: target)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                 ofItemAtPath: target.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try target.setResourceValues(values)
            MirrorLog.write("Touch: neue Kopplungsdatei uebernommen (aus Documents entfernt)")
        } catch {
            MirrorLog.write("Touch: Kopplungsdatei nicht uebernommen – \(error)")
        }
    }

    /// Wieder vorn: Ist die Verbindung weg, sofort neu versuchen statt die Pause abzuwarten.
    func wake() {
        guard enabled, !discovering, phase == .failed || phase == .off else { return }
        MirrorLog.write("Touch: wieder vorn – neuer Versuch")
        retryCount = 0
        connect()
    }

    /// Knopf "Neu verbinden".
    func reconnect() {
        guard enabled else { return }
        retryCount = 0
        stopBridge()
        // TouchBridge raeumt asynchron auf; kurz warten, sonst meldet der Start "laeuft schon".
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if enabled { connect() }
        }
    }

    func stop() {
        retry?.cancel()
        retry = nil
        retryCount = 0
        stopBridge()
        set(.off, "")
    }

    /// Ein Finger auf dem Autodisplay. `point`: Lage auf dem iPhone-Bildschirm im Hochformat, je Achse 0...1.
    /// `contact` false = Finger hebt ab (an der letzten Stelle).
    func send(contact: Bool, at point: CGPoint) {
        #if TOUCHBRIDGE
        guard isActive else { return }
        let x = UInt16((point.x.clamped(to: 0...1) * 65535).rounded())
        let y = UInt16((point.y.clamped(to: 0...1) * 65535).rounded())
        _ = touchbridge_touch(contact ? 1 : 0, x, y)
        #endif
    }

    // MARK: Verbinden

    private func connect() {
        retry?.cancel()
        retry = nil
        #if TOUCHBRIDGE
        Self.adoptIncomingPairingFile()
        let path = Self.pairingFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            // Kein automatischer neuer Versuch: Ohne Datei hilft Warten nicht.
            set(.failed, String(localized: "Pairing file missing – see “Touch in the car” in the README.", bundle: .ui))
            return
        }
        let result = touchbridge_start(path, Self.host, port)
        if result == -2 { return } // laeuft schon, das Abfragen laeuft weiter
        guard result == 0 else {
            set(.failed, "touchbridge_start \(result)")
            return
        }
        set(.connecting, String(localized: "Connecting…", bundle: .ui))
        startPolling()
        #else
        set(.failed, String(localized: "Not built in (scripts/build-touchbridge.sh)", bundle: .ui))
        #endif
    }

    private func stopBridge() {
        #if TOUCHBRIDGE
        if phase == .ready || phase == .connecting {
            let touches = touchbridge_touches_sent()
            let megabytes = Double(touchbridge_stream_bytes()) / 1_000_000
            MirrorLog.write(String(format: "Touch: gestoppt nach %llu Beruehrungen, Freigabe-Bildstrom %.1f MB", touches, megabytes))
        }
        touchbridge_stop()
        #endif
        poll?.cancel()
        poll = nil
    }

    private func set(_ newPhase: Phase, _ text: String) {
        guard newPhase != phase || text != status else { return }
        // Fehler nur loggen, wenn sie sich aendern – sonst schreibt das Neuverbinden alle 30 s dasselbe.
        if newPhase == .failed {
            if text != lastLoggedFailure { MirrorLog.write("Touch: Fehler – \(text.replacingOccurrences(of: "\n", with: " | "))") }
            lastLoggedFailure = text
        } else if newPhase != phase {
            MirrorLog.write("Touch: \(newPhase)")
            if newPhase == .ready { lastLoggedFailure = "" }
        }
        phase = newPhase
        status = text
    }

    /// Automatisch neu verbinden: 3, 5, 10, 20, dann alle 30 s – solange der Schalter an ist.
    private func scheduleRetry() {
        let delays = [3, 5, 10, 20, 30]
        let seconds = delays[min(retryCount, delays.count - 1)]
        retryCount += 1
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.enabled, self.phase == .failed else { return }
            self.connect()
        }
    }

    #if TOUCHBRIDGE
    /// TouchBridge laeuft auf eigenem Thread; der Zustand wird zweimal pro Sekunde abgeholt (billig: Atomics).
    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                switch touchbridge_state() {
                case TB_READY:
                    if self.phase != .ready {
                        self.retryCount = 0
                        self.searchedPort = false
                        self.set(.ready, String(localized: "Ready – touches go to the iPhone", bundle: .ui))
                    }
                case TB_FAILED:
                    self.handleFailure(step: touchbridge_step(), detail: Self.bridgeDetail())
                    return
                case TB_IDLE:
                    if self.phase != .off { self.set(.off, "") }
                    return
                default:
                    let text = Self.stepName(touchbridge_step()) + "…"
                    if self.phase != .connecting || self.status != text { self.set(.connecting, text) }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func handleFailure(step: Int32, detail: String) {
        set(.failed, Self.failureText(step: step, detail: detail))
        guard enabled else { return }
        // Liegt der Dienst vielleicht auf einem anderen Port? Einmal per Bonjour suchen, dann sofort neu.
        if step == TB_STEP_CONNECT, !searchedPort {
            searchedPort = true
            discovering = true
            Task {
                let found = await RemotePairingPort.discover()
                discovering = false
                guard enabled, phase == .failed else { return }
                if let found, found != port {
                    MirrorLog.write("Touch: Remote-Pairing-Port per Bonjour: \(found) (vorher \(port))")
                    port = found
                    connect()
                } else {
                    MirrorLog.write("Touch: Bonjour-Suche: \(found.map { "Port \($0), unveraendert" } ?? "nichts gefunden (lokales Netz erlaubt?)")")
                    scheduleRetry()
                }
            }
            return
        }
        guard !discovering else { return }
        scheduleRetry()
    }

    private static func bridgeDetail() -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        _ = touchbridge_copy_status(&buffer, buffer.count)
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func stepName(_ step: Int32) -> String {
        switch step {
        case TB_STEP_PAIRING_FILE: String(localized: "Reading the pairing file", bundle: .ui)
        case TB_STEP_CONNECT: String(localized: "Connecting through LocalDevVPN", bundle: .ui)
        case TB_STEP_VERIFY: String(localized: "Checking the pairing", bundle: .ui)
        case TB_STEP_TUNNEL: String(localized: "Opening the tunnel", bundle: .ui)
        case TB_STEP_SERVICES: String(localized: "Reading the iPhone’s services", bundle: .ui)
        case TB_STEP_SCREEN_STREAM: String(localized: "Starting the screen stream", bundle: .ui)
        case TB_STEP_TOUCH_SERVICE: String(localized: "Connecting the touch service", bundle: .ui)
        default: String(localized: "Connecting", bundle: .ui)
        }
    }

    /// Was schiefging (uebersetzt), was man tun kann, und darunter die technische Meldung.
    private static func failureText(step: Int32, detail: String) -> String {
        let headline = step == TB_STEP_RUNNING
            ? String(localized: "Connection lost.", bundle: .ui)
            : String(format: String(localized: "%@ failed.", bundle: .ui), locale: .ui, stepName(step))
        let hint: String? = switch step {
        case TB_STEP_CONNECT, TB_STEP_RUNNING:
            String(localized: "Is LocalDevVPN on? Without Wi-Fi, mobile data must be off.", bundle: .ui)
        case TB_STEP_PAIRING_FILE, TB_STEP_VERIFY:
            String(localized: "Create the pairing file again (scripts/make-pairing-file.sh).", bundle: .ui)
        case TB_STEP_SCREEN_STREAM, TB_STEP_TOUCH_SERVICE:
            String(localized: "Is the Developer Disk Image mounted? After restarting the iPhone, mount it again from a Mac.", bundle: .ui)
        default:
            nil
        }
        return [headline, hint, detail.isEmpty ? nil : detail].compactMap { $0 }.joined(separator: "\n")
    }
    #endif
}
