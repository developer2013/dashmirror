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

import AVFoundation
import ImageIO
import UIKit

final class MirrorVideoView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()
    var renderer: AVSampleBufferVideoRenderer { displayLayer.sampleBufferRenderer }

    var orientation: CGImagePropertyOrientation = .up {
        didSet { if orientation != oldValue { setNeedsLayout() } }
    }

    var fit: MirrorFit = .fit {
        didSet { if fit != oldValue { displayLayer.videoGravity = fit.gravity; setNeedsLayout() } }
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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        displayLayer.videoGravity = fit.gravity
        displayLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstuetzt") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let (angle, swapsSides) = Self.rotation(for: orientation)
        let scale = zoom.clamped(to: Self.zoomRange)
        let limit = maxPan(zoom: scale)
        let offset = CGPoint(x: panFraction.x.clamped(to: -1...1) * limit.x,
                             y: panFraction.y.clamped(to: -1...1) * limit.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Vor dem Drehen hat der Layer vertauschte Seiten – nach der Drehung fuellt er die Ansicht genau.
        displayLayer.bounds = CGRect(origin: .zero, size: swapsSides
                                     ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Reihenfolge: drehen, vergroessern (beides um die Mitte), dann in Ansichts-Koordinaten verschieben.
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: offset.x, y: offset.y)))
        CATransaction.commit()
    }

    /// Wie weit sich das Bild bei diesem Zoom je Achse verschieben laesst, bis sein Rand die Ansicht erreicht.
    func maxPan(zoom: CGFloat? = nil) -> CGPoint {
        let scale = (zoom ?? self.zoom).clamped(to: Self.zoomRange)
        let content = contentSize()
        return CGPoint(x: max(0, (content.width * scale - bounds.width) / 2),
                       y: max(0, (content.height * scale - bounds.height) / 2))
    }

    /// Groesse des sichtbaren Bildes ohne Zoom, je nach Bildformat.
    private func contentSize() -> CGSize {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds.size }
        let shown = Self.rotation(for: orientation).swapsSides
            ? CGSize(width: videoSize.height, height: videoSize.width) : videoSize
        switch fit {
        case .fit:
            return AVMakeRect(aspectRatio: shown, insideRect: bounds).size
        case .fill:
            let factor = max(bounds.width / shown.width, bounds.height / shown.height)
            return CGSize(width: shown.width * factor, height: shown.height * factor)
        case .stretch:
            return bounds.size
        }
    }

    /// EXIF-Bedeutung: .right (6) = zum Anzeigen 90 Grad im Uhrzeigersinn drehen, .left (8) = dagegen.
    /// In UIKit dreht ein positiver Winkel im Uhrzeigersinn (y zeigt nach unten).
    /// Gespiegelte Varianten liefert ReplayKit nicht – sie werden wie die ungespiegelten gedreht.
    static func rotation(for orientation: CGImagePropertyOrientation) -> (angle: CGFloat, swapsSides: Bool) {
        switch orientation {
        case .right, .rightMirrored: (.pi / 2, true)
        case .left, .leftMirrored:   (-.pi / 2, true)
        case .down, .downMirrored:   (.pi, false)
        default:                     (0, false)
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
