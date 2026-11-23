//
//  NightMode.swift
//  DashMirror
//
//  Nachtmodus: dunkelt das Bild im Auto ab, damit helle Spiele nachts nicht blenden.
//  "Automatisch" folgt dem Tag/Nacht-Signal des Autos: CarPlay schaltet das Erscheinungsbild des Fensters
//  (traitCollection.userInterfaceStyle) nach Licht bzw. Lichtsensor um – so wie Navigations-Apps ihre
//  Karte hell/dunkel stellen. Manche Autos (oder "Immer dunkel" in den CarPlay-Einstellungen) melden
//  dauerhaft dunkel; dann wuerde auch tagsueber abgedunkelt. Das iPhone zeigt deshalb an, was das Auto meldet.
//

import Foundation

enum NightMode: String, CaseIterable, Identifiable {
    case off, auto, always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "Off", bundle: .ui)
        case .auto: String(localized: "Automatic", bundle: .ui)
        case .always: String(localized: "Always", bundle: .ui)
        }
    }

    static let strengthRange: ClosedRange<Double> = 0.15...0.7
}
