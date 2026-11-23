//
//  CarPlaySceneDelegate.swift
//  DashMirror
//
//  Das Autodisplay als ganz normales UIKit-Fenster (keine CarPlay-Vorlagen). Voraussetzung sind BEIDE
//  Freigaben im Profil: com.apple.developer.carplay-video UND carplay-audio – mit "video" allein laeuft
//  die App am iPhone, erscheint im Auto aber ohne jede Fehlermeldung nie (cafari-lite und eigene Tests).
//
//  Die Rolle "UIWindowSceneSessionRoleCarPlay" exportiert UIKit, nennt sie in Swift aber nicht –
//  deshalb steht sie nur als Text im Info.plist und hier als `carPlayWindowRole`.
//

import UIKit

let carPlayWindowRole = UISceneSession.Role(rawValue: "UIWindowSceneSessionRoleCarPlay")

final class CarPlaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var hub: MirrorHub { MirrorHub.shared }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else {
            MirrorLog.write("CarPlay FEHLER: Szene ist keine UIWindowScene (\(type(of: scene)))")
            return
        }
        let screen = windowScene.screen
        MirrorLog.write("CarPlay verbunden – Rolle \(session.role == carPlayWindowRole ? "CarPlay-Fenster" : session.role.rawValue), "
                        + "Display \(Int(screen.bounds.width))x\(Int(screen.bounds.height)) pt @\(screen.scale)x, "
                        + "nativ \(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height)) px, "
                        + "max \(screen.maximumFramesPerSecond) Hz")
        hub.start()
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = CarMirrorViewController()
        window.makeKeyAndVisible()
        self.window = window
        hub.carDidConnect()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        MirrorLog.write("CarPlay getrennt")
        hub.carDidDisconnect()
        window = nil
    }

    // Wechselt man im Auto zu Karten oder aufs Dashboard, ist das Fenster weg: dann nicht weiter dekodieren.
    func sceneWillEnterForeground(_ scene: UIScene) {
        MirrorLog.write("CarPlay-Fenster im Vordergrund")
        hub.setCarForeground(true)
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        MirrorLog.write("CarPlay-Fenster im Hintergrund")
        hub.setCarForeground(false)
    }
}
