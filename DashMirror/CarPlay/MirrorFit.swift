//
//  MirrorFit.swift
//  DashMirror
//
//  Bildformate fuers Autodisplay. AVSampleBufferDisplayLayer kann selbst nur einpassen, fuellen und strecken –
//  fuer den einstellbaren Zoom rechnet `contentSize` die Bildgroesse selbst aus, MirrorVideoView legt das Video
//  dann mit .resize genau in diesen Rahmen (zentriert, mit Zoom/Ausschnitt obendrauf).
//
//  Zahlen fuer den BMW (23.11.2026): Bildflaeche 2,45:1, iPhone quer 2,17:1 -> Fuellen ist 1,13x groesser als
//  Einpassen und schneidet quer 11,4 % der Hoehe ab. Hochkant (1:2,17) ist der Unterschied riesig (5,3x).
//
//  Bis 23.11.2026 gab es sieben Formate. Im BMW-Test waren quer "Automatisch", "Leicht vergroessert" und
//  "Fuellen" identisch (alle 11,4 % abgeschnitten, "zu nah dran"), die Streck-Varianten kaum zu unterscheiden.
//  Deshalb jetzt vier klar verschiedene Formate, und beim Zoom stellt man am iPhone ein, wie viel er hoechstens
//  abschneiden darf.
//

import CoreGraphics
import Foundation

enum MirrorFit: String, CaseIterable, Identifiable {
    case fit
    case zoom = "zoomLight"     // alter Rohwert: Wer "Leicht vergroessert" gewaehlt hatte, behaelt den Zoom
    case fill
    case stretch

    var id: String { rawValue }

    /// Gespeicherte Wahl laden. Die entfernten Formate (auto, smart, stretchLight) und "nichts gespeichert"
    /// werden zum Zoom – im BMW-Test das beste Format.
    init(stored: String?) {
        self = stored.flatMap(Self.init(rawValue:)) ?? .zoom
    }

    var title: String {
        switch self {
        case .fit:     String(localized: "Fit", bundle: .ui)
        case .zoom:    String(localized: "Zoom", bundle: .ui)
        case .fill:    String(localized: "Fill", bundle: .ui)
        case .stretch: String(localized: "Stretch", bundle: .ui)
        }
    }

    var detail: String {
        switch self {
        case .fit:     String(localized: "Whole picture, black bars.", bundle: .ui)
        case .zoom:    String(localized: "Zooms in, but cuts off at most the amount set below. The rest stays as a border.", bundle: .ui)
        case .fill:    String(localized: "Fills completely, edges are cut off.", bundle: .ui)
        case .stretch: String(localized: "Fills completely, the picture gets distorted.", bundle: .ui)
        }
    }

    /// Tippen im Auto geht der Reihe nach durch alle Formate (zum Vergleichen; der Name wird eingeblendet).
    var next: MirrorFit {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// Wie viel der Zoom hoechstens abschneiden darf (Anteil der Bildhoehe bzw. -breite). 15 % reichen im BMW
    /// quer bis ganz randlos (11,4 %); 6 % als Start = etwa die Mitte zwischen Einpassen und Fuellen.
    static let zoomCropRange: ClosedRange<Double> = 0...0.15
    static let defaultZoomCrop = 0.06

    /// Groesse des sichtbaren Bildes (ohne Zoom mit zwei Fingern) in der Ansicht.
    /// - Parameters:
    ///   - video: Bildgroesse so, wie es angezeigt wird (nach der Drehung).
    ///   - view: Groesse der Bildflaeche.
    ///   - zoomCrop: nur fuer `.zoom` – hoechstens so viel abschneiden (0...0,15).
    func contentSize(video: CGSize, in view: CGSize, zoomCrop: CGFloat) -> CGSize {
        guard video.width > 0, video.height > 0, view.width > 0, view.height > 0 else { return view }
        let fitScale = min(view.width / video.width, view.height / video.height)
        let fillScale = max(view.width / video.width, view.height / video.height)
        let fit = CGSize(width: video.width * fitScale, height: video.height * fitScale)
        let ratio = fillScale / fitScale                       // >= 1: um so viel ist Fuellen groesser

        func zoomed(_ factor: CGFloat) -> CGSize { CGSize(width: fit.width * factor, height: fit.height * factor) }

        switch self {
        case .fit:     return fit
        case .fill:    return zoomed(ratio)
        case .stretch: return view
        case .zoom:
            // Abgeschnitten wird quer oben/unten: 1 - 1/Faktor. Nie weiter als bis randlos (ratio).
            let crop = zoomCrop.clamped(to: 0...CGFloat(Self.zoomCropRange.upperBound))
            return zoomed(min(ratio, 1 / (1 - crop)))
        }
    }
}
