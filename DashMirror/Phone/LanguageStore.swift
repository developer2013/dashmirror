//
//  LanguageStore.swift
//  DashMirror
//
//  Beobachtbare Huelle um AppLanguage: Aendert sich die Wahl, zeichnen iPhone-Oberflaeche (ueber die
//  Umgebungs-Locale) und Autodisplay (ueber withObservationTracking auf `code`) sofort neu.
//

import Foundation
import Observation

@Observable
final class LanguageStore {
    static let shared = LanguageStore()

    var selection = AppLanguage.selected {
        didSet {
            guard selection != oldValue else { return }
            AppLanguage.select(selection)
            code = AppLanguage.code
            MirrorLog.write("Sprache: \(selection.rawValue) -> \(code)")
        }
    }

    /// Tatsaechlich verwendete Sprache ("en"/"de") – Abhaengigkeit fuer alles, was Texte berechnet.
    private(set) var code = AppLanguage.code

    var locale: Locale { Locale(identifier: code) }

    private init() {
        AppLanguage.migrate()
        selection = AppLanguage.selected
        code = AppLanguage.code
        #if DEBUG
        // Test-Hilfe: `-MirrorLanguageSwitchTest en` wechselt 5 s nach dem Start die Sprache – im selben Prozess,
        // um zu pruefen, dass alles ohne Neustart umschaltet (Simulator, ohne Antippen).
        if let target = UserDefaults.standard.string(forKey: "MirrorLanguageSwitchTest"),
           let language = AppLanguage(rawValue: target) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { LanguageStore.shared.selection = language }
        }
        #endif
    }
}
