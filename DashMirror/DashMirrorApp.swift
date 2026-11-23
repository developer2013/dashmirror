//
//  DashMirrorApp.swift
//  DashMirror
//
//  Spiegelt den iPhone-Bildschirm (jede App, z. B. ein Spiel mit Bluetooth-Controller) aufs Autodisplay:
//  ReplayKit-Broadcast-Erweiterung (MirrorBroadcast) -> H.264 ueber Unix-Socket -> CarPlay-Fenster.
//  Aufbau und Regeln: README.md und AGENTS.md.
//

import SwiftUI

@main
struct DashMirrorApp: App {
    init() {
        let info = Bundle.main.infoDictionary
        MirrorLog.write("=== App gestartet: DashMirror \(info?["CFBundleShortVersionString"] as? String ?? "?") "
                        + "(\(info?["CFBundleVersion"] as? String ?? "?")), \(UIDevice.current.model) "
                        + "iOS \(UIDevice.current.systemVersion) ===")
        MirrorHub.shared.start()
    }

    @State private var language = LanguageStore.shared

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "MirrorCarPreview") {
                CarPreview().ignoresSafeArea()
            } else {
                phoneUI
            }
            #else
            phoneUI
            #endif
        }
    }

    private var phoneUI: some View {
        ContentView()
            .environment(MirrorHub.shared)
            .environment(language)
            // Sprachwahl wirkt sofort: SwiftUI schlaegt feste Texte in dieser Locale nach.
            .environment(\.locale, language.locale)
            .preferredColorScheme(.dark)
    }
}

#if DEBUG
/// Test-Hilfe: `-MirrorCarPreview YES` zeigt das Autofenster im iPhone-Fenster – so lassen sich Leiste,
/// unscharfer Hintergrund und Nachtmodus im Simulator ansehen, ohne CarPlay-Display.
private struct CarPreview: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> CarMirrorViewController {
        MirrorHub.shared.carDidConnect()
        return CarMirrorViewController()
    }

    func updateUIViewController(_ controller: CarMirrorViewController, context: Context) {}
}
#endif
