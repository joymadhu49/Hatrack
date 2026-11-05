import AppKit
import SwiftUI

enum Palette {
    static let track = Color.primary.opacity(0.10)
    static let dim = Color.secondary
    static let accent = Color(red: 0.45, green: 0.58, blue: 1.0)
    static let ok = Color(red: 0.36, green: 0.80, blue: 0.56)
    static let warn = Color(red: 0.96, green: 0.72, blue: 0.32)
    static let bad = Color(red: 0.96, green: 0.40, blue: 0.40)

    /// Colour by what is LEFT: calm while there is room, amber under 30%, red under 10%.
    static func fill(left: Double, active: Bool) -> Color {
        left <= 10 ? bad : left <= 30 ? warn : (active ? accent : Color.primary.opacity(0.7))
    }
}

enum Fmt {
    /// "Resets in 3 hours 30 min, tomorrow at 2:49 AM" / "Resets in 5 days 13 hours, Tuesday at 12:59 PM"
    static func reset(_ d: Date?, now: Date = Date()) -> String {
        guard let d else { return "" }
        let secs = d.timeIntervalSince(now)
        if secs <= 0 { return "Resetting now" }
        let cal = Calendar.current
        let t = DateFormatter(); t.dateFormat = "h:mm a"
        let day: String
        if cal.isDate(d, inSameDayAs: now) { day = "today" }
        else if let tm = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: tm) { day = "tomorrow" }
        else { let w = DateFormatter(); w.dateFormat = "EEEE, MMM d"; day = w.string(from: d) }
        return "Resets in \(long(secs)), \(day) at \(t.string(from: d))"
    }

    /// ("5 days 13 hours", "Tuesday, Nov 10 at 1:00 PM")
    static func resetParts(_ d: Date?, now: Date = Date()) -> (String, String)? {
        guard let d else { return nil }
        let secs = d.timeIntervalSince(now)
        if secs <= 0 { return ("now", "") }
        let cal = Calendar.current
        let t = DateFormatter(); t.dateFormat = "h:mm a"
        let day: String
        if cal.isDate(d, inSameDayAs: now) { day = "Today" }
        else if let tm = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: tm) { day = "Tomorrow" }
        else { let w = DateFormatter(); w.dateFormat = "EEEE, MMM d"; day = w.string(from: d) }
        return (long(secs), "\(day) at \(t.string(from: d))")
    }

    static func long(_ s: TimeInterval) -> String {
        let m = Int(s / 60), h = m / 60, d = h / 24
        func u(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }
        if d > 0 { return h % 24 > 0 ? "\(u(d, "day")) \(u(h % 24, "hour"))" : u(d, "day") }
        if h > 0 { return m % 60 > 0 ? "\(u(h, "hour")) \(m % 60) min" : u(h, "hour") }
        return "\(max(1, m)) min"
    }

    static func countdown(_ s: TimeInterval) -> String {
        let m = Int(s / 60), h = m / 60, d = h / 24
        if d > 0 { return "\(d)d \(h % 24)h" }
        if h > 0 { return "\(h)h \(m % 60)m" }
        return "\(max(1, m))m"
    }

    static func ago(_ d: Date?) -> String {
        guard let d else { return "never" }
        let s = Date().timeIntervalSince(d)
        if s < 60 { return "just now" }
        return "\(countdown(s)) ago"
    }

    static func plan(_ p: String?) -> String? {
        guard let p, !p.isEmpty else { return nil }
        return p.prefix(1).uppercased() + p.dropFirst()
    }
}

struct PanelView: View {
    @ObservedObject var store: Store
    @ObservedObject var login: LoginRunner
    @State private var adding = false
    @State private var email = ""
    @State private var code = ""
    @State private var renaming: String?
    @State private var renameText = ""
    var now: Date = Date()

    init(store: Store, now: Date = Date()) {
        self.store = store
        self.login = store.login
        self.now = now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let e = store.errorText { banner(e, color: Palette.bad) }
            else if let n = store.notice { banner(n, color: Palette.accent) }

            VStack(spacing: 8) {
                if login.running || adding { addSection }
                list
            }
            .glassGroup(spacing: 8)

            sessionsSection
        }
        .padding(10)
        .frame(width: 300)
        .onChange(of: store.notice) { _, n in
            guard let n else { return }
            if n.hasPrefix("Added") { adding = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if store.notice == n { store.notice = nil } }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Hatrack").font(.system(size: 13, weight: .semibold))
            Spacer()
            if store.working { ProgressView().controlSize(.mini) }
            Button { adding.toggle() } label: { Image(systemName: adding ? "xmark" : "plus") }
                .buttonStyle(GlassIcon())
                .help("Add account")
            Button { Task { await store.tick(forceUsage: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(GlassIcon())
                .help("Refresh usage")
            Menu {
                Picker("Menu bar shows", selection: $store.barStyle) {
                    Text("Weekly left").tag("week")
                    Text("Session left").tag("session")
                    Text("Icon only").tag("icon")
                }
                Picker("Open sessions in", selection: $store.terminal) {
                    Text("Ghostty").tag("Ghostty")
                    Text("Terminal").tag("Terminal")
                }
                Divider()
                Button("Restart idle sessions") { store.restartSessions(store.sessions.filter { !$0.isBusy }) }
                    .disabled(store.sessions.filter { !$0.isBusy }.isEmpty)
                Button("Open accounts folder") { NSWorkspace.shared.open(Store.supportDir) }
                Button("Quit Hatrack") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .glassCapsule()
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
        .padding(.leading, 4)
    }

    private func banner(_ text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(text).font(.system(size: 10.5)).lineLimit(2)
            Spacer(minLength: 0)
            Button { store.notice = nil; store.errorText = nil } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .glass(10, tint: color.opacity(0.18))
    }

    // MARK: Accounts

    private var list: some View {
        VStack(spacing: 0) {
            if store.accounts.isEmpty {
                Text("Your Claude Code login is added automatically.")
                    .font(.system(size: 11)).foregroundStyle(Palette.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            ForEach(Array(store.accounts.enumerated()), id: \.element.id) { i, a in
                if i > 0 { Divider().opacity(0.5).padding(.horizontal, 10) }
                row(a)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .glass(14)
    }

    /// Muted, stable hue per account so rows are easy to tell apart at a glance.
    private func hue(_ a: Account) -> Color {
        let hues: [Double] = [0.62, 0.08, 0.40, 0.78, 0.52, 0.95, 0.15]
        let h = a.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: hues[h % hues.count], saturation: 0.45, brightness: 0.85)
    }

    private func row(_ a: Account) -> some View {
        let isActive = a.id == store.activeID
        let week = a.usage?.week
        let session = a.usage?.session
        let weekOut = (week?.left ?? 1) <= 0
        let usable = !a.signedOut && !weekOut && (session?.left ?? 1) > 0
        let color = hue(a)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(String((a.label?.isEmpty == false ? a.label! : a.email).prefix(1)).uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(color.gradient))
                    .overlay(alignment: .bottomTrailing) {
                        if isActive {
                            Circle().fill(Palette.ok).frame(width: 7, height: 7)
                                .overlay(Circle().strokeBorder(.black.opacity(0.35), lineWidth: 1))
                                .offset(x: 1, y: 1)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    if renaming == a.id {
                        TextField("Label", text: $renameText, onCommit: { store.rename(a.id, to: renameText); renaming = nil })
                            .textFieldStyle(.plain).font(.system(size: 11.5, weight: .medium))
                    } else {
                        Text(a.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.tail)
                    }
                    HStack(spacing: 4) {
                        if let p = Fmt.plan(a.plan) { Text(p) }
                        if isActive { Text("·"); Text("In use").foregroundStyle(Palette.ok) }
                        else if a.usageAt != nil { Text("·"); Text("updated \(Fmt.ago(a.usageAt))") }
                    }
                    .font(.system(size: 9.5, weight: .medium)).foregroundStyle(Palette.dim)
                }
                Spacer(minLength: 4)
                if !isActive {
                    Button("Switch") { Task { await store.switchTo(a.id) } }
                        .buttonStyle(GlassPill(prominent: usable, small: true))
                        .disabled(store.working || a.signedOut)
                        .help(usable ? "Use this account in Claude Code" : "This account has no usage left right now")
                }
            }

            if a.signedOut {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(Palette.bad)
                    Text("Signed out").font(.system(size: 10, weight: .medium))
                    Spacer(minLength: 0)
                    Button("Sign in") { email = a.email; adding = true; store.startLogin(email: a.email) }
                        .buttonStyle(GlassPill(small: true))
                }
            } else if weekOut, let w = week {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass").font(.system(size: 10)).foregroundStyle(Palette.warn)
                    Text("Week used up").font(.system(size: 10.5, weight: .medium)).lineLimit(1).fixedSize()
                    Spacer(minLength: 4)
                    if let (inText, atText) = Fmt.resetParts(w.resetsAt, now: now) {
                        Text("back in \(inText)").font(.system(size: 10)).foregroundStyle(Palette.dim).help(atText)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.warn.opacity(0.10)))
            } else if a.usage != nil {
                HStack(spacing: 12) {
                    mini("Week", week, active: isActive)
                    mini("Session", session, active: isActive)
                }
                if let w = week, let (inText, atText) = Fmt.resetParts(w.resetsAt, now: now) {
                    Text("Week resets in \(inText)")
                        .font(.system(size: 9.5)).foregroundStyle(Palette.dim)
                        .help(atText)
                }
            } else if let e = a.error {
                Text(e).font(.system(size: 10)).foregroundStyle(Palette.dim).lineLimit(1)
            } else {
                Text("Loading usage").font(.system(size: 10)).foregroundStyle(Palette.dim)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(isActive ? Palette.accent.opacity(0.09) : .clear)
        .opacity(!isActive && !usable ? 0.82 : 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Rename") { renameText = a.label ?? ""; renaming = a.id }
            Button("Refresh usage") { Task { await store.refreshUsage(for: a.id, live: Keychain.readLiveBlob()?["claudeAiOauth"] as? [String: Any]) } }
            Button("Move up") { store.move(a.id, by: -1) }
            Button("Move down") { store.move(a.id, by: 1) }
            Divider()
            Button("Remove from Hatrack") { store.remove(a.id) }.disabled(isActive)
        }
    }

    /// "Week  81%" over a thin bar.
    private func mini(_ title: String, _ l: Limit?, active: Bool) -> some View {
        let left = l?.left ?? 0
        let color = Palette.fill(left: left, active: active)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Palette.dim)
                Spacer(minLength: 0)
                Text(l == nil ? "n/a" : "\(Int(left.rounded()))%")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(left <= 30 ? color : .primary.opacity(0.9))
            }
            bar(left, color: color, height: 3)
        }
        .frame(maxWidth: .infinity)
    }

    private func bar(_ left: Double, color: Color, height: CGFloat) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color)
                    .frame(width: max(height, min(1, left / 100) * g.size.width))
                    .opacity(left <= 0 ? 0 : 1)
            }
        }
        .frame(height: height)
    }

    // MARK: Add account

    @ViewBuilder
    private var addSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            if login.running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Finish signing in in your browser").font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 0)
                    Button("Cancel") { login.cancel(); adding = false }.buttonStyle(GlassPill(small: true))
                }
                HStack(spacing: 6) {
                    TextField("Paste code if asked", text: $code)
                        .textFieldStyle(.plain).font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .glassCapsule(interactive: false)
                    Button("Submit") { login.submit(code: code); code = "" }
                        .buttonStyle(GlassPill(prominent: true, small: true)).disabled(code.isEmpty)
                    if let u = login.url {
                        Button { NSWorkspace.shared.open(u) } label: { Image(systemName: "arrow.up.right") }
                            .buttonStyle(GlassIcon()).help("Open sign in link")
                    }
                }
            } else {
                Text("Add an account").font(.system(size: 11, weight: .semibold))
                HStack(spacing: 6) {
                    TextField("Email (optional)", text: $email)
                        .textFieldStyle(.plain).font(.system(size: 11))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .glassCapsule(interactive: false)
                    Button("Sign in") { store.startLogin(email: email) }
                        .buttonStyle(GlassPill(prominent: true, small: true))
                }
                Text("Use the browser profile signed in to that account.")
                    .font(.system(size: 9.5)).foregroundStyle(Palette.dim)
            }
        }
        .padding(10)
        .glass(14)
    }

    // MARK: Sessions

    @ViewBuilder
    private var sessionsSection: some View {
        if !store.sessions.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(Palette.dim)
                Text(store.sessions.count == 1 ? "1 open session switches on its next message"
                                               : "\(store.sessions.count) open sessions switch on their next message")
                    .font(.system(size: 10)).foregroundStyle(Palette.dim).lineLimit(1).minimumScaleFactor(0.9)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
        }
    }
}
