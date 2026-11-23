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
//  Anzeige mit eigenem Decoder (die Hardware schafft das nebenbei); sie wird nur gebraucht, solange Raender
//  sichtbar sind – das meldet `onNeedsBackgroundChange`, der Besitzer meldet sie dann an bzw. ab.
//
//  Ebenen von hinten nach vorn: backgroundHost (Hintergrund-Video) -> blur -> foregroundHost (Bild).
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

    /// Ob der Hintergrund gerade gebraucht wird (an, Bild bekannt, Raender sichtbar).
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
        for host in [backgroundHost, blur, foregroundHost] { host.frame = bounds }
        let (angle, swapsSides) = Self.rotation(for: orientation)
        let scale = zoom.clamped(to: Self.zoomRange)
        let limit = maxPan(zoom: scale)
        let offset = CGPoint(x: panFraction.x.clamped(to: -1...1) * limit.x,
                             y: panFraction.y.clamped(to: -1...1) * limit.y)
        let content = contentSize()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Layer genau so gross wie das sichtbare Bild; vor dem Drehen mit vertauschten Seiten.
        place(displayLayer, size: content, swapsSides: swapsSides)
        // Reihenfolge: drehen, vergroessern (beides um die Mitte), dann in Ansichts-Koordinaten verschieben.
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offset.x, y: offset.y)))

        // Raender sichtbar? Dann den Hintergrund randlos fuellen (8 % groesser, damit der Weichzeichner an den
        // Kanten keine dunklen Saeume zeigt). Zoom/Ausschnitt gelten nur fuers Bild vorne.
        let covers = content.width * scale >= bounds.width - 1 && content.height * scale >= bounds.height - 1
        let wants = ambient && videoSize.width > 0 && videoSize.height > 0 && !covers
        backgroundHost.isHidden = !wants
        blur.isHidden = !wants
        if wants {
            let fill = MirrorFit.fill.contentSize(video: shownSize, in: bounds.size)
            place(backgroundLayer, size: CGSize(width: fill.width * 1.08, height: fill.height * 1.08),
                  swapsSides: swapsSides)
            backgroundLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        }
        CATransaction.commit()

        if wants != needsBackground {
            needsBackground = wants
            onNeedsBackgroundChange?(wants)
        }
    }

    /// Wie weit sich das Bild bei diesem Zoom je Achse verschieben laesst, bis sein Rand die Ansicht erreicht.
    func maxPan(zoom: CGFloat? = nil) -> CGPoint {
        let scale = (zoom ?? self.zoom).clamped(to: Self.zoomRange)
        let content = contentSize()
        return CGPoint(x: max(0, (content.width * scale - bounds.width) / 2),
                       y: max(0, (content.height * scale - bounds.height) / 2))
    }

    private func place(_ layer: CALayer, size: CGSize, swapsSides: Bool) {
        layer.bounds = CGRect(origin: .zero, size: swapsSides ? CGSize(width: size.height, height: size.width) : size)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Bildgroesse so, wie es angezeigt wird (nach der Drehung).
    private var shownSize: CGSize {
        Self.rotation(for: orientation).swapsSides ? CGSize(width: videoSize.height, height: videoSize.width) : videoSize
    }

    /// Groesse des sichtbaren Bildes ohne Zoom, je nach Bildformat (Rechnung in MirrorFit).
    /// Ohne bekannte Bildgroesse (noch kein Bild empfangen): ganze Flaeche.
    private func contentSize() -> CGSize {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds.size }
        return fit.contentSize(video: shownSize, in: bounds.size)
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
