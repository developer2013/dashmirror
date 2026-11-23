//
//  AppLanguage.swift
//  DashMirror
//
//  Sprachwahl in der App (System / English / Deutsch). iOS legt die Sprache einer App beim Start fest –
//  die Wahl wird deshalb erst beim naechsten Start wirksam.
//
//  Technik: Die App schreibt "AppleLanguages" in ihre eigenen Einstellungen. Denselben Eintrag setzt iOS,
//  wenn man die Sprache unter Einstellungen › Apps › DashMirror waehlt – beide Wege vertragen sich also.
//  "System" entfernt den Eintrag wieder; dann gilt die Sprache des iPhones.
//

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case german = "de"

    var id: String { rawValue }

    /// Sprachnamen in ihrer eigenen Sprache, wie in den iOS-Einstellungen – so findet man seine Sprache immer.
    var title: String {
        switch self {
        case .system:  String(localized: "System")
        case .english: "English"
        case .german:  "Deutsch"
        }
    }

    private static let key = "appLanguage"

    /// Die gespeicherte Wahl.
    static var selected: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
    }

    /// Die Wahl, mit der diese App-Sitzung gestartet ist – weicht die aktuelle davon ab, braucht es einen Neustart.
    static let atLaunch = selected

    static func select(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        defaults.set(language.rawValue, forKey: key)
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
        MirrorLog.write("Sprache gewaehlt: \(language.rawValue) (wirkt nach dem naechsten App-Start)")
    }
}
