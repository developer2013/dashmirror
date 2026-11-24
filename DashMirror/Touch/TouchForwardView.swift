//
//  TouchForwardView.swift
//  DashMirror
//
//  Durchsichtige Ebene ueber dem Bild im Auto, nur aktiv, wenn "Touch weiterleiten" bereit ist. Sie nimmt EINEN
//  Finger und meldet ihn als iPhone-Koordinate weiter; die uebrigen Gesten (Leiste, Zoom, Clip) ruhen solange.
//  Mehrfinger-Gesten liefert ohnehin nicht jedes Auto (CarPlay Simulator: nein, gemessen am 23.11.2026).
//

import UIKit

final class TouchForwardView: UIView {
    /// Punkt in dieser View -> Lage auf dem iPhone (je Achse 0...1, Hochformat); nil = neben dem Bild.
    var mapToPhone: ((CGPoint) -> CGPoint?)?
    /// (Finger liegt?, Lage auf dem iPhone)
    var onTouch: ((Bool, CGPoint) -> Void)?

    private weak var tracked: UITouch?
    /// Letzte Stelle auf dem iPhone – dort hebt der Finger ab, auch wenn er zuletzt neben das Bild gerutscht ist.
    private var lastPhonePoint: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) wird nicht unterstuetzt") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracked == nil, let touch = touches.first,
              let point = mapToPhone?(touch.location(in: self)) else { return }
        tracked = touch
        lastPhonePoint = point
        onTouch?(true, point)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch),
              let point = mapToPhone?(touch.location(in: self)), point != lastPhonePoint else { return }
        lastPhonePoint = point
        onTouch?(true, point)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        lift(touches)
    }

    /// Ebene wird abgeschaltet (Fahrsperre, Verbindung weg): einen liegenden Finger sauber abheben,
    /// sonst "klebt" er am iPhone.
    func liftAll() {
        if tracked != nil, let point = lastPhonePoint { onTouch?(false, point) }
        tracked = nil
        lastPhonePoint = nil
    }

    private func lift(_ touches: Set<UITouch>) {
        guard let touch = tracked, touches.contains(touch) else { return }
        if let point = lastPhonePoint { onTouch?(false, point) }
        tracked = nil
        lastPhonePoint = nil
    }
}
