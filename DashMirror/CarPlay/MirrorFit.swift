//
//  MirrorFit.swift
//  DashMirror
//
//  Bildformate fuers Autodisplay. AVSampleBufferDisplayLayer kann selbst nur einpassen, fuellen und strecken –
//  fuer Zwischenstufen rechnet `contentSize` die Bildgroesse selbst aus, MirrorVideoView legt das Video dann mit
//  .resize genau in diesen Rahmen (zentriert, mit Zoom/Ausschnitt obendrauf).
//
//  Zahlen fuer den BMW (23.11.2026): Bildflaeche 2,45:1, iPhone quer 2,17:1 -> Fuellen ist 1,13x groesser als
//  Einpassen. Hochkant (1:2,17) ist der Unterschied riesig (5,3x) – dort helfen nur Einpassen oder Zoom.
//

import CoreGraphics
import Foundation

enum MirrorFit: String, CaseIterable, Identifiable {
    case auto, fit, zoomLight, smart, stretchLight, fill, stretch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:         String(localized: "Automatic", bundle: .ui)
        case .fit:          String(localized: "Fit", bundle: .ui)
        case .zoomLight:    String(localized: "Slight zoom", bundle: .ui)
        case .smart:        String(localized: "Smart fill", bundle: .ui)
        case .stretchLight: String(localized: "Slight stretch", bundle: .ui)
        case .fill:         String(localized: "Fill (zoom)", bundle: .ui)
        case .stretch:      String(localized: "Stretch", bundle: .ui)
        }
    }

    var detail: String {
        switch self {
        case .auto:         String(localized: "Fills when the shapes are close (under 15 %), otherwise fits. Never distorts.", bundle: .ui)
        case .fit:          String(localized: "Whole picture, black bars.", bundle: .ui)
        case .zoomLight:    String(localized: "Zooms in until at most 12 % is cut off.", bundle: .ui)
        case .smart:        String(localized: "Up to 10 % stretch and 10 % zoom combined – usually fills wide displays with barely visible changes.", bundle: .ui)
        case .stretchLight: String(localized: "Stretches by at most 12 %, the rest stays black bars.", bundle: .ui)
        case .fill:         String(localized: "Fills completely, edges are cut off.", bundle: .ui)
        case .stretch:      String(localized: "Fills completely, the picture gets distorted.", bundle: .ui)
        }
    }

    /// Tippen im Auto geht der Reihe nach durch alle Formate (zum Vergleichen; der Name wird eingeblendet).
    var next: MirrorFit {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    static let autoThreshold: CGFloat = 1.15     // Automatisch fuellt, wenn Fuellen hoechstens 15 % groesser ist
    static let maxCrop: CGFloat = 0.12           // Leicht vergroessert: hoechstens 12 % abschneiden
    static let maxStretch: CGFloat = 1.12        // Leicht gestreckt: hoechstens 12 % verzerren
    static let smartLimit: CGFloat = 1.10        // Smart: je bis 10 % strecken und zoomen

    /// Groesse des sichtbaren Bildes (ohne Zoom) in der Ansicht.
    /// - Parameters:
    ///   - video: Bildgroesse so, wie es angezeigt wird (nach der Drehung).
    ///   - view: Groesse der Bildflaeche.
    func contentSize(video: CGSize, in view: CGSize) -> CGSize {
        guard video.width > 0, video.height > 0, view.width > 0, view.height > 0 else { return view }
        let fitScale = min(view.width / video.width, view.height / video.height)
        let fillScale = max(view.width / video.width, view.height / video.height)
        let fit = CGSize(width: video.width * fitScale, height: video.height * fitScale)
        let ratio = fillScale / fitScale                       // >= 1: um so viel ist Fuellen groesser
        let barsLeftRight = fit.width < view.width - 0.5      // sonst Raender oben/unten

        func scaled(_ size: CGSize, uniform: CGFloat, stretch: CGFloat = 1) -> CGSize {
            // Streckung nur in der Richtung der Raender, Zoom in beide Richtungen.
            CGSize(width: size.width * uniform * (barsLeftRight ? stretch : 1),
                   height: size.height * uniform * (barsLeftRight ? 1 : stretch))
        }

        switch self {
        case .fit:          return fit
        case .fill:         return scaled(fit, uniform: ratio)
        case .stretch:      return view
        case .auto:         return ratio <= Self.autoThreshold ? scaled(fit, uniform: ratio) : fit
        case .zoomLight:    return scaled(fit, uniform: min(ratio, 1 / (1 - Self.maxCrop)))
        case .stretchLight: return scaled(fit, uniform: 1, stretch: min(ratio, Self.maxStretch))
        case .smart:
            // Unterschied gleichmaessig auf Strecken und Zoomen verteilen, beides gedeckelt.
            let stretch = min(ratio.squareRoot(), Self.smartLimit)
            let zoom = min(ratio / stretch, Self.smartLimit)
            return scaled(fit, uniform: zoom, stretch: stretch)
        }
    }
}
