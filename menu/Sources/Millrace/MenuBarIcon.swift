import AppKit

/// The menu-bar (status) icon: a compact wheel-with-orange-race "mini badge".
///
/// It's drawn as a self-contained rounded square (carrying its own dark
/// background) rather than a monochrome template, so the white wheel + orange
/// race stay legible on both light and dark menu bars. `inactive` (server not
/// running) is the same icon dimmed.
enum MenuBarIcon {
    static let active = render(dim: false)
    static let inactive = render(dim: true)

    private static func c(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
    }

    private static func render(dim: Bool) -> NSImage {
        let pt: CGFloat = 18, scale = 2
        let px = Int(pt) * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let g = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        draw(g.cgContext, CGFloat(px), dim: dim)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: pt, height: pt))
        img.addRepresentation(rep)
        img.isTemplate = false   // keep the colour; do not let the system tint it
        return img
    }

    private static func draw(_ cg: CGContext, _ S: CGFloat, dim: Bool) {
        let bgTop = c(40,74,92), bgBot = c(18,38,50)
        let wheel = c(245,248,252), wheelShade = c(206,218,230)
        let accent = c(255,122,28), accentLite = c(255,176,92)
        let space = CGColorSpaceCreateDeviceRGB()
        cg.setAllowsAntialiasing(true)
        if dim { cg.setAlpha(0.55) }

        let pad = S * 0.045
        let rect = CGRect(x: pad, y: pad, width: S - 2*pad, height: S - 2*pad)
        let sq = CGPath(roundedRect: rect, cornerWidth: rect.width*0.28, cornerHeight: rect.width*0.28, transform: nil)
        cg.saveGState(); cg.addPath(sq); cg.clip()
        let bg = CGGradient(colorsSpace: space, colors: [bgTop.cgColor, bgBot.cgColor] as CFArray, locations: [0,1])!
        cg.drawLinearGradient(bg, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.minY), options: [])

        let cx = S*0.5, cy = pad + rect.width*0.57, content = rect.width
        let Rout = content*0.33, rimT = content*0.075, Rmid = Rout - rimT/2
        let Rhub = content*0.085, spokeW = content*0.060
        func stroke(_ col: NSColor, _ w: CGFloat) { cg.setStrokeColor(col.cgColor); cg.setLineWidth(w); cg.setLineCap(.round) }

        cg.setFillColor(wheelShade.cgColor)
        let n = 4, a0 = CGFloat.pi*1.20, a1 = CGFloat.pi*1.80
        for i in 0..<n {
            let a = a0 + (a1-a0)*CGFloat(i)/CGFloat(n-1)
            let ur = (cos(a), sin(a)), ut = (-sin(a), cos(a))
            func pt(_ r: CGFloat, _ t: CGFloat) -> CGPoint { CGPoint(x: cx+ur.0*r+ut.0*t, y: cy+ur.1*r+ut.1*t) }
            let bw = content*0.13, base = Rout - rimT*0.2, outer = Rout + content*0.06
            let p = CGMutablePath(); p.move(to: pt(base, bw/2)); p.addLine(to: pt(base, -bw/2))
            p.addLine(to: pt(outer, -bw/2)); p.addLine(to: pt(outer, bw/2)); p.closeSubpath()
            cg.addPath(p); cg.fillPath()
        }
        for i in 0..<6 {
            let a = CGFloat(i)/6*2 * .pi; stroke(wheel, spokeW)
            cg.beginPath(); cg.move(to: CGPoint(x: cx+cos(a)*Rhub*0.5, y: cy+sin(a)*Rhub*0.5))
            cg.addLine(to: CGPoint(x: cx+cos(a)*(Rmid-rimT*0.2), y: cy+sin(a)*(Rmid-rimT*0.2))); cg.strokePath()
        }
        stroke(wheel, rimT)
        cg.beginPath(); cg.addEllipse(in: CGRect(x: cx-Rmid, y: cy-Rmid, width: 2*Rmid, height: 2*Rmid)); cg.strokePath()
        cg.setFillColor(wheel.cgColor); cg.fillEllipse(in: CGRect(x: cx-Rhub, y: cy-Rhub, width: 2*Rhub, height: 2*Rhub))
        cg.setFillColor(accent.cgColor); cg.fillEllipse(in: CGRect(x: cx-Rhub*0.42, y: cy-Rhub*0.42, width: Rhub*0.84, height: Rhub*0.84))

        let wy = pad + content*0.26
        let w = CGMutablePath(); w.move(to: CGPoint(x: rect.minX, y: wy))
        w.addQuadCurve(to: CGPoint(x: rect.midX, y: wy), control: CGPoint(x: rect.minX+rect.width*0.25, y: wy+content*0.03))
        w.addQuadCurve(to: CGPoint(x: rect.maxX, y: wy), control: CGPoint(x: rect.minX+rect.width*0.75, y: wy-content*0.03))
        w.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); w.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); w.closeSubpath()
        cg.saveGState(); cg.addPath(w); cg.clip()
        let wg = CGGradient(colorsSpace: space, colors: [accentLite.cgColor, accent.cgColor] as CFArray, locations: [0,1])!
        cg.drawLinearGradient(wg, start: CGPoint(x: rect.midX, y: wy), end: CGPoint(x: rect.midX, y: rect.minY), options: [])
        cg.restoreGState()
        cg.restoreGState()
    }
}
