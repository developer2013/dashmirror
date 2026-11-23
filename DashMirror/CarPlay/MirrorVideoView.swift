//
//  MirrorVideoView.swift
//  DashMirror
//
//  Zeigt den H.264-Strom an (Hardware-Decoder ueber AVSampleBufferDisplayLayer) und dreht ihn nach der
//  Ausrichtung, die ReplayKit mitschickt: Das iPhone liefert immer hochkant, ein quer laufendes Spiel
//  liegt darin um 90 Grad gedreht. Gedreht wird hier per Layer-Transform – kostet praktisch nichts,
//  waehrend Drehen in der Erweiterung Speicher und Rechenzeit unter der 50-MB-Grenze kosten wuerde.
//
//  Zoom und Ausschnitt sind ebenfalls nur Transform (Zoom mit zwei Fingern im Auto): kein Neukodieren,
//  keine Verzoegerung. Der Ausschnitt wird als Anteil (-1...1) der moeglichen Verschiebung gefuehrt, damit er
//  nach Zoom-, Format- oder Displaywechsel noch sinnvoll sitzt.
//
//  Unscharfer Hintergrund (`ambient`): Statt schwarzer Raender liegt dahinter dasselbe Bild noch einmal,
//  randlos vergroessert und weichgezeichnet – wie bei Hochkant-Videos im Fernsehen. Das ist eine zweite
//  Anzeige mit eigenem Decoder (die Hardware schafft das nebenbei); ob sie gebraucht wird, meldet
//  `onNeedsBackgroundChange`, der Besitzer meldet sie dann an bzw. ab.
//
//  Wie native CarPlay-Apps (Foto aus dem BMW vom 15.11.2026): Der Hintergrund fuellt die ganze Flaeche, auch unter der
//  schwebenden Seitenleiste; das scharfe Bild bleibt im sicheren Bereich (`pictureInsets`), damit die Leiste
//  nichts vom Spiel verdeckt. Der sichtbare Teil des Bildes bekommt runde Ecken wie die CarPlay-Flaeche.
//  Weil die Ecken und der Streifen unter der Leiste immer Hintergrund zeigen, laeuft die zweite Anzeige jetzt
//  bei eingeschaltetem Hintergrund immer mit (vorher nur bei Raendern).
//
//  Ebenen von hinten nach vorn: backgroundHost (Hintergrund-Video) -> blur -> foregroundHost (Bild, gerundet).
//

import AVFoundation
import ImageIO
import UIKit

final class MirrorVideoView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()
    var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    let backgroundLayer = AVSampleBufferDisplayLayer()
    var backgroundRenderer: AVSampleBufferVideoRenderer { backgroundLayer.sampleBufferRenderer }

    var orientation: CGImagePropertyOrientation = .up {
        didSet { if orientation != oldValue { setNeedsLayout() } }
    }

    var fit: MirrorFit = .fit {
        didSet { if fit != oldValue { setNeedsLayout() } }
    }

    /// Nur fuers Format Zoom: hoechstens so viel abschneiden (Einstellung am iPhone).
    var zoomCrop = CGFloat(MirrorFit.defaultZoomCrop) {
        didSet { if zoomCrop != oldValue { setNeedsLayout() } }
    }

    /// Kodierte Bildgroesse (vor der Drehung) – braucht es fuer die Grenzen beim Verschieben.
    var videoSize: CGSize = .zero {
        didSet { if videoSize != oldValue { setNeedsLayout() } }
    }

    static let zoomRange: ClosedRange<CGFloat> = 1...4

    var zoom: CGFloat = 1 {
        didSet { if zoom != oldValue { setNeedsLayout() } }
    }

    var panFraction: CGPoint = .zero {
        didSet { if panFraction != oldValue { setNeedsLayout() } }
    }

    /// Unscharfer Hintergrund statt schwarzer Raender.
    var ambient = false {
        didSet { if ambient != oldValue { setNeedsLayout() } }
    }

    /// Bereich, den das scharfe Bild meiden muss (im Auto: die CarPlay-Seitenleiste). Der Hintergrund liegt
    /// trotzdem auf der ganzen Flaeche.
    var pictureInsets: UIEdgeInsets = .zero {
        didSet { if pictureInsets != oldValue { setNeedsLayout() } }
    }

    /// Eckenradius des Bildes als Anteil der Hoehe. Geschaetzt am Foto vom 15.11.2026 (BMW): CarPlay rundet
    /// die App-Flaeche mit etwa 5 % der Hoehe – im BMW (241 pt) also rund 12 pt.
    static let cornerFraction: CGFloat = 0.05

    /// Flaeche fuer das scharfe Bild (ohne Seitenleiste).
    var pictureArea: CGRect { bounds.inset(by: pictureInsets) }

    /// Ob der Hintergrund gerade gebraucht wird (an, Bild bekannt).
    private(set) var needsBackground = false
    var onNeedsBackgroundChange: ((Bool) -> Void)?

    private let backgroundHost = UIView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let foregroundHost = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        for host in [backgroundHost, blur, foregroundHost] {
            host.isUserInteractionEnabled = false
            addSubview(host)
        }
        backgroundHost.isHidden = true
        blur.isHidden = true
        // Runde Ecken: der Rahmen des sichtbaren Bildes schneidet das Video zu (continuous wie CarPlay selbst).
        foregroundHost.clipsToBounds = true
        foregroundHost.layer.cornerCurve = .continuous
        // Etwas dunkler als der reine Weichzeichner, damit das eigentliche Bild vorne bleibt.
        blur.contentView.backgroundColor = UIColor(white: 0, alpha: 0.25)

        // Immer .resize: Der Layer bekommt genau die Groesse, die MirrorFit ausrechnet (auch Zwischenstufen).
        for layer in [displayLayer, backgroundLayer] {
            layer.videoGravity = .resize
            layer.backgroundColor = UIColor.black.cgColor
        }
        backgroundHost.layer.addSublayer(backgroundLayer)
        foregroundHost.layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstuetzt") }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundHost.frame = bounds
        blur.frame = bounds
        let area = pictureArea
        let (angle, swapsSides) = Self.rotation(for: orientation)
        let scale = zoom.clamped(to: Self.zoomRange)
        let limit = maxPan(zoom: scale)
        let offset = CGPoint(x: panFraction.x.clamped(to: -1...1) * limit.x,
                             y: panFraction.y.clamped(to: -1...1) * limit.y)
        let content = contentSize()

        // Wo das Bild nach Zoom und Ausschnitt liegt – sichtbar ist davon nur der Teil im sicheren Bereich.
        // Dieser Teil wird der Rahmen mit den runden Ecken; das Video liegt darin an derselben Stelle wie vorher.
        let center = CGPoint(x: area.midX + offset.x, y: area.midY + offset.y)
        let picture = CGRect(x: center.x - content.width * scale / 2, y: center.y - content.height * scale / 2,
                             width: content.width * scale, height: content.height * scale)
        let visible = picture.intersection(area)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let shownFrame = visible.isNull ? .zero : visible
        foregroundHost.frame = shownFrame
        // Bezogen auf die Displayhoehe wie bei CarPlay – aber nie mehr, als zum Bild passt (flaches Bild in einer
        // hohen Flaeche, z. B. in der iPhone-Vorschau). Im Auto sind beide Hoehen gleich.
        foregroundHost.layer.cornerRadius = (min(area.height, shownFrame.height, shownFrame.width) * Self.cornerFraction).rounded()
        // Layer genau so gross wie das Bild ohne Zoom; vor dem Drehen mit vertauschten Seiten.
        place(displayLayer, size: content, swapsSides: swapsSides,
              at: CGPoint(x: center.x - shownFrame.minX, y: center.y - shownFrame.minY))
        // Drehen und vergroessern, beides um die Mitte (die Verschiebung steckt schon in der Position).
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)))

        // Hintergrund randlos ueber die ganze Flaeche (8 % groesser, damit der Weichzeichner an den Kanten keine
        // dunklen Saeume zeigt). Zoom/Ausschnitt gelten nur fuers Bild vorne.
        let wants = ambient && videoSize.width > 0 && videoSize.height > 0
        backgroundHost.isHidden = !wants
        blur.isHidden = !wants
        if wants {
            let fill = MirrorFit.fill.contentSize(video: shownSize, in: bounds.size, zoomCrop: zoomCrop)
            place(backgroundLayer, size: CGSize(width: fill.width * 1.08, height: fill.height * 1.08),
                  swapsSides: swapsSides, at: CGPoint(x: bounds.midX, y: bounds.midY))
            backgroundLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        }
        CATransaction.commit()

        if wants != needsBackground {
            needsBackground = wants
            onNeedsBackgroundChange?(wants)
        }
    }

    /// Wie weit sich das Bild bei diesem Zoom je Achse verschieben laesst, bis sein Rand den Bildbereich erreicht.
    func maxPan(zoom: CGFloat? = nil) -> CGPoint {
        let scale = (zoom ?? self.zoom).clamped(to: Self.zoomRange)
        let content = contentSize()
        let area = pictureArea
        return CGPoint(x: max(0, (content.width * scale - area.width) / 2),
                       y: max(0, (content.height * scale - area.height) / 2))
    }

    private func place(_ layer: CALayer, size: CGSize, swapsSides: Bool, at position: CGPoint) {
        layer.bounds = CGRect(origin: .zero, size: swapsSides ? CGSize(width: size.height, height: size.width) : size)
        layer.position = position
    }

    /// Bildgroesse so, wie es angezeigt wird (nach der Drehung).
    private var shownSize: CGSize {
        Self.rotation(for: orientation).swapsSides ? CGSize(width: videoSize.height, height: videoSize.width) : videoSize
    }

    /// Groesse des Bildes ohne Zoom, je nach Bildformat (Rechnung in MirrorFit), bezogen auf den Bildbereich.
    /// Ohne bekannte Bildgroesse (noch kein Bild empfangen): ganzer Bildbereich.
    private func contentSize() -> CGSize {
        let area = pictureArea.size
        guard videoSize.width > 0, videoSize.height > 0 else { return area }
        return fit.contentSize(video: shownSize, in: area, zoomCrop: zoomCrop)
    }

    /// ReplayKit meint mit .right (6) "zum Anzeigen 90 Grad GEGEN den Uhrzeigersinn drehen", mit .left (8) im
    /// Uhrzeigersinn – also umgekehrt zur EXIF-Lesart. Gemessen am 23.11.2026 im BMW: Mit der EXIF-Lesart stand
    /// YouTube bei Ausrichtung 6 auf dem Kopf (90 Grad falsch herum = 180 Grad). WebRTC/Jitsi drehen ebenso.
    /// In UIKit dreht ein positiver Winkel im Uhrzeigersinn (y zeigt nach unten).
    /// Gespiegelte Varianten liefert ReplayKit nicht – sie werden wie die ungespiegelten gedreht.
    /// `nonisolated`: Auch ClipWriter dreht damit (im Hintergrund).
    nonisolated static func rotation(for orientation: CGImagePropertyOrientation) -> (angle: CGFloat, swapsSides: Bool) {
        switch orientation {
        case .right, .rightMirrored: (-.pi / 2, true)
        case .left, .leftMirrored:   (.pi / 2, true)
        case .down, .downMirrored:   (.pi, false)
        default:                     (0, false)
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
