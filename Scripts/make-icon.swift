import AppKit

// Renders Resources/AppIcon.icns: the Hatrack menu bar mark (Sources/BarIcon.swift),
// drawn in white on a dark tile.
//
//   swiftc -O Scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon /tmp/out
//   iconutil -c icns /tmp/out/AppIcon.iconset -o Resources/AppIcon.icns

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)

/// Same geometry as Sources/BarIcon.swift.
func spark(center c: CGPoint, radius R: CGFloat, rays: Int, seed: Int, color: NSColor) {
    let lengths: [CGFloat] = [1.0, 0.84, 0.96, 0.78, 0.92, 0.86, 1.0, 0.8, 0.94, 0.82, 0.9, 0.88]
    let jitter: [CGFloat] = [0, 0.05, -0.04, 0.04, -0.05, 0.03, -0.02, 0.05, -0.04, 0.02, -0.03, 0.04]
    color.setFill()
    let w = R * 0.15
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

func draw(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px), flipped: false) { r in
        let s = r.width
        // macOS icon grid: the tile fills ~80% of the canvas.
        let tileRect = r.insetBy(dx: s * 0.1, dy: s * 0.1)
        let tile = NSBezierPath(roundedRect: tileRect, xRadius: s * 0.18, yRadius: s * 0.18)
        NSGradient(starting: NSColor(white: 0.17, alpha: 1), ending: NSColor(white: 0.06, alpha: 1))!.draw(in: tile, angle: -90)
        NSColor(white: 1, alpha: 0.08).setStroke(); tile.lineWidth = max(1, s * 0.004); tile.stroke()

        // The menu bar mark, same layout as BarIcon, scaled into a box inside the tile.
        let box = s * 0.50, ox = (s - box) / 2, oy = (s - box) / 2
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * box, y: oy + y * box) }
        spark(center: p(0.42, 0.58), radius: box * 0.40, rays: 12, seed: 0, color: .white)
        let small = p(0.79, 0.21), smallR = box * 0.20, gap = smallR * 1.42
        // Cut a gap around the badge by repainting the tile gradient inside that circle.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: NSRect(x: small.x - gap, y: small.y - gap, width: gap * 2, height: gap * 2)).addClip()
        NSGradient(starting: NSColor(white: 0.17, alpha: 1), ending: NSColor(white: 0.06, alpha: 1))!.draw(in: tile, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        spark(center: small, radius: smallR, rays: 8, seed: 5, color: .white)
        return true
    }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

for (n, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(n).png"))
}
print("wrote \(set)")
