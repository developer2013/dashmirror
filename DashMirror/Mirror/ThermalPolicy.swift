//
//  ThermalPolicy.swift
//  DashMirror
//
//  Hitzeschutz: Im Sommer wird das iPhone im Auto heiss (Sonne, Laden, Spiel und Kodieren gleichzeitig).
//  Erreicht es "serious", drosselt iOS selbst – ruckartig und fuer das Spiel gleich mit. Wir senken vorher
//  unsere eigene Last: weniger Pixel und Daten pro Bild, bei "critical" auch weniger Bilder.
//
//  Bewusst eine eigene kleine Regel: Was man zuerst opfert, ist Geschmackssache. Fuer Spiele zaehlen
//  fluessige 60 fps meist mehr als Schaerfe auf dem ohnehin kleinen Autodisplay – deshalb faellt die
//  Bildrate erst ganz zum Schluss. Wer es anders will, aendert nur diese Funktion.
//

import Foundation

enum ThermalPolicy {
    static func adjust(_ settings: MirrorSettings, for state: ProcessInfo.ThermalState) -> MirrorSettings {
        var reduced = settings
        switch state {
        case .serious:
            reduced.maxLongSide = even(settings.maxLongSide * 3 / 4)
            reduced.maxShortSide = even(settings.maxShortSide * 3 / 4)
            reduced.bitrate = min(settings.bitrate, 8_000_000)
        case .critical:
            reduced.maxLongSide = even(settings.maxLongSide * 2 / 3)
            reduced.maxShortSide = even(settings.maxShortSide * 2 / 3)
            reduced.bitrate = min(settings.bitrate, 6_000_000)
            reduced.frameRate = min(settings.frameRate, 30)
        default:
            break       // nominal, fair: nichts tun – "fair" ist im Auto der Normalfall
        }
        return reduced
    }

    /// H.264 mit 4:2:0 braucht gerade Kantenlaengen.
    private static func even(_ value: Int) -> Int { value & ~1 }
}

extension ProcessInfo.ThermalState {
    /// Fuers Protokoll (fest, ohne Uebersetzung).
    var logName: String {
        switch self {
        case .nominal: "normal"
        case .fair: "warm"
        case .serious: "heiss"
        case .critical: "kritisch"
        @unknown default: "unbekannt"
        }
    }

    var title: String {
        switch self {
        case .nominal: String(localized: "normal", bundle: .ui)
        case .fair: String(localized: "warm", bundle: .ui)
        case .serious: String(localized: "hot", bundle: .ui)
        case .critical: String(localized: "very hot", bundle: .ui)
        @unknown default: String(localized: "unknown", bundle: .ui)
        }
    }
}
