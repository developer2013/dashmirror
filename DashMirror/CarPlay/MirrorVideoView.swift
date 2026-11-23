//
//  MirrorVideoView.swift
//  DashMirror
//
//  Zeigt den H.264-Strom an (Hardware-Decoder ueber AVSampleBufferDisplayLayer) und dreht ihn nach der
//  Ausrichtung, die ReplayKit mitschickt: Das iPhone liefert immer hochkant, ein quer laufendes Spiel
//  liegt darin um 90 Grad gedreht. Gedreht wird hier per Layer-Transform – kostet praktisch nichts,
//  waehrend Drehen in der Erweiterung Speicher und Rechenzeit unter der 50-MB-Grenze kosten wuerde.
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
        didSet { if fit != oldValue { displayLayer.videoGravity = fit.gravity } }
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Vor dem Drehen hat der Layer vertauschte Seiten – nach der Drehung fuellt er die Ansicht genau.
        displayLayer.bounds = CGRect(origin: .zero, size: swapsSides
                                     ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        displayLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
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
