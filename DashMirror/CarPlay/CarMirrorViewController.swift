//
//  CarMirrorViewController.swift
//  DashMirror
//
//  Inhalt des Autodisplays: das gespiegelte iPhone-Bild im sicheren Bereich (die CarPlay-Seitenleiste
//  verdeckt sonst einen Streifen), darueber Hinweise, wenn nichts kommt oder die Fahrsperre greift.
//
//  Tippen blendet eine Leiste ein (Bildformat, Clip speichern, Messwerte, Zoom zuruecksetzen), die nach
//  4 s wieder verschwindet. Lange druecken speichert sofort einen Clip der letzten 30 s.
//  Beruehrungen gehen NICHT ans Spiel – das steuert man per Controller am iPhone.
//

import AVFoundation
import Observation
import UIKit

final class CarMirrorViewController: UIViewController {
    private let hub = MirrorHub.shared
    private let videoView = MirrorVideoView()
    private let nightShade = UIView()
    /// Experiment: Finger ans iPhone weitergeben (TouchForwarder). Nur aktiv, wenn bereit und das Bild sichtbar ist.
    private let touchLayer = TouchForwardView()
    private var forwardingShown = false
    private let message = UIStackView()
    private let messageIcon = UIImageView()
    private let messageTitle = UILabel()
    private let messageText = UILabel()
    private let hud = UILabel()
    private let toast = UILabel()
    private let testWarning = UILabel()
    private let controls = UIStackView()
    private let formatButton = UIButton(configuration: .filled())
    private let clipButton = UIButton(configuration: .filled())
    private let infoButton = UIButton(configuration: .filled())
    private let resetZoomButton = UIButton(configuration: .filled())
    private var attached = false
    private var backgroundAttached = false
    private var showsHUD = false
    private var toastWork: DispatchWorkItem?
    private var controlsWork: DispatchWorkItem?
    private var lastPixelSize: CGSize = .zero
    private var lastThermal = ProcessInfo.ThermalState.nominal

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        videoView.translatesAutoresizingMaskIntoConstraints = false
        videoView.onNeedsBackgroundChange = { [weak self] _ in self?.updateBackground() }
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

        // Nachtmodus: schwarze Schicht ueber Bild und Hinweisen, unter Leiste und Meldungen.
        nightShade.backgroundColor = .black
        nightShade.alpha = 0
        nightShade.isUserInteractionEnabled = false
        nightShade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(nightShade)

        // Touch ans iPhone (Experiment): ueber Bild und Nachtschicht, unter Leiste und Meldungen. Standard: aus.
        touchLayer.translatesAutoresizingMaskIntoConstraints = false
        touchLayer.isHidden = true
        touchLayer.isUserInteractionEnabled = false
        touchLayer.mapToPhone = { [weak self] point in
            guard let self else { return nil }
            return self.videoView.phonePoint(forCarPoint: self.touchLayer.convert(point, to: self.videoView))
        }
        touchLayer.onTouch = { contact, point in
            TouchForwarder.shared.send(contact: contact, at: point)
        }
        view.addSubview(touchLayer)
        NSLayoutConstraint.activate([
            touchLayer.topAnchor.constraint(equalTo: view.topAnchor),
            touchLayer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            touchLayer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            touchLayer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        for label in [hud, toast] {
            label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            label.textColor = .white
            label.backgroundColor = UIColor(white: 0.1, alpha: 0.8)
            label.layer.cornerRadius = 10
            label.layer.masksToBounds = true
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isHidden = true
            view.addSubview(label)
        }
        toast.font = .systemFont(ofSize: 18, weight: .semibold)

        // Leiste: grosse Knoepfe (Autodisplay ist nur ~240 pt hoch, man trifft waehrend des Spiels ungenau).
        for (button, symbol, action) in [(formatButton, "aspectratio", #selector(formatTapped)),
                                         (clipButton, "record.circle", #selector(clipTapped)),
                                         (infoButton, "info.circle", #selector(infoTapped)),
                                         (resetZoomButton, "arrow.down.right.and.arrow.up.left", #selector(resetZoomTapped))] {
            var configuration = UIButton.Configuration.filled()
            configuration.image = UIImage(systemName: symbol)
            configuration.imagePadding = 8
            configuration.cornerStyle = .capsule
            configuration.baseBackgroundColor = UIColor(white: 0.12, alpha: 0.88)
            configuration.baseForegroundColor = .white
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)
            configuration.titleLineBreakMode = .byTruncatingTail
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 18, weight: .semibold)
                return attributes
            }
            button.configuration = configuration
            button.addTarget(self, action: action, for: .touchUpInside)
            controls.addArrangedSubview(button)
        }
        clipButton.configuration?.baseForegroundColor = UIColor(red: 1, green: 0.38, blue: 0.35, alpha: 1)
        controls.axis = .horizontal
        controls.spacing = 12
        controls.alignment = .center
        controls.isHidden = true
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)

        // Dauerhafter Hinweis, solange die Fahrsperre per Test-Startargument aus ist.
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
            // Ganze Flaeche: der unscharfe Hintergrund laeuft unter der Seitenleiste weiter wie bei nativen
            // CarPlay-Apps. Das scharfe Bild haelt sich selbst an den sicheren Bereich (pictureInsets).
            videoView.topAnchor.constraint(equalTo: view.topAnchor),
            videoView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            nightShade.topAnchor.constraint(equalTo: view.topAnchor),
            nightShade.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            nightShade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nightShade.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            message.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            message.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, multiplier: 0.85),

            hud.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 10),
            hud.topAnchor.constraint(equalTo: safe.topAnchor, constant: 10),

            toast.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            toast.topAnchor.constraint(equalTo: safe.topAnchor, constant: 14),
            toast.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, multiplier: 0.9),

            controls.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
            controls.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -12),
            controls.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor, constant: -20),

            testWarning.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            testWarning.topAnchor.constraint(equalTo: safe.topAnchor, constant: 8),
        ])

        // Tippen = Leiste, zwei Finger = zoomen, ziehen = Ausschnitt, lange druecken = Clip.
        // Ob ein Autodisplay Mehrfinger-Gesten liefert, haengt vom Auto ab (CarPlay Simulator: nein, gemessen
        // am 23.11.2026) – am iPhone gibt es deshalb denselben Zoom als Regler samt Zuruecksetzen.
        // Kein Doppeltippen: Schnelles Tippen wurde als Doppeltipp erkannt (7x in einer Minute), ausserdem
        // verzoegerte es jeden einfachen Tipp um ~0,3 s.
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 2
        for gesture in [tap, pinch, pan, UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))] {
            gesture.delegate = self
            view.addGestureRecognizer(gesture)
        }

        // Tag/Nacht des Autos: CarPlay stellt das Erscheinungsbild des Fensters um.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: Self, _) in
            controller.reportAppearance()
        }
        observe()
        #if DEBUG
        // Test-Hilfe: `-MirrorShowControls YES` blendet die Leiste nach 3 s dauerhaft ein (Screenshots ohne Tippen).
        if UserDefaults.standard.bool(forKey: "MirrorShowControls") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.videoVisible else { return }
                self.showControls()
            }
        }
        #endif
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        reportAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let insets = view.safeAreaInsets
        videoView.pictureInsets = insets
        // Pixelgroesse der Bildflaeche (ohne Seitenleiste) an die Erweiterung melden: Sie kodiert dann genau so gross.
        let area = videoView.pictureArea
        let scale = view.window?.windowScene?.screen.scale ?? traitCollection.displayScale
        let pixels = CGSize(width: (area.width * scale).rounded(), height: (area.height * scale).rounded())
        guard pixels != lastPixelSize, pixels.width > 0 else { return }
        lastPixelSize = pixels
        MirrorLog.write("Autodisplay: Fenster \(Int(view.bounds.width))x\(Int(view.bounds.height)) pt, sicherer Rand "
                        + "oben \(Int(insets.top)) links \(Int(insets.left)) unten \(Int(insets.bottom)) "
                        + "rechts \(Int(insets.right)), Bildflaeche \(Int(pixels.width))x\(Int(pixels.height)) px")
        hub.setCarPixelSize(pixels)
    }

    private func reportAppearance() {
        hub.setCarDark(traitCollection.userInterfaceStyle == .dark)
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

    private var videoVisible: Bool { attached && hub.sourceConnected }

    private func refresh() {
        // Sprachwechsel am iPhone wirkt auch hier sofort: `code` lesen = beobachten.
        _ = LanguageStore.shared.code
        testWarning.text = "  " + String(localized: "Driving lock OFF – test only", bundle: .ui) + "  "
        let locked = hub.driving.isLocked
        let streaming = hub.sourceConnected
        let visible = hub.carForeground && !locked
        setAttached(visible)
        videoView.isHidden = !visible || !streaming
        videoView.orientation = hub.orientation
        videoView.fit = hub.fit
        videoView.zoomCrop = CGFloat(hub.zoomCrop)
        videoView.videoSize = hub.frameSize
        videoView.zoom = hub.zoom
        videoView.panFraction = hub.panFraction
        videoView.ambient = hub.ambientBackground

        if locked {
            // Den Grund nennen: In der Garage stand sonst "waehrend der Fahrt", obwohl nur GPS fehlte (23.11.2026).
            switch hub.driving.lockReason {
            case .noLocation:
                showMessage(symbol: "location.slash.fill", title: String(localized: "Precise location needed", bundle: .ui),
                            text: String(localized: "Allow DashMirror precise location on the iPhone. Without it the picture stays off.", bundle: .ui))
            case .noGPS:
                showMessage(symbol: "location.magnifyingglass", title: String(localized: "Waiting for GPS", bundle: .ui),
                            text: String(localized: "The picture appears once GPS confirms that the car is standing. Garages and tunnels often have no GPS.", bundle: .ui))
            case .driving, nil:
                showMessage(symbol: "car.fill", title: String(localized: "Hidden while driving", bundle: .ui),
                            text: String(localized: "The picture comes back as soon as the car stands still.", bundle: .ui))
            }
        } else if !streaming {
            showMessage(symbol: "rectangle.on.rectangle",
                        title: String(localized: "Waiting for the broadcast", bundle: .ui),
                        text: String(localized: "On the iPhone: open “DashMirror” › “Start mirroring”\nor Control Center › long-press Screen Recording › “DashMirror”.\nLocking the iPhone ends the broadcast – start it again afterwards.", bundle: .ui))
        } else {
            message.isHidden = true
        }
        if !videoVisible { controls.isHidden = true }

        // Touch ans iPhone: nur mit sichtbarem Bild (Fahrsperre!) und bereiter Verbindung. Lesen = beobachten.
        let forwarding = TouchForwarder.shared.isActive && visible && streaming
        if forwarding != forwardingShown {
            forwardingShown = forwarding
            if !forwarding { touchLayer.liftAll() }
            touchLayer.isHidden = !forwarding
            touchLayer.isUserInteractionEnabled = forwarding
            if forwarding { hideControls() }
            showToast(forwarding ? String(localized: "Touch goes to the iPhone", bundle: .ui)
                                 : String(localized: "Touch back to DashMirror", bundle: .ui), seconds: 2)
            MirrorLog.write("Autodisplay: Touch ans iPhone \(forwarding ? "an" : "aus")")
        }

        // Nachtmodus weich ein- und ausblenden (der Lichtsensor schaltet z. B. im Tunnel schnell um).
        let shade = hub.nightDimActive ? CGFloat(hub.nightStrength) : 0
        if abs(nightShade.alpha - shade) > 0.001 {
            UIView.animate(withDuration: 0.8) { self.nightShade.alpha = shade }
        }

        // Leiste: Texte immer aktuell halten (Sprache, Format, Speichern laeuft).
        formatButton.configuration?.title = hub.fit.title
        clipButton.configuration?.title = hub.replay.isSaving ? String(localized: "Saving…", bundle: .ui)
                                                               : String(localized: "Save clip", bundle: .ui)
        clipButton.isEnabled = !hub.replay.isSaving
        clipButton.isHidden = !hub.replay.enabled
        // Info und Zoom nur als Symbol – mit Text passt die Leiste nicht auf ein ~590 pt breites Autodisplay.
        infoButton.accessibilityLabel = String(localized: "Info", bundle: .ui)
        resetZoomButton.accessibilityLabel = String(localized: "Reset zoom", bundle: .ui)
        resetZoomButton.isHidden = hub.zoom <= 1.001 && hub.panFraction == .zero

        // Hitzeschutz: einmal pro Wechsel Bescheid geben.
        let thermal = hub.thermalState
        if thermal != lastThermal {
            if hub.heatProtection, thermal.rawValue > ProcessInfo.ThermalState.fair.rawValue {
                showToast(thermal == .critical
                          ? String(localized: "iPhone very hot – picture reduced to 30 fps", bundle: .ui)
                          : String(localized: "iPhone hot – picture quality lowered", bundle: .ui), seconds: 4)
            } else if hub.heatProtection, lastThermal.rawValue > ProcessInfo.ThermalState.fair.rawValue {
                showToast(String(localized: "iPhone cooler – picture quality back to normal", bundle: .ui), seconds: 3)
            }
            lastThermal = thermal
        }

        hud.isHidden = !showsHUD
        if showsHUD {
            let latency = hub.latencyMs.map { String(format: "%.0f ms", locale: .ui, $0) } ?? "–"
            hud.text = "  " + String(format: String(localized: "%.0f fps", bundle: .ui), locale: .ui, hub.framesPerSecond)
                + String(format: " · %.1f Mbit/s · %@ · %dx%d · %@ · %@  ", locale: .ui, hub.megabitsPerSecond, latency,
                              Int(hub.frameSize.width), Int(hub.frameSize.height), hub.fit.title, hub.thermalState.title)
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
        updateBackground()
    }

    /// Zweite Anzeige fuer den unscharfen Hintergrund – nur angemeldet, solange Raender sichtbar sind.
    private func updateBackground() {
        let wants = attached && videoView.needsBackground
        guard wants != backgroundAttached else { return }
        backgroundAttached = wants
        if wants {
            hub.attach(videoView.backgroundRenderer)
        } else {
            hub.detach(videoView.backgroundRenderer)
            videoView.backgroundRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        }
        MirrorLog.write("Autodisplay: unscharfer Hintergrund \(wants ? "an" : "aus")")
    }

    private func showMessage(symbol: String, title: String, text: String) {
        messageIcon.image = UIImage(systemName: symbol)
        messageTitle.text = title
        messageText.text = text
        message.isHidden = false
    }

    // MARK: Leiste

    @objc private func tapped() {
        MirrorLog.write("Autodisplay: getippt (Leiste \(controls.isHidden ? "ein" : "aus")\(videoVisible ? "" : ", kein Bild – ignoriert"))")
        guard videoVisible else { return }
        if controls.isHidden { showControls() } else { hideControls() }
    }

    private func showControls() {
        controls.alpha = 0
        controls.isHidden = false
        UIView.animate(withDuration: 0.2) { self.controls.alpha = 1 }
        scheduleHideControls()
    }

    private func hideControls() {
        controlsWork?.cancel()
        UIView.animate(withDuration: 0.25, animations: { self.controls.alpha = 0 }) { _ in
            if self.controls.alpha == 0 { self.controls.isHidden = true }
        }
    }

    /// Jede Bedienung verlaengert die Anzeige – beim Durchtippen der Formate verschwindet sie nicht mittendrin.
    private func scheduleHideControls() {
        controlsWork?.cancel()
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "MirrorShowControls") { return }
        #endif
        let work = DispatchWorkItem { [weak self] in self?.hideControls() }
        controlsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    @objc private func formatTapped() {
        hub.fit = hub.fit.next
        showToast(String(format: String(localized: "Picture: %@", bundle: .ui), locale: .ui, hub.fit.title))
        MirrorLog.write("Autodisplay: Bildformat \(hub.fit.rawValue)")
        scheduleHideControls()
    }

    @objc private func clipTapped() {
        hideControls()
        saveClip(trigger: "Knopf")
    }

    @objc private func infoTapped() {
        showsHUD.toggle()
        refresh()
        scheduleHideControls()
    }

    @objc private func resetZoomTapped() {
        hub.resetZoom()
        scheduleHideControls()
    }

    private func saveClip(trigger: String) {
        guard hub.replay.enabled, !hub.replay.isSaving else { return }
        MirrorLog.write("Autodisplay: Clip speichern (\(trigger))")
        showToast(String(localized: "Saving clip…", bundle: .ui))
        Task {
            let outcome = await hub.replay.save()
            showToast(outcome.message, seconds: 4)
        }
    }

    // MARK: Beruehrung

    private var pinchStartZoom: Double = 1

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartZoom = hub.zoom
        case .changed:
            hub.zoom = Double((CGFloat(pinchStartZoom) * gesture.scale).clamped(to: MirrorVideoView.zoomRange))
        case .ended, .cancelled:
            showToast(String(format: "Zoom %.1f×", locale: .ui, hub.zoom))
            MirrorLog.write(String(format: "Autodisplay: Zoom %.2f", hub.zoom))
        default:
            break
        }
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let delta = gesture.translation(in: videoView)
        gesture.setTranslation(.zero, in: videoView)
        // Verschiebung in Punkten -> Anteil der moeglichen Verschiebung. Ohne Zoom gibt es nichts zu verschieben.
        let limit = videoView.maxPan()
        var fraction = hub.panFraction
        if limit.x > 0 { fraction.x = (fraction.x + delta.x / limit.x).clamped(to: -1...1) }
        if limit.y > 0 { fraction.y = (fraction.y + delta.y / limit.y).clamped(to: -1...1) }
        if fraction != hub.panFraction { hub.panFraction = fraction }
    }

    @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, videoVisible else { return }
        saveClip(trigger: "lang gedrueckt")
    }

    private func showToast(_ text: String, seconds: Double = 1.6) {
        toast.text = "   \(text)   "
        toast.isHidden = false
        toastWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.toast.isHidden = true }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

extension CarMirrorViewController: UIGestureRecognizerDelegate {
    /// Zoomen und Verschieben gleichzeitig (zwei Finger), sonst muesste man absetzen.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (gestureRecognizer is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    /// Beruehrungen auf den Knoepfen der Leiste gehoeren den Knoepfen, nicht den Gesten.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Touch geht ans iPhone: DashMirrors eigene Gesten ruhen (sonst blendete jeder Tipp die Leiste ein).
        if forwardingShown { return false }
        var view = touch.view
        while let current = view {
            if current is UIControl { return false }
            view = current.superview
        }
        return true
    }
}
