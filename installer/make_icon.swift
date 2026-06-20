#!/usr/bin/env swift
//
// Generates the Millfolio app icon — a partial (half-submerged) mill water-wheel
// turning in an orange "race", on a deep slate-teal squircle — and assembles
// Millfolio.icns. Pure AppKit/CoreGraphics, so it needs no design tools.
//
//   swift make_icon.swift     # writes Millfolio.iconset/, Millfolio.png, Millfolio.icns
//
import AppKit

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: a)
}
// Cool base so the orange race/hub reads as the accent (Mojo).
let bgTop = rgb(40, 74, 92)
let bgBot = rgb(18, 38, 50)
let wheel = rgb(245, 248, 252)
let wheelShade = rgb(206, 218, 230)
let accent = rgb(255, 122, 28)     // Mojo orange — the water / race
let accentLite = rgb(255, 176, 92)

func renderPNG(size: Int) -> Data {
    let S = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
    let cg = gctx.cgContext
    cg.setAllowsAntialiasing(true); cg.interpolationQuality = .high
    let space = CGColorSpaceCreateDeviceRGB()

    let pad = S * 0.085
    let rect = CGRect(x: pad, y: pad, width: S - 2*pad, height: S - 2*pad)
    let corner = rect.width * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    let content = rect.width

    // floating-squircle shadow + background gradient
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -S*0.012), blur: S*0.05, color: rgb(0,0,0,0.28).cgColor)
    cg.addPath(squircle); cg.setFillColor(NSColor.white.cgColor); cg.fillPath()
    cg.restoreGState()
    cg.saveGState(); cg.addPath(squircle); cg.clip()
    let bg = CGGradient(colorsSpace: space, colors: [bgTop.cgColor, bgBot.cgColor] as CFArray, locations: [0,1])!
    cg.drawLinearGradient(bg, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])

    // ── wheel ─────────────────────────────────────────────────────────────────
    let cx = S * 0.5
    let cy = pad + content * 0.58
    let Rout = content * 0.32
    let rimT = content * 0.050
    let Rmid = Rout - rimT/2
    let Rhub = content * 0.072
    let spokeW = content * 0.034
    let bladeW = content * 0.090
    let bladeD = content * 0.050

    func stroke(_ c: NSColor, _ w: CGFloat) { cg.setStrokeColor(c.cgColor); cg.setLineWidth(w); cg.setLineCap(.round) }

    // paddle boards only along the lower arc — buckets dipping into the race.
    // (Boards all around read as a gear; outward spikes as a ship's helm.)
    cg.setFillColor(wheelShade.cgColor)
    let bottomBlades = 5
    let startA = CGFloat.pi * 1.18, endA = CGFloat.pi * 1.82
    for i in 0..<bottomBlades {
        let a = startA + (endA - startA) * CGFloat(i) / CGFloat(bottomBlades - 1)
        let ur = (cos(a), sin(a)), ut = (-sin(a), cos(a))
        func pt(_ rad: CGFloat, _ tan: CGFloat) -> CGPoint {
            CGPoint(x: cx + ur.0*rad + ut.0*tan, y: cy + ur.1*rad + ut.1*tan)
        }
        let base = Rout - rimT*0.2, outer = Rout + bladeD
        let blade = CGMutablePath()
        blade.move(to: pt(base, bladeW/2)); blade.addLine(to: pt(base, -bladeW/2))
        blade.addLine(to: pt(outer, -bladeW/2)); blade.addLine(to: pt(outer, bladeW/2))
        blade.closeSubpath(); cg.addPath(blade); cg.fillPath()
    }
    // spokes
    for i in 0..<8 {
        let a = CGFloat(i) / 8 * 2 * .pi
        stroke(wheel, spokeW)
        cg.beginPath()
        cg.move(to: CGPoint(x: cx + cos(a)*Rhub*0.6, y: cy + sin(a)*Rhub*0.6))
        cg.addLine(to: CGPoint(x: cx + cos(a)*(Rmid - rimT*0.2), y: cy + sin(a)*(Rmid - rimT*0.2)))
        cg.strokePath()
    }
    // rim
    stroke(wheel, rimT)
    cg.beginPath(); cg.addEllipse(in: CGRect(x: cx-Rmid, y: cy-Rmid, width: 2*Rmid, height: 2*Rmid)); cg.strokePath()
    // hub with orange centre
    cg.setFillColor(wheel.cgColor)
    cg.fillEllipse(in: CGRect(x: cx-Rhub, y: cy-Rhub, width: 2*Rhub, height: 2*Rhub))
    cg.setFillColor(accent.cgColor)
    cg.fillEllipse(in: CGRect(x: cx-Rhub*0.42, y: cy-Rhub*0.42, width: Rhub*0.84, height: Rhub*0.84))

    // ── orange race over the wheel's lower part → "partial" ────────────────
    let waterY = pad + content * 0.27
    let amp = content * 0.020
    let water = CGMutablePath()
    water.move(to: CGPoint(x: rect.minX, y: waterY))
    let segs = 4
    for i in 0..<segs {
        let x0 = rect.minX + rect.width * CGFloat(i)/CGFloat(segs)
        let x1 = rect.minX + rect.width * CGFloat(i+1)/CGFloat(segs)
        let up = (i % 2 == 0) ? amp : -amp
        water.addQuadCurve(to: CGPoint(x: x1, y: waterY), control: CGPoint(x: (x0+x1)/2, y: waterY + up))
    }
    water.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    water.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    water.closeSubpath()
    cg.saveGState(); cg.addPath(water); cg.clip()
    let wg = CGGradient(colorsSpace: space, colors: [accentLite.cgColor, accent.cgColor] as CFArray, locations: [0,1])!
    cg.drawLinearGradient(wg, start: CGPoint(x: rect.midX, y: waterY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
    cg.restoreGState()

    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// ── emit iconset + master png ───────────────────────────────────────────────
let fm = FileManager.default
let iconset = "Millfolio.iconset"
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
try! renderPNG(size: 1024).write(to: URL(fileURLWithPath: "Millfolio.png"))
print("wrote \(iconset)/ and Millfolio.png")
