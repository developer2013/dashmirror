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

import Foundation

nonisolated enum DrivingPolicy {
    /// - Parameters:
    ///   - s: aktuelle Messwerte (Erklaerung der Felder in DrivingSignals).
    ///   - wasLocked: Ergebnis der letzten Sekunde – fuer eine Hysterese, z. B. sofort sperren,
    ///     aber erst nach einer Weile Stillstand wieder freigeben.
    /// - Returns: true = gesperrt, Bild im Auto aus.
    static func shouldLock(_ s: DrivingSignals, wasLocked: Bool) -> Bool {
        // TODO: Regel festlegen (5–10 Zeilen). Bis dahin bleibt das Bild im Auto immer aus.
        return true
    }
}
