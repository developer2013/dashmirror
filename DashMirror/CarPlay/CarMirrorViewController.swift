//
//  CarMirrorViewController.swift
//  DashMirror
//
//  Inhalt des Autodisplays: das gespiegelte iPhone-Bild im sicheren Bereich (die CarPlay-Seitenleiste
//  verdeckt sonst einen Streifen), darueber Hinweise, wenn nichts kommt oder die Fahrsperre greift.
//
//  Tippen schaltet das Bildformat durch (Einpassen -> Fuellen -> Strecken). Lange druecken blendet
//  Messwerte ein. Beruehrungen gehen NICHT ans Spiel – das steuert man per Controller am iPhone.
//

import AVFoundation
import Observation
import UIKit

final class CarMirrorViewController: UIViewController {
    private let hub = MirrorHub.shared
    private let videoView = MirrorVideoView()
    private let message = UIStackView()
    private let messageIcon = UIImageView()
    private let messageTitle = UILabel()
    private let messageText = UILabel()
    private let hud = UILabel()
    private let toast = UILabel()
    private let testWarning = UILabel()
    private var attached = false
    private var showsHUD = false
    private var toastWork: DispatchWorkItem?
    private var lastPixelSize: CGSize = .zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(videoView)

        messageIcon.tintColor = .white
        messageIcon.contentMode = .scaleAspectFit
        messageIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .semibold)
        messageTitle.font = .systemFont(ofSize: 24, weight: .bold)
        messageTitle.textColor = .white
        messageTitle.textAlignment = .center
        messageTitle.numberOfLines = 0
        messageText.font = .systemFont(ofSize: 17)
        messageText.textColor = UIColor(white: 1, alpha: 0.7)
        messageText.textAlignment = .center
        messageText.numberOfLines = 0
        message.axis = .vertical
        message.alignment = .center
        message.spacing = 10
        [messageIcon, messageTitle, messageText].forEach(message.addArrangedSubview)
        message.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(message)

        for label in [hud, toast] {
            label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            label.textColor = .white
            label.backgroundColor = UIColor(white: 0.1, alpha: 0.8)
            label.layer.cornerRadius = 10
            label.layer.masksToBounds = true
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isHidden = true
            view.addSubview(label)
        }
        toast.font = .systemFont(ofSize: 18, weight: .semibold)

        // Dauerhafter Hinweis, solange die Fahrsperre per Test-Startargument aus ist.
        testWarning.text = "  Fahrsperre AUS – nur Test  "
        testWarning.font = .systemFont(ofSize: 13, weight: .bold)
        testWarning.textColor = .black
        testWarning.backgroundColor = .systemOrange
        testWarning.layer.cornerRadius = 8
        testWarning.layer.masksToBounds = true
        testWarning.translatesAutoresizingMaskIntoConstraints = false
        testWarning.isHidden = !hub.driving.lockDisabledForTesting
        view.addSubview(testWarning)

        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            videoView.topAnchor.constraint(equalTo: safe.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),

            message.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, multiplier: 0.85),

            hud.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10),
            hud.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -10),

            toast.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            toast.topAnchor.constraint(equalTo: safe.topAnchor, constant: 14),

            testWarning.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            testWarning.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
        ])

        view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        view.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:))))
        observe()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Pixelgroesse der Spielflaeche an die Erweiterung melden: Sie kodiert dann genau so gross.
        let scale = view.window?.windowScene?.screen.scale ?? traitCollection.displayScale
        let pixels = CGSize(width: (videoView.bounds.width * scale).rounded(),
                            height: (videoView.bounds.height * scale).rounded())
        guard pixels != lastPixelSize, pixels.width > 0 else { return }
        lastPixelSize = pixels
        let insets = view.safeAreaInsets
        MirrorLog.write("Autodisplay: Fenster \(Int(view.bounds.width))x\(Int(view.bounds.height)) pt, sicherer Rand "
                        + "oben \(Int(insets.top)) links \(Int(insets.left)) unten \(Int(insets.bottom)) "
                        + "rechts \(Int(insets.right)), Bildflaeche \(Int(pixels.width))x\(Int(pixels.height)) px")
        hub.setCarPixelSize(pixels)
    }

    // MARK: Zustand

    private func observe() {
        withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.observe() }
        }
    }

    private func refresh() {
        let locked = hub.driving.isLocked
        let streaming = hub.sourceConnected
        let visible = hub.carForeground && !locked
        setAttached(visible)
        videoView.isHidden = !visible || !streaming
        videoView.orientation = hub.orientation
        videoView.fit = hub.fit

        if locked {
            showMessage(symbol: "car.fill", title: "Während der Fahrt ausgeblendet",
                        text: "Das Bild erscheint wieder, sobald das Auto steht.")
        } else if !streaming {
            showMessage(symbol: "rectangle.on.rectangle",
                        title: "Warte auf die Übertragung",
                        text: "Am iPhone „DashMirror“ öffnen › „Spiegelung starten“\n"
                            + "oder Kontrollzentrum › Bildschirmaufnahme gedrückt halten › „DashMirror“.")
        } else {
            message.isHidden = true
        }

        hud.isHidden = !showsHUD
        if showsHUD {
            let latency = hub.latencyMs.map { String(format: "%.0f ms", $0) } ?? "–"
            hud.text = String(format: "  %.0f B/s · %.1f Mbit/s · %@ · %dx%d · %@  ",
                              hub.framesPerSecond, hub.megabitsPerSecond, latency,
                              Int(hub.frameSize.width), Int(hub.frameSize.height), hub.fit.title)
        }
    }

    /// Bei Fahrsperre und im Hintergrund wird die Anzeige abgemeldet und geleert – es bleibt kein
    /// eingefrorenes Standbild stehen, und der Decoder arbeitet nicht umsonst.
    private func setAttached(_ on: Bool) {
        guard on != attached else { return }
        attached = on
        if on {
            hub.attach(videoView.renderer)
        } else {
            hub.detach(videoView.renderer)
            videoView.renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
    }

    private func showMessage(symbol: String, title: String, text: String) {
        messageIcon.image = UIImage(systemName: symbol)
        messageTitle.text = title
        messageText.text = text
        message.isHidden = false
    }

    // MARK: Beruehrung

    @objc private func tapped() {
        hub.fit = hub.fit.next
        showToast("Bild: \(hub.fit.title)")
        MirrorLog.write("Autodisplay: Bildformat \(hub.fit.rawValue)")
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        showsHUD.toggle()
        refresh()
    }

    private func showToast(_ text: String) {
        toast.text = "   \(text)   "
        toast.isHidden = false
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast.isHidden = true }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }
}
