import AppKit

/// Menu bar mark: a Claude style spark (thick rounded rays of uneven length) with a small
/// second spark as a badge in the lower right, cut out with a gap: "more than one account".
/// Template image, so macOS tints it like every other menu bar icon.
enum BarIcon {
    static func make(size: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let s = r.width
            let big = CGPoint(x: s * 0.42, y: s * 0.58), bigR = s * 0.40
            let small = CGPoint(x: s * 0.79, y: s * 0.21), smallR = s * 0.20
            spark(center: big, radius: bigR, rays: 12, seed: 0)
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.saveGState()
                ctx.setBlendMode(.clear)
                let g = smallR * 1.42
                ctx.fillEllipse(in: CGRect(x: small.x - g, y: small.y - g, width: g * 2, height: g * 2))
                ctx.restoreGState()
            }
            spark(center: small, radius: smallR, rays: 8, seed: 5)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Hatrack"
        return img
    }

    private static func spark(center c: CGPoint, radius R: CGFloat, rays: Int, seed: Int) {
        let lengths: [CGFloat] = [1.0, 0.84, 0.96, 0.78, 0.92, 0.86, 1.0, 0.8, 0.94, 0.82, 0.9, 0.88]
        let jitter: [CGFloat] = [0, 0.05, -0.04, 0.04, -0.05, 0.03, -0.02, 0.05, -0.04, 0.02, -0.03, 0.04]
        NSColor.black.setFill()
        let w = R * 0.15  // ray half width
        for i in 0..<rays {
            let k = (i + seed) % lengths.count
            let a = CGFloat(i) / CGFloat(rays) * 2 * .pi + .pi / 2 + jitter[k]
            let len = R * lengths[k]
            let dir = CGPoint(x: cos(a), y: sin(a))
            let n = CGPoint(x: -dir.y, y: dir.x)
            let tipW = w * 0.62
            let tip = CGPoint(x: c.x + dir.x * (len - tipW), y: c.y + dir.y * (len - tipW))
            let ray = NSBezierPath()
            ray.move(to: CGPoint(x: c.x + n.x * w, y: c.y + n.y * w))
            ray.line(to: CGPoint(x: tip.x + n.x * tipW, y: tip.y + n.y * tipW))
            let deg = a * 180 / .pi
            ray.appendArc(withCenter: tip, radius: tipW, startAngle: deg + 90, endAngle: deg - 90, clockwise: true)
            ray.line(to: CGPoint(x: c.x - n.x * w, y: c.y - n.y * w))
            ray.close()
            ray.fill()
        }
        NSBezierPath(ovalIn: NSRect(x: c.x - R * 0.26, y: c.y - R * 0.26, width: R * 0.52, height: R * 0.52)).fill()
    }
}
