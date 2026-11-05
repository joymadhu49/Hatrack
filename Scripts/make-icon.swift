import AppKit
// Renders Resources/AppIcon.icns: a dark rounded tile with two stacked account cards.
let out = CommandLine.arguments[1]
let set = out + "/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
func draw(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px), flipped: false) { r in
        let s = r.width
        let tile = NSBezierPath(roundedRect: r.insetBy(dx: s*0.1, dy: s*0.1), xRadius: s*0.18, yRadius: s*0.18)
        NSGradient(starting: NSColor(white: 0.17, alpha: 1), ending: NSColor(white: 0.07, alpha: 1))!.draw(in: tile, angle: -90)
        NSColor(white: 1, alpha: 0.08).setStroke(); tile.lineWidth = s*0.006; tile.stroke()
        func card(_ y: CGFloat, _ c: NSColor, _ fill: CGFloat) {
            let rr = NSRect(x: s*0.25, y: y, width: s*0.5, height: s*0.17)
            let p = NSBezierPath(roundedRect: rr, xRadius: s*0.04, yRadius: s*0.04)
            NSColor(white: 1, alpha: 0.07).setFill(); p.fill()
            let dot = NSBezierPath(ovalIn: NSRect(x: rr.minX+s*0.035, y: rr.midY-s*0.04, width: s*0.08, height: s*0.08))
            c.setFill(); dot.fill()
            let track = NSRect(x: rr.minX+s*0.15, y: rr.midY-s*0.012, width: s*0.3, height: s*0.024)
            NSColor(white: 1, alpha: 0.12).setFill(); NSBezierPath(roundedRect: track, xRadius: s*0.012, yRadius: s*0.012).fill()
            var f = track; f.size.width *= fill
            c.setFill(); NSBezierPath(roundedRect: f, xRadius: s*0.012, yRadius: s*0.012).fill()
        }
        card(s*0.54, NSColor(red: 0.42, green: 0.55, blue: 1, alpha: 1), 0.8)
        card(s*0.30, NSColor(white: 0.62, alpha: 1), 0.45)
        return true
    }
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}
for (n, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
    try! draw(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(n).png"))
}
