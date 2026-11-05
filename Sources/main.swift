import AppKit
import Combine
import SwiftUI

// Command line modes for checking the app without touching the screen:
//   Hatrack -list               accounts and usage as JSON (no tokens)
//   Hatrack -snapshot out.png   render the panel offscreen  [-light]
//   Hatrack -window out.png     render the panel in a real glass window and capture it  [-light] [-demo]
//   Hatrack -icon out.png       render the menu bar mark large, light and dark
let args = CommandLine.arguments
if args.contains("-list") {
    let s = MainActor.assumeIsolated { Store(loadOnly: true) }
    let sem = DispatchSemaphore(value: 0)
    Task { @MainActor in
        await s.tick(forceUsage: true)
        var out: [[String: Any]] = []
        for a in s.accounts {
            var row: [String: Any] = ["email": a.email, "id": a.id, "active": a.id == s.activeID, "plan": a.plan ?? ""]
            if let e = a.error { row["error"] = e }
            row["limits"] = (a.usage?.limits ?? []).map { l -> [String: Any] in
                ["kind": l.kind, "usedPercent": l.percent, "leftPercent": l.left,
                 "resetsAt": l.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""]
            }
            out.append(row)
        }
        let d = try! JSONSerialization.data(withJSONObject: ["sessions": s.sessions.count, "accounts": out], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: d, as: UTF8.self))
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

// Render the panel in a real window parked at desktop level (behind every other window)
// and capture just that window with `screencapture -l`, so glass renders for real.
if let i = args.firstIndex(of: "-window"), i + 1 < args.count {
    let path = args[i + 1]
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let s = args.contains("-demo") ? Store.demo() : Store(loadOnly: true)
        if !args.contains("-demo") {
            s.activeID = ClaudeConfig.oauthAccount()?["accountUuid"] as? String
            s.sessions = Sessions.running()
        }
        let host = NSHostingView(rootView: PanelView(store: s))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(x: 200, y: 200, width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .normal
        panel.appearance = NSAppearance(named: args.contains("-light") ? .aqua : .darkAqua)
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = 22
            g.contentView = host
            panel.contentView = g
        } else {
            let v = NSVisualEffectView(); v.material = .popover; v.state = .active
            v.wantsLayer = true; v.layer?.cornerRadius = 22
            host.frame = v.bounds; host.autoresizingMask = [.width, .height]; v.addSubview(host)
            panel.contentView = v
        }
        panel.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Shell.run("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(panel.windowNumber)", path])
            print("wrote \(path)")
            exit(0)
        }
        app.run()
    }
}

if let i = args.firstIndex(of: "-icon"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let src = BarIcon.make(size: 18)
        // 18 pt at 8x, drawn black on white and white on dark, side by side.
        let W: CGFloat = 18 * 8
        let out = NSImage(size: NSSize(width: W * 2, height: W), flipped: false) { r in
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: W, height: W).fill()
            NSColor(white: 0.12, alpha: 1).setFill(); NSRect(x: W, y: 0, width: W, height: W).fill()
            src.draw(in: NSRect(x: 0, y: 0, width: W, height: W))
            let white = NSImage(size: src.size, flipped: false) { rr in
                src.draw(in: rr); NSColor.white.set(); rr.fill(using: .sourceAtop); return true }
            white.draw(in: NSRect(x: W, y: 0, width: W, height: W))
            return true
        }
        let rep = NSBitmapImageRep(data: out.tiffRepresentation!)!
        try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
    }
    exit(0)
}

if let i = args.firstIndex(of: "-snapshot"), i + 1 < args.count {
    let path = args[i + 1]
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: args.contains("-light") ? .aqua : .darkAqua)
        let s = Store(loadOnly: true)
        s.activeID = ClaudeConfig.oauthAccount()?["accountUuid"] as? String
        s.sessions = Sessions.running()
        let view = PanelView(store: s).environment(\.colorScheme, args.contains("-light") ? .light : .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }
    }
    exit(0)
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var bag = Set<AnyCancellable>()
    var eventMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.action = #selector(toggle)
            b.target = self
            b.imagePosition = .imageLeading
        }
        popover.behavior = .transient
        popover.animates = false
        let host = NSHostingController(rootView: PanelView(store: store))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateButton() } }
            .store(in: &bag)
        updateButton()
        store.start()
    }

    func updateButton() {
        guard let b = statusItem.button else { return }
        b.image = BarIcon.make()
        var text = ""
        if let a = store.active, let u = a.usage {
            let l = store.barStyle == "session" ? u.session : store.barStyle == "week" ? u.week : nil
            if let l { text = " \(Int(l.left.rounded()))%" }
        }
        b.title = text
        b.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        b.toolTip = store.active.map { "Hatrack: \($0.title)" } ?? "Hatrack"
    }

    @objc func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let b = statusItem.button {
            store.panelOpened()
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
