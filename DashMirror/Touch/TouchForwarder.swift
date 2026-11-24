//
//  TouchForwarder.swift
//  DashMirror
//
//  Experiment "Touch im Auto" (Branch touch-prototype): Beruehrungen auf dem Autodisplay steuern die App, die
//  am iPhone vorn ist. Weg (gemessen am 24.11.2026, iPhone 16 Pro, iOS 27.0.1):
//  - Ueber LocalDevVPN (10.7.0.1) spricht DashMirror mit den Entwickler-Diensten des EIGENEN iPhones – wie
//    StikDebug. Geht mit WLAN oder bei ausgeschalteten mobilen Daten; mit mobilen Daten ohne WLAN scheitert der
//    Tunnel ("device socket io failed"), auch mit CarPlay per Kabel.
//  - Der Dienst hid.universalhidservice (Developer-Image) nimmt echte Touchscreen-Berichte an, aber nur solange
//    ein Bildstrom des displayservice laeuft. Vom Mac aus: 5/5 Tipps, auch waehrend der ReplayKit-Uebertragung.
//  Die eigentliche Arbeit macht die Rust-Bibliothek TouchBridge (TouchBridge/src/lib.rs) auf eigenem Thread.
//
//  Ohne gebaute Bibliothek (oder im Simulator) ist das hier ein leerer Platzhalter: isAvailable == false.
//  Standard: aus. Solange es aus ist, aendert sich an DashMirror nichts.
//

import Foundation
import Observation
#if TOUCHBRIDGE
import TouchBridge
#endif

@Observable
final class TouchForwarder {
    static let shared = TouchForwarder()

    enum Phase: Equatable {
        case off, connecting, ready, failed
    }

    /// LocalDevVPN leitet 10.7.0.1 an das iPhone selbst zurueck. 49152 hat StikDebug am 24.11.2026 per Bonjour
    /// gefunden (Fallback dort ebenfalls 49152).
    static let host = "10.7.0.1"
    static let port: UInt16 = 49152

    static var isAvailable: Bool {
        #if TOUCHBRIDGE
        true
        #else
        false
        #endif
    }

    /// Kopplungsdatei (Remote Pairing: public_key, private_key, identifier). Wird per Kabel abgelegt
    /// (`devicectl device copy to … --destination Documents/pairingFile.plist`) – NIE ins Repo: Sie gibt vollen
    /// Entwickler-Zugriff auf dieses iPhone.
    static var pairingFileURL: URL { URL.documentsDirectory.appendingPathComponent("pairingFile.plist") }

    var enabled = UserDefaults.standard.bool(forKey: "touchForwarding") {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: "touchForwarding")
            MirrorLog.write("Touch weiterleiten: \(enabled ? "an" : "aus")")
            if enabled { start() } else { stop() }
            // Raender abschneiden aendert die Lage des Bildes – siehe MirrorHub.requestedSettings.
            MirrorHub.shared.touchForwardingChanged()
        }
    }

    private(set) var phase: Phase = .off
    /// Letzter Schritt oder Fehler aus TouchBridge, fuer die Anzeige am iPhone.
    private(set) var status = ""

    /// Gehen Beruehrungen gerade wirklich ans iPhone?
    var isActive: Bool { enabled && phase == .ready }

    @ObservationIgnored private var poll: Task<Void, Never>?

    private init() {}

    /// Beim App-Start: War der Schalter an, gleich verbinden.
    func resume() {
        if enabled { start() }
    }

    /// Neu verbinden, z. B. nachdem LocalDevVPN eingeschaltet wurde.
    func reconnect() {
        guard enabled else { return }
        stop()
        // TouchBridge raeumt asynchron auf; kurz warten, sonst meldet der Start "laeuft schon".
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if enabled { start() }
        }
    }

    func start() {
        #if TOUCHBRIDGE
        let path = Self.pairingFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            set(.failed, String(localized: "Pairing file missing (Documents/pairingFile.plist)", bundle: .ui))
            return
        }
        let result = touchbridge_start(path, Self.host, Self.port)
        guard result == 0 || result == -2 else {
            set(.failed, "touchbridge_start \(result)")
            return
        }
        set(.connecting, String(localized: "Connecting…", bundle: .ui))
        startPolling()
        #else
        set(.failed, String(localized: "Not built in (scripts/build-touchbridge.sh)", bundle: .ui))
        #endif
    }

    func stop() {
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

    // MARK: Zustand aus TouchBridge holen

    private func set(_ newPhase: Phase, _ text: String) {
        if newPhase != phase || text != status {
            if newPhase != phase || newPhase == .failed {
                MirrorLog.write("Touch: \(newPhase) – \(text)")
            }
            phase = newPhase
            status = text
        }
    }

    #if TOUCHBRIDGE
    /// TouchBridge laeuft auf eigenem Thread; der Zustand wird zweimal pro Sekunde abgeholt (billig: zwei Atomics).
    private func startPolling() {
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let text = Self.bridgeStatus()
                switch touchbridge_state() {
                case TB_READY:
                    if self.phase != .ready { self.set(.ready, String(localized: "Ready – touches go to the iPhone", bundle: .ui)) }
                case TB_FAILED:
                    self.set(.failed, text)
                    return
                case TB_IDLE:
                    if self.phase != .off { self.set(.off, text) }
                    return
                default:
                    self.set(.connecting, text)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private static func bridgeStatus() -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        _ = touchbridge_copy_status(&buffer, buffer.count)
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
    #endif
}
