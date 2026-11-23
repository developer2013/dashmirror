//
//  DrivingPolicy.swift
//  DashMirror
//
//  DIE Regel der Fahrsperre: Darf das gespiegelte Bild gerade auf dem Autodisplay zu sehen sein?
//  Wird jede Sekunde mit frischen Messwerten aufgerufen (DrivingLockMonitor) und blendet bei `true`
//  das Bild im Auto sofort aus (kein eingefrorenes Standbild).
//
//  Bewusst eine eigene, kleine Datei: Hier steckt keine Technik, sondern eine Abwaegung –
//  Sicherheit und Rechtslage gegen "das Bild verschwindet an jeder roten Ampel".
//
//  Festgelegt vom Nutzer am 23.11.2026 (vorher Platzhalter "immer sperren"): sofort sperren, sobald GPS
//  Fahrt meldet; erst nach 5 s Stillstand wieder freigeben; ohne genauen Standort oder ohne verlaessliches
//  GPS bleibt es gesperrt. Nicht ohne Ruecksprache lockern.
//

import Foundation

nonisolated enum DrivingPolicy {
    /// So lange muss das Auto stehen, bevor das Bild zurueckkommt – gegen Flackern beim Anfahren und im Stau.
    static let unlockAfterSeconds: TimeInterval = 5

    /// - Parameters:
    ///   - s: aktuelle Messwerte (Erklaerung der Felder in DrivingSignals).
    ///   - wasLocked: Ergebnis der letzten Sekunde – fuer die Hysterese: sofort sperren, aber erst nach einer
    ///     Weile Stillstand wieder freigeben.
    /// - Returns: true = gesperrt, Bild im Auto aus.
    static func shouldLock(_ s: DrivingSignals, wasLocked: Bool) -> Bool {
        // Fail-closed: ohne genaue Standortfreigabe oder ohne frischen, genauen GPS-Wert bleibt das Bild aus.
        guard !s.locationUnavailable, let speed = s.trustedSpeedKmh else { return true }
        // Faehrt: sofort sperren.
        if speed > DrivingSignals.movingKmh { return true }
        // Steht: War es gesperrt, erst freigeben, wenn die letzte Bewegung lange genug her ist.
        // nil = seit dem Start keine Bewegung gesehen (z. B. App im geparkten Auto gestartet).
        if wasLocked, let since = s.secondsSinceMoving, since < unlockAfterSeconds { return true }
        return false
    }
}
