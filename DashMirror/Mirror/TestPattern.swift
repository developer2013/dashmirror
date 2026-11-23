//
//  TestPattern.swift
//  DashMirror
//
//  Testbild durch die komplette Kette: zeichnen -> MirrorStreamer (derselbe Code wie in der Erweiterung)
//  -> Unix-Socket -> Empfang -> Anzeige. Prueft alles ausser ReplayKit selbst – auch im Simulator
//  und am Schreibtisch mit dem CarPlay Simulator.
//
//  Absichtlich wie ReplayKit bei quer gehaltenem iPhone: Der Puffer ist HOCHKANT, das Querformat-Bild
//  liegt darin um 90 Grad gedreht, und die Ausrichtung sagt ".right" (EXIF 6 = zum Anzeigen 90 Grad im
//  Uhrzeigersinn drehen). Steht "↑ oben" auf dem Display aufrecht und lesbar, stimmt die Drehung.
//

import CoreVideo
import UIKit

nonisolated final class TestPattern: @unchecked Sendable {
    private let streamer: MirrorStreamer
    private let queue = DispatchQueue(label: "mirror.testpattern", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var frame = 0
    private let started = Mirror.now()
    /// Querformat wie ein iPhone 16 Pro (2556x1179), verkleinert. Der Puffer selbst ist hochkant.
    private let landscape = CGSize(width: 1560, height: 720)

    init?(settings: MirrorSettings) {
        guard let streamer = MirrorStreamer(settings: settings, source: .testPattern) else { return nil }
        self.streamer = streamer
    }

    func start() {
        streamer.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in self?.render() }
        timer.resume()
        self.timer = timer
        MirrorLog.write("Testbild: an")
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            streamer.stop()
            MirrorLog.write("Testbild: aus")
        }
    }

    private func render() {
        guard streamer.sender.isConnected else { return }
        let width = Int(landscape.height), height = Int(landscape.width)
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            // UIKit-Koordinaten (y nach unten) auf dem Hochkant-Puffer ...
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            // ... und das Querformat 90 Grad GEGEN den Uhrzeigersinn hineinlegen (EXIF 6):
            // Anzeige-Punkt (x, y) -> Puffer-Punkt (y, L - x), L = Breite des Querformats.
            context.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: landscape.width))
            draw(in: context, size: landscape)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        frame += 1
        streamer.push(buffer, orientation: 6, captureTime: Mirror.now())
    }

    private func draw(in context: CGContext, size full: CGSize) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        // Wie ein 16:9-Spiel auf dem breiteren iPhone: links und rechts schwarze Streifen. Ist "Raender abschneiden"
        // an, muessen sie im Auto verschwinden (Encoder: "Raender abgeschnitten: ... Inhalt 720x1280").
        UIColor.black.setFill()
        UIRectFill(CGRect(origin: .zero, size: full))
        let contentWidth = (full.height * 16 / 9).rounded()
        context.translateBy(x: ((full.width - contentWidth) / 2).rounded(), y: 0)
        let size = CGSize(width: contentWidth, height: full.height)

        // Farbbalken (ohne Schwarz – sonst saehe der rechte Rand selbst wie ein schwarzer Streifen aus)
        let colors: [UIColor] = [.white, .systemYellow, .cyan, .systemGreen, .magenta, .systemRed, .systemBlue, .darkGray]
        let barWidth = size.width / CGFloat(colors.count)
        for (index, color) in colors.enumerated() {
            color.setFill()
            UIRectFill(CGRect(x: CGFloat(index) * barWidth, y: 0, width: barWidth + 1, height: size.height))
        }

        // Laufender Balken: Ruckeln und Aussetzer sieht man sofort.
        let seconds = Double(Mirror.now() - started) / 1_000_000_000
        let x = CGFloat((seconds * 500).truncatingRemainder(dividingBy: Double(size.width - 40)))
        UIColor(white: 0.25, alpha: 1).setFill()
        UIRectFill(CGRect(x: 0, y: size.height * 0.7, width: size.width, height: size.height * 0.3))
        UIColor.white.setFill()
        UIRectFill(CGRect(x: x, y: size.height * 0.7, width: 40, height: size.height * 0.3))

        let big: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 72, weight: .heavy),
            .foregroundColor: UIColor.white,
            .backgroundColor: UIColor.black.withAlphaComponent(0.75),
        ]
        let small: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 40, weight: .bold),
            .foregroundColor: UIColor.white,
            .backgroundColor: UIColor.black.withAlphaComponent(0.75),
        ]
        (" ↑ oben – TESTBILD " as NSString).draw(at: CGPoint(x: size.width * 0.2, y: 40), withAttributes: big)
        (String(format: " Bild %d · %.1f s ", frame, seconds) as NSString)
            .draw(at: CGPoint(x: size.width * 0.3, y: 160), withAttributes: small)
        // Ecken: zeigen, ob das Bild gespiegelt statt gedreht ankommt.
        (" links oben " as NSString).draw(at: CGPoint(x: 12, y: 12), withAttributes: small)
        let corner = " rechts unten " as NSString
        let cornerSize = corner.size(withAttributes: small)
        corner.draw(at: CGPoint(x: size.width - cornerSize.width - 12, y: size.height - cornerSize.height - 12),
                    withAttributes: small)
    }
}
