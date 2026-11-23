//
//  DrivingLockMonitor.swift
//  DashMirror
//
//  Sammelt jede Sekunde, was iPhone ueber die Fahrt weiss (GPS-Geschwindigkeit, Bewegungs-Coprozessor),
//  und fragt DrivingPolicy, ob das Bild im Auto aus sein muss. Startet gesperrt (fail-closed):
//  Erst eine Auswertung mit Messwerten kann freigeben.
//
//  Laeuft nur, solange jemand es braucht (CarPlay verbunden oder iPhone-Oberflaeche vorn) – GPS in
//  bester Genauigkeit kostet Akku.
//

import CoreLocation
import CoreMotion
import Observation

/// Was die Fahrsperre jede Sekunde weiss. Alles optional bzw. konservativ vorbelegt: fehlende Daten
/// sollen nie wie "steht" aussehen.
nonisolated struct DrivingSignals: Equatable, CustomStringConvertible {
    /// GPS-Geschwindigkeit in km/h. nil = unbekannt (kein frischer Fix, Tunnel, Parkhaus, keine Freigabe).
    var speedKmh: Double?
    /// Bewegungs-Coprozessor erkennt "im Auto". Bleibt an der Ampel oft true.
    var automotive = false
    /// Bewegungs-Coprozessor erkennt "steht still".
    var stationary = false
    /// Sicherheit der Bewegungs-Erkennung: 0 niedrig, 1 mittel, 2 hoch.
    var motionConfidence = 0
    /// Sekunden seit der letzten erkannten Bewegung. "Bewegung" = GPS schneller als 7 km/h ODER
    /// Coprozessor sagt "Auto, steht nicht" mit mindestens mittlerer Sicherheit. nil = seit Start keine.
    var secondsSinceMoving: TimeInterval?
    /// Standortfreigabe fehlt, ist verweigert oder nur ungefaehr.
    var locationUnavailable = true

    var description: String {
        let speed = speedKmh.map { String(format: "%.0f km/h", $0) } ?? "? km/h"
        let since = secondsSinceMoving.map { String(format: "%.0f s", $0) } ?? "nie"
        return "\(speed), Auto \(automotive ? "ja" : "nein"), steht \(stationary ? "ja" : "nein") "
            + "(Sicherheit \(motionConfidence)), Bewegung vor \(since)\(locationUnavailable ? ", OHNE Standort" : "")"
    }
}

@Observable
final class DrivingLockMonitor: NSObject, CLLocationManagerDelegate {
    private(set) var isLocked = true
    private(set) var signals = DrivingSignals()
    private(set) var authorization: CLAuthorizationStatus = .notDetermined
    private(set) var isRunning = false
    let motionAvailable = CMMotionActivityManager.isActivityAvailable()

    /// Test am Schreibtisch (CarPlay Simulator): Startargument `-MirrorNoDrivingLock YES`, NUR in Debug-Builds.
    /// Gilt nur fuer diesen einen App-Start – startet CarPlay oder das iPhone die App normal, ist die Sperre
    /// wieder aktiv. Das Autodisplay zeigt dabei dauerhaft einen Warnhinweis.
    #if DEBUG
    let lockDisabledForTesting = UserDefaults.standard.bool(forKey: "MirrorNoDrivingLock")
    #else
    let lockDisabledForTesting = false
    #endif

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let motion = CMMotionActivityManager()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastLocation: CLLocation?
    @ObservationIgnored private var lastActivity: CMMotionActivity?
    @ObservationIgnored private var lastMoving: Date?
    @ObservationIgnored private var users = 0

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .automotiveNavigation
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
        // Braucht UIBackgroundModes "location" im Info.plist, sonst stuerzt die App hier ab.
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        authorization = locationManager.authorizationStatus
        if lockDisabledForTesting { MirrorLog.write("ACHTUNG: Fahrsperre fuer diesen Test-Start ABGESCHALTET (-MirrorNoDrivingLock)") }
    }

    /// Mehrere Nutzer (Auto, iPhone-Oberflaeche) – die Sensoren laufen, solange mindestens einer da ist.
    func acquire() {
        users += 1
        if users == 1 { startSensors() }
    }

    func release() {
        users = max(users - 1, 0)
        if users == 0 { stopSensors() }
    }

    func requestPermission() {
        locationManager.requestWhenInUseAuthorization()
    }

    private func startSensors() {
        isRunning = true
        if authorization == .notDetermined { locationManager.requestWhenInUseAuthorization() }
        locationManager.startUpdatingLocation()
        if motionAvailable {
            motion.startActivityUpdates(to: .main) { [weak self] activity in
                guard let activity else { return }
                MainActor.assumeIsolated {
                    self?.lastActivity = activity
                    self?.evaluate()
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        MirrorLog.write("Fahrsperre: Sensoren an (Standort \(Self.describe(authorization)), "
                        + "Bewegung \(motionAvailable ? "ja" : "nicht verfuegbar"))")
        evaluate()
    }

    private func stopSensors() {
        isRunning = false
        locationManager.stopUpdatingLocation()
        motion.stopActivityUpdates()
        timer?.invalidate()
        timer = nil
        MirrorLog.write("Fahrsperre: Sensoren aus")
    }

    private func evaluate() {
        let now = Date()
        var signals = DrivingSignals()
        signals.locationUnavailable = !(authorization == .authorizedWhenInUse || authorization == .authorizedAlways)
            || locationManager.accuracyAuthorization == .reducedAccuracy
        if let location = lastLocation, now.timeIntervalSince(location.timestamp) < 5,
           location.speed >= 0, location.speedAccuracy >= 0 {
            signals.speedKmh = location.speed * 3.6
        }
        if let activity = lastActivity {
            signals.automotive = activity.automotive
            signals.stationary = activity.stationary
            signals.motionConfidence = activity.confidence.rawValue
        }
        let moving = (signals.speedKmh ?? 0) > 7
            || (signals.automotive && !signals.stationary && signals.motionConfidence >= 1)
        if moving { lastMoving = now }
        signals.secondsSinceMoving = lastMoving.map { now.timeIntervalSince($0) }

        if signals != self.signals { self.signals = signals }
        let locked = lockDisabledForTesting ? false : DrivingPolicy.shouldLock(signals, wasLocked: isLocked)
        if locked != isLocked {
            isLocked = locked
            MirrorLog.write("Fahrsperre: \(locked ? "GESPERRT" : "frei") – \(signals)")
        }
    }

    // MARK: CLLocationManagerDelegate (kommt auf dem Hauptthread: dort wurde der Manager angelegt)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { lastLocation = last }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard status != authorization else { return }
            authorization = status
            MirrorLog.write("Fahrsperre: Standortfreigabe \(Self.describe(status))")
            if isRunning { locationManager.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let text = error.localizedDescription
        MainActor.assumeIsolated { MirrorLog.write("Fahrsperre: Standortfehler – \(text)") }
    }

    static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: String(localized: "not asked yet")
        case .restricted: String(localized: "restricted")
        case .denied: String(localized: "denied")
        case .authorizedAlways: String(localized: "always")
        case .authorizedWhenInUse: String(localized: "while using")
        @unknown default: String(localized: "unknown")
        }
    }
}
