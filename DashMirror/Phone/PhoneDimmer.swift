//
//  PhoneDimmer.swift
//  DashMirror
//
//  Option "iPhone abdunkeln": Laeuft die Spiegelung ins Auto und ist am iPhone eine andere App vorn (Video,
//  Spiel), dreht DashMirror die Helligkeit des iPhones auf 2 %. Das Bild im Auto bleibt hell – ReplayKit nimmt
//  den Bildinhalt auf, nicht die Hintergrundbeleuchtung (wie Screenshots). Im Auto noch zu bestaetigen.
//
//  Anders als RetroGames (schwarzer Bildschirm + 2 %) geht hier NUR die Helligkeit: Der iPhone-Bildschirm ist
//  die Quelle der Spiegelung, ein schwarzer Bildschirm kaeme auch im Auto schwarz an.
//
//  Wie bei RetroGames/PhoneDimmer: iOS setzt eine von einer App gesetzte Helligkeit erst beim naechsten Sperren
//  zurueck – deshalb merken und wiederherstellen. Abgedunkelt wird beim Verlassen von DashMirror (Szene wird
//  inaktiv, die App darf da noch), wiederhergestellt beim Zurueckkommen oder wenn Spiegelung/Auto enden.
//  Ob iOS das Zuruecksetzen aus dem Hintergrund annimmt, ist ungeprueft: Klappt es nicht (Kontrollwert weicht ab),
//  bleibt der alte Wert gemerkt und wird beim naechsten Oeffnen von DashMirror gesetzt.
//

import Observation
import UIKit

final class PhoneDimmer {
    static let shared = PhoneDimmer()
    /// Wie RetroGames: praktisch dunkel, aber noch erkennbar, dass das iPhone an ist.
    static let dimmedBrightness: CGFloat = 0.02

    private let hub = MirrorHub.shared
    /// Helligkeit vor dem Abdunkeln; nil = nicht abgedunkelt (bzw. schon wiederhergestellt).
    private var saved: CGFloat?
    /// DashMirror ist am iPhone vorn und aktiv.
    private var phoneActive = true
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] note in
            let isPhone = (note.object as? UIScene)?.session.role == .windowApplication
            MainActor.assumeIsolated { if isPhone { self?.setPhoneActive(true) } }
        }
        center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] note in
            let isPhone = (note.object as? UIScene)?.session.role == .windowApplication
            MainActor.assumeIsolated { if isPhone { self?.setPhoneActive(false) } }
        }
        observe()
    }

    /// Abdunkeln nur, solange jemand das Bild im Auto sieht und eine andere App vorn ist.
    private var shouldDim: Bool {
        hub.dimPhone && hub.source == .screen && hub.carConnected && !phoneActive
    }

    private func setPhoneActive(_ active: Bool) {
        guard active != phoneActive else { return }
        phoneActive = active
        update()
    }

    private func observe() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.observe() }
        }
    }

    private func update() {
        if shouldDim { dim() } else { restore() }
    }

    /// Bildschirm des iPhone-Fensters (nicht des Autos). Ohne iPhone-Fenster (App nur von CarPlay gestartet)
    /// gibt es keinen Zugriff – dann bleibt die Helligkeit, wie sie ist.
    private var phoneScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication }?.screen
    }

    private func dim() {
        guard saved == nil, let screen = phoneScreen else { return }
        let before = screen.brightness
        saved = before
        screen.brightness = Self.dimmedBrightness
        MirrorLog.write(String(format: "iPhone abgedunkelt: Helligkeit %.2f -> %.2f (gemessen %.2f)",
                               before, Self.dimmedBrightness, screen.brightness))
    }

    private func restore() {
        guard let value = saved, let screen = phoneScreen else { return }
        screen.brightness = value
        let measured = screen.brightness
        if abs(measured - value) < 0.02 {
            saved = nil
            MirrorLog.write(String(format: "iPhone-Helligkeit zurueck: %.2f", value))
        } else {
            // Gemerkten Wert behalten: beim naechsten Oeffnen von DashMirror erneut (siehe Kopfkommentar).
            MirrorLog.write(String(format: "iPhone-Helligkeit noch nicht zurueck (soll %.2f, gemessen %.2f) – "
                                   + "wird beim naechsten Oeffnen von DashMirror gesetzt", value, measured))
        }
    }
}
