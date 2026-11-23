// make-icon.swift – draws the DashMirror app icon (light, dark, tinted) as 1024x1024 PNGs.
//
//   swift scripts/make-icon.swift
//
// Motif, kept deliberately simple: a wide car display as a frame, the iPhone image lying in it in
// landscape, and a diagonal sheen across the glass – the "mirror".

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = URL(fileURLWithPath: "DashMirror/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

struct Palette {
    var background: [CGColor]      // gradient top-left -> bottom-right
    var frame: CGColor             // display outline
    var phone: [CGColor]           // gradient of the phone image
    var camera: CGColor
    var sheen: CGFloat             // opacity of the glass reflection
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gray(_ value: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: value, green: value, blue: value, alpha: alpha)
}

let palettes: [(file: String, palette: Palette)] = [
    ("AppIcon.png", Palette(background: [rgb(0x0B1430), rgb(0x1A4FD6)], frame: rgb(0xFFFFFF),
                            phone: [rgb(0x7FF0FF), rgb(0x3D8BFF)], camera: rgb(0x0B1430, 0.85), sheen: 0.16)),
    ("AppIcon-Dark.png", Palette(background: [rgb(0x05070D), rgb(0x0E1A3A)], frame: rgb(0x8CCBFF),
                                 phone: [rgb(0x5FE0FF), rgb(0x2F6BFF)], camera: rgb(0x05070D, 0.9), sheen: 0.10)),
    ("AppIcon-Tinted.png", Palette(background: [gray(0), gray(0)], frame: gray(1),
                                   phone: [gray(0.95), gray(0.6)], camera: gray(0, 0.85), sheen: 0.12)),
]

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func draw(_ palette: Palette) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Background (iOS rounds the corners itself – fill the whole square).
    let background = CGGradient(colorsSpace: space, colors: palette.background as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: CGFloat(size), y: 0),
                           options: [])

    // Car display: wide, free-floating frame (no stand – a stand made it read as a TV), centered.
    let display = CGRect(x: 122, y: 287, width: 780, height: 450)
    let inner = display.insetBy(dx: 27, dy: 27)

    // Glass reflection: a diagonal band, clipped to the display's inside.
    ctx.saveGState()
    ctx.addPath(roundedRect(inner, 68))
    ctx.clip()
    ctx.setFillColor(gray(1, palette.sheen))
    ctx.move(to: CGPoint(x: inner.minX + 120, y: inner.maxY))
    ctx.addLine(to: CGPoint(x: inner.minX + 380, y: inner.maxY))
    ctx.addLine(to: CGPoint(x: inner.minX + 120, y: inner.minY))
    ctx.addLine(to: CGPoint(x: inner.minX - 140, y: inner.minY))
    ctx.closePath()
    ctx.fillPath()
    ctx.restoreGState()

    // The iPhone image, landscape, centered in the display.
    let phone = CGRect(x: display.midX - 230, y: display.midY - 112, width: 460, height: 224)
    ctx.saveGState()
    ctx.addPath(roundedRect(phone, 56))
    ctx.clip()
    let phoneGradient = CGGradient(colorsSpace: space, colors: palette.phone as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(phoneGradient, start: CGPoint(x: phone.minX, y: phone.maxY),
                           end: CGPoint(x: phone.maxX, y: phone.minY), options: [])
    ctx.restoreGState()
    // Camera pill on the left edge, like a phone held in landscape.
    ctx.setFillColor(palette.camera)
    ctx.addPath(roundedRect(CGRect(x: phone.minX + 26, y: phone.midY - 38, width: 22, height: 76), 11))
    ctx.fillPath()

    // Display frame on top (stroke centered on the path: 27 px inwards, 27 px outwards).
    ctx.setStrokeColor(palette.frame)
    ctx.setLineWidth(54)
    ctx.addPath(roundedRect(display.insetBy(dx: 27, dy: 27), 82))
    ctx.strokePath()

    return ctx.makeImage()!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (file, palette) in palettes {
    let url = output.appendingPathComponent(file)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, draw(palette), nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("PNG not written: \(url.path)") }
    print("written:", url.path)
}
