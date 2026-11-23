//
//  BorderDetector.swift
//  DashMirror – gemeinsam fuer App (Testbild) und Broadcast-Erweiterung
//
//  Findet schwarze Raender im iPhone-Bild. Viele Spiele lassen im Querformat links und rechts Streifen fuer die
//  Dynamic Island frei oder laufen in 16:9 auf dem 19,5:9-Bildschirm. Schneidet der Encoder diese Raender weg,
//  wird der echte Inhalt im Auto groesser – ohne dass etwas vom Bild verloren geht.
//
//  Regeln, damit nie Inhalt fehlt:
//  - Pro Achse wird nur so viel geschnitten, wie auf BEIDEN Seiten schwarz ist (Minimum, mittig). Das haelt den
//    Zuschnitt symmetrisch und spart den Versatz in der Clean Aperture.
//  - Wird der Rand kleiner (neuer Inhalt am Rand), gilt das sofort. Wird er groesser, erst nach 2 s Stabilitaet –
//    sonst wuerde jede dunkle Spielszene das Bild zoomen.
//  - Komplett schwarze Bilder (Ladebildschirm) oder Inhalt unter 40 % je Achse: nichts aendern.
//
//  Kostet wenig: hoechstens 4 Messungen pro Sekunde mit je einigen tausend gelesenen Pixeln.
//

import CoreVideo
import Foundation

nonisolated struct BorderDetector {
    /// Symmetrischer Zuschnitt in Pixeln je Seite (Puffer-Koordinaten, also vor der Drehung in der App).
    struct Crop: Equatable, CustomStringConvertible {
        var dx = 0
        var dy = 0
        var isZero: Bool { dx == 0 && dy == 0 }
        var description: String { "\(dx) px links/rechts, \(dy) px oben/unten" }
    }

    private(set) var active = Crop()
    private var candidate: Crop?
    private var candidateSince: UInt64 = 0
    private var lastCheck: UInt64 = 0

    static let checkInterval: UInt64 = 250_000_000      // 4x pro Sekunde
    static let growDelay: UInt64 = 2_000_000_000        // Rand waechst erst nach 2 s stabilem Messwert

    mutating func reset() {
        active = Crop()
        candidate = nil
        lastCheck = 0
    }

    /// Liefert den Zuschnitt, der fuer dieses Bild gelten soll.
    mutating func update(_ buffer: CVPixelBuffer, now: UInt64) -> Crop {
        guard now - lastCheck >= Self.checkInterval else { return active }
        lastCheck = now
        guard let measured = Self.measure(buffer) else { return active }

        if measured != candidate {
            candidate = measured
            candidateSince = now
        }
        var next = active
        // Weniger Rand = mehr Inhalt: sofort, sonst wuerde Bild abgeschnitten.
        if measured.dx < next.dx { next.dx = measured.dx }
        if measured.dy < next.dy { next.dy = measured.dy }
        // Mehr Rand: erst wenn der Messwert lange genug gleich bleibt.
        if now - candidateSince >= Self.growDelay { next = measured }
        active = next
        return active
    }

    /// Misst die schwarzen Raender. nil = keine verwertbare Aussage (unbekanntes Format, fast alles schwarz).
    static func measure(_ buffer: CVPixelBuffer) -> Crop? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let planar: Bool
        let bytesPerPixel: Int
        let threshold: UInt8
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  (planar, bytesPerPixel, threshold) = (true, 1, 16)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: (planar, bytesPerPixel, threshold) = (true, 1, 32)
        case kCVPixelFormatType_32BGRA:                        (planar, bytesPerPixel, threshold) = (false, 4, 16)
        default: return nil
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let rowBytes = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        guard width > 32, height > 32,
              let base = (planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer))?
                .assumingMemoryBound(to: UInt8.self) else { return nil }

        func dark(_ x: Int, _ y: Int) -> Bool {
            let pixel = base + y * rowBytes + x * bytesPerPixel
            if bytesPerPixel == 1 { return pixel[0] < threshold }
            return pixel[0] < threshold && pixel[1] < threshold && pixel[2] < threshold   // B, G, R
        }
        // 64 Stichproben je Spalte bzw. Zeile: Abstand ~40 px auf einem iPhone-Bild, kleiner als jedes HUD-Element.
        let samples = 64
        func columnDark(_ x: Int) -> Bool {
            (0..<samples).allSatisfy { dark(x, ($0 * (height - 1)) / (samples - 1)) }
        }
        func rowDark(_ y: Int) -> Bool {
            (0..<samples).allSatisfy { dark(($0 * (width - 1)) / (samples - 1), y) }
        }

        let maxX = width * 35 / 100, maxY = height * 35 / 100
        var left = 0, right = 0, top = 0, bottom = 0
        while left < maxX, columnDark(left) { left += 4 }
        while right < maxX, columnDark(width - 1 - right) { right += 4 }
        while top < maxY, rowDark(top) { top += 4 }
        while bottom < maxY, rowDark(height - 1 - bottom) { bottom += 4 }

        // Bis zur Grenze schwarz = (fast) leeres Bild, z. B. Ladebildschirm: keine Aussage.
        guard left < maxX, right < maxX, top < maxY, bottom < maxY else { return nil }
        // Abrunden auf 8 px: kleinerer Zuschnitt ist immer sicher, und kleines Zittern aendert nichts.
        var crop = Crop(dx: min(left, right) / 8 * 8, dy: min(top, bottom) / 8 * 8)
        // Mini-Raender (unter 4 % je Achse) ignorieren: Sie bringen kaum Bildflaeche, kosten aber bei jedem Wechsel
        // einen Encoder-Neuaufbau. Gemessen am 23.11.2026 auf dem iPhone: 8 -> 0 -> 24 -> 16 px in 6 s
        // (Statusleiste bzw. Abdunkeln beim Sperren), jedes Mal mit kurzem Bildsprung im Auto.
        if crop.dx < width * 4 / 100 { crop.dx = 0 }
        if crop.dy < height * 4 / 100 { crop.dy = 0 }
        guard width - 2 * crop.dx >= width * 4 / 10, height - 2 * crop.dy >= height * 4 / 10 else { return nil }
        return crop
    }
}
