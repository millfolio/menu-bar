#!/usr/bin/env swift
//
// Generates the Millrace app icon — a water drop (matching the menu-bar `drop`
// glyph) on a blue gradient squircle — and assembles Millrace.icns.
//
// Pure AppKit/CoreGraphics, so it needs no design tools. Run from installer/:
//   swift make_icon.swift          # writes Millrace.iconset/, Millrace.png, Millrace.icns
//
import AppKit

// ── palette (water / millrace) ──────────────────────────────────────────────
func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}
let bgTop = rgb(255, 138, 61)     // warm orange (Mojo flame)
let bgBot = rgb(230, 50, 23)      // deep red-orange
let dropTop = rgb(255, 255, 255)  // white
let dropBot = rgb(255, 235, 224)  // faint warm-white

// Teardrop path (apex up), bottom-circle centered at (cx, cy0), radius R, apex
// A above the circle centre.
func dropPath(cx: CGFloat, cy0: CGFloat, R: CGFloat, A: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let apex = CGPoint(x: cx, y: cy0 + A)
    p.move(to: apex)
    // left flank: apex -> left of circle
    p.addCurve(to: CGPoint(x: cx - R, y: cy0),
               control1: CGPoint(x: cx - R * 0.50, y: cy0 + A * 0.55),
               control2: CGPoint(x: cx - R, y: cy0 + R * 0.95))
    // bottom semicircle: left -> bottom -> right (through cy0 - R)
    p.addArc(center: CGPoint(x: cx, y: cy0), radius: R,
             startAngle: .pi, endAngle: 0, clockwise: false)
    // right flank: right of circle -> apex
    p.addCurve(to: apex,
               control1: CGPoint(x: cx + R, y: cy0 + R * 0.95),
               control2: CGPoint(x: cx + R * 0.50, y: cy0 + A * 0.55))
    p.closeSubpath()
    return p
}

func renderPNG(size: Int) -> Data {
    let S = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.setAllowsAntialiasing(true)
    cg.interpolationQuality = .high

    // macOS-style floating rounded square: inset content, soft shadow.
    let pad = S * 0.085
    let rect = CGRect(x: pad, y: pad, width: S - 2*pad, height: S - 2*pad)
    let corner = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // ambient shadow under the squircle
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -S*0.012), blur: S*0.05,
                 color: NSColor(white: 0, alpha: 0.28).cgColor)
    cg.addPath(squircle); cg.setFillColor(NSColor.white.cgColor); cg.fillPath()
    cg.restoreGState()

    // background gradient, clipped to the squircle
    cg.saveGState()
    cg.addPath(squircle); cg.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let bg = CGGradient(colorsSpace: space, colors: [bgTop.cgColor, bgBot.cgColor] as CFArray,
                        locations: [0, 1])!
    cg.drawLinearGradient(bg, start: CGPoint(x: rect.minX, y: rect.maxY),
                          end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // subtle top gloss
    let gloss = CGGradient(colorsSpace: space,
                           colors: [NSColor(white: 1, alpha: 0.18).cgColor,
                                    NSColor(white: 1, alpha: 0).cgColor] as CFArray,
                           locations: [0, 1])!
    cg.drawLinearGradient(gloss, start: CGPoint(x: rect.midX, y: rect.maxY),
                          end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    cg.restoreGState()

    // water drop
    let content = rect.width
    let R = content * 0.205
    let A = content * 0.44
    let cx = S/2
    let cy0 = S*0.435                      // circle centre; apex reaches well above
    let drop = dropPath(cx: cx, cy0: cy0, R: R, A: A)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -S*0.006), blur: S*0.02,
                 color: NSColor(srgbRed: 0.35, green: 0.08, blue: 0.0, alpha: 0.35).cgColor)
    cg.addPath(drop); cg.clip()
    let dg = CGGradient(colorsSpace: space, colors: [dropTop.cgColor, dropBot.cgColor] as CFArray,
                        locations: [0, 1])!
    cg.drawLinearGradient(dg, start: CGPoint(x: cx, y: cy0 + A),
                          end: CGPoint(x: cx, y: cy0 - R), options: [])
    cg.restoreGState()

    // small specular highlight on the drop
    cg.saveGState()
    cg.addPath(drop); cg.clip()
    let hi = CGRect(x: cx - R*0.55, y: cy0 - R*0.35, width: R*0.5, height: R*0.95)
    cg.setFillColor(NSColor(white: 1, alpha: 0.65).cgColor)
    cg.fillEllipse(in: hi)
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// ── emit iconset + master png ───────────────────────────────────────────────
let fm = FileManager.default
let iconset = "Millrace.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    try! renderPNG(size: px).write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
try! renderPNG(size: 1024).write(to: URL(fileURLWithPath: "Millrace.png"))   // docs/preview
print("wrote \(iconset)/ and Millrace.png")
