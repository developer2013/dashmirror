//
//  AppLanguage.swift
//  DashMirror – gemeinsam fuer App und Broadcast-Erweiterung
//
//  Sprachwahl, die SOFORT wirkt (System / English / Deutsch). iOS legt Bundle.main beim Start auf eine Sprache
//  fest; deshalb laden alle berechneten Texte ihre Uebersetzung direkt aus dem passenden Sprachpaket
//  (de.lproj / en.lproj) – `String(localized: "…", bundle: .ui)` – und SwiftUI bekommt die Sprache ueber
//  `.environment(\.locale, …)`. AppleLanguages wird nicht angefasst.
//
//  Die Wahl liegt im gemeinsamen Container: Autodisplay, Testbild und Erweiterung sprechen dieselbe Sprache.
//

import Foundation

nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case german = "de"

    static let supported = ["en", "de"]
    private static let key = "appLanguage"

    var id: String { rawValue }

    /// Sprachnamen in ihrer eigenen Sprache, wie in den iOS-Einstellungen – so findet man seine Sprache immer.
    var title: String {
        switch self {
        case .system:  String(localized: "System", bundle: .ui)
        case .english: "English"
        case .german:  "Deutsch"
        }
    }

    static var selected: AppLanguage {
        AppLanguage(rawValue: Mirror.sharedDefaults?.string(forKey: key) ?? "") ?? .system
    }

    static func select(_ language: AppLanguage) {
        Mirror.sharedDefaults?.set(language.rawValue, forKey: key)
    }

    /// Tatsaechlich verwendete Sprache: die Wahl oder, bei "System", die beste Uebereinstimmung mit den
    /// Sprachen des iPhones (inkl. der Sprachwahl pro App in den iOS-Einstellungen).
    static var code: String {
        let choice = selected
        guard choice == .system else { return choice.rawValue }
        return Bundle.preferredLocalizations(from: supported, forPreferences: Locale.preferredLanguages).first ?? "en"
    }

    static var locale: Locale { Locale(identifier: code) }

    /// Sprachpaket der gewaehlten Sprache; ohne passendes Paket (z. B. Englisch als Ausgangssprache ohne eigene
    /// Datei) Bundle.main – dann liefert die Suche den englischen Schluessel selbst.
    static var bundle: Bundle {
        let code = code
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[code] { return cached }
        let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        cache[code] = bundle
        return bundle
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bundle] = [:]

    /// Aufraeumen nach der ersten Fassung (17.11 Uhr, 23.11.2026), die AppleLanguages gesetzt hat und erst nach
    /// einem Neustart wirkte: deren Eintrag wuerde "System" sonst dauerhaft auf eine Sprache festnageln.
    static func migrate() {
        let defaults = UserDefaults.standard
        guard let old = defaults.string(forKey: key) else { return }
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: "AppleLanguages")
        if Mirror.sharedDefaults?.string(forKey: key) == nil { Mirror.sharedDefaults?.set(old, forKey: key) }
    }
}

extension Bundle {
    /// Sprachpaket der in der App gewaehlten Sprache – fuer `String(localized:bundle:)`.
    nonisolated static var ui: Bundle { AppLanguage.bundle }
}

extension Locale {
    /// Locale der gewaehlten Sprache – fuer Zahlen in der Oberflaeche (0,3 bzw. 0.3).
    nonisolated static var ui: Locale { AppLanguage.locale }
}
