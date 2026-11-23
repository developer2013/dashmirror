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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(MirrorHub.shared)
                .preferredColorScheme(.dark)
        }
    }
}
