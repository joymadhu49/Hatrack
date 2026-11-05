import AppKit
import CryptoKit
import Foundation
import ServiceManagement

/// Non secret account record. The tokens live in the Keychain (service "Hatrack").
struct Account: Codable, Identifiable, Hashable {
    var id: String                 // accountUuid
    var email: String
    var name: String
    var label: String?
    var plan: String?              // pro, max, team ...
    var orgName: String?
    var oauthAccountJSON: String?  // the ~/.claude.json "oauthAccount" object for this account
    var usage: Usage?
    var usageAt: Date?
    var error: String?
    var signedOut: Bool = false
    var addedAt: Date = Date()

    var title: String { (label?.isEmpty == false ? label! : nil) ?? maskedEmail }

    /// Show only the start of the name part: alexand•••@example.com
    var maskedEmail: String { Account.mask(email) }

    static func mask(_ email: String) -> String {
        let parts = email.split(separator: "@", maxSplits: 1)
        guard parts.count == 2 else { return email }
        let name = parts[0]
        let keep = min(7, max(1, name.count / 2))
        let shown = name.prefix(keep) + "\u{2022}\u{2022}\u{2022}"
        // Hide My Email addresses are long and say nothing; name the service instead.
        if parts[1].hasSuffix("privaterelay.appleid.com") { return shown + " (Apple relay)" }
        return shown + "@" + parts[1]
    }

    var oauthAccount: [String: Any]? {
        guard let s = oauthAccountJSON, let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var activeID: String?
    @Published var sessions: [ClaudeSession] = []
    @Published var notice: String?
    @Published var errorText: String?
    @Published var working = false
    @Published var lastSwitch: Date?
    @Published var terminal: String = UserDefaults.standard.string(forKey: "terminal") ?? "Ghostty" {
        didSet { UserDefaults.standard.set(terminal, forKey: "terminal") }
    }
    @Published var barStyle: String = UserDefaults.standard.string(forKey: "barStyle") ?? "week" {
        didSet { UserDefaults.standard.set(barStyle, forKey: "barStyle") }
    }

    let login = LoginRunner()
    private var vault: [String: [String: Any]] = [:]
    private var backoffUntil: [String: Date] = [:]
    private var timer: Timer?
    private var suppressConfigRepair = false

    nonisolated static var supportDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Hatrack")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var metaURL: URL { Self.supportDir.appendingPathComponent("accounts.json") }

    var active: Account? { accounts.first { $0.id == activeID } }

    /// Made up accounts for screenshots. Touches no file and no Keychain item.
    static func demo() -> Store {
        let s = Store(empty: true)
        let now = Date()
        func lim(_ k: String, _ g: String, _ used: Double, _ hours: Double) -> Limit {
            Limit(kind: k, group: g, percent: used, resetsAt: now.addingTimeInterval(hours * 3600))
        }
        s.accounts = [
            Account(id: "demo-1", email: "alex.morgan@example.com", name: "Alex", plan: "max",
                    usage: Usage(limits: [lim("session", "session", 38, 3.4), lim("weekly_all", "weekly", 22, 133)]), usageAt: now),
            Account(id: "demo-2", email: "studio@example.org", name: "Studio", label: "Studio", plan: "pro",
                    usage: Usage(limits: [lim("session", "session", 0, 4.9), lim("weekly_all", "weekly", 100, 61)]), usageAt: now),
            Account(id: "demo-3", email: "side.project@example.net", name: "Side", plan: "pro",
                    usage: Usage(limits: [lim("session", "session", 12, 1.2), lim("weekly_all", "weekly", 57, 18)]), usageAt: now),
        ]
        s.activeID = "demo-1"
        s.sessions = [ClaudeSession(pid: 1, sessionId: "", cwd: "/tmp", name: "", status: "idle"),
                      ClaudeSession(pid: 2, sessionId: "", cwd: "/tmp", name: "", status: "busy")]
        return s
    }

    private init(empty: Bool) {}

    init(loadOnly: Bool = false) {
        if let d = try? Data(contentsOf: metaURL) {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            accounts = (try? dec.decode([Account].self, from: d)) ?? []
        }
        for a in accounts { vault[a.id] = Keychain.readVault(a.id) }
        if loadOnly { return }
        login.onExit = { [weak self] _ in
            Task { @MainActor in
                self?.suppressConfigRepair = false
                await self?.afterLogin()
            }
        }
    }

    func start() {
        Task { await tick(forceUsage: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick(forceUsage: false) }
        }
        if UserDefaults.standard.object(forKey: "loginItemSet") == nil {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemSet")
        }
    }

    /// Called when the panel opens: refresh fast so the numbers are current.
    func panelOpened() {
        Task { await tick(forceUsage: false, maxAge: 90) }
    }

    func tick(forceUsage: Bool, maxAge: TimeInterval = 300) async {
        sessions = Sessions.running()
        await captureLive()
        await refreshUsage(maxAge: forceUsage ? 0 : maxAge)
    }

    private func save() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(accounts) { try? d.write(to: metaURL, options: .atomic) }
    }

    // MARK: Capture whatever Claude Code is signed in to right now

    /// Reads the live Keychain login. Known account: store its rotated tokens. Unknown
    /// login: ask the profile endpoint whose token it is and remember it. The profile call
    /// is the source of truth for identity, because ~/.claude.json can lag the Keychain
    /// while a sign in is in progress.
    func captureLive() async {
        guard let blob = Keychain.readLiveBlob(), let oauth = blob["claudeAiOauth"] as? [String: Any],
              let rt = oauth["refreshToken"] as? String else {
            activeID = nil
            return
        }
        if let id = vault.first(where: { ($0.value["refreshToken"] as? String) == rt })?.key {
            activeID = id
            repairConfigIfNeeded(for: id)
            return
        }
        // New refresh token. Either Claude Code rotated the active account's token or this
        // is a different account. Identify it.
        guard let access = oauth["accessToken"] as? String, ClaudeAPI.isFresh(oauth, margin: 10) else {
            // Token already expired, so the profile endpoint cannot name it. Outside a sign
            // in, ~/.claude.json is a safe witness; keep the rotated token for that account.
            if !login.running, !suppressConfigRepair,
               let cfgID = ClaudeConfig.oauthAccount()?["accountUuid"] as? String,
               accounts.contains(where: { $0.id == cfgID }) {
                try? Keychain.writeVault(cfgID, oauth)
                vault[cfgID] = oauth
                activeID = cfgID
            }
            return
        }
        guard let profile = try? await ClaudeAPI.profile(token: access),
              let acct = profile["account"] as? [String: Any],
              let uuid = acct["uuid"] as? String else { return }
        do { try Keychain.writeVault(uuid, oauth) } catch { errorText = error.localizedDescription; return }
        vault[uuid] = oauth

        var cfgAccount = ClaudeConfig.oauthAccount()
        if (cfgAccount?["accountUuid"] as? String) != uuid { cfgAccount = nil }
        if !accounts.contains(where: { $0.id == uuid }) { notice = "Added \(Account.mask(acct["email"] as? String ?? ""))" }
        upsert(uuid: uuid, oauth: oauth, profile: profile, cfgAccount: cfgAccount)
        activeID = uuid
        save()
        repairConfigIfNeeded(for: uuid)
    }

    private func upsert(uuid: String, oauth: [String: Any], profile: [String: Any], cfgAccount: [String: Any]?) {
        let acct = profile["account"] as? [String: Any] ?? [:]
        let org = profile["organization"] as? [String: Any] ?? [:]
        let built = cfgAccount ?? Self.oauthAccount(fromProfile: profile)
        let json = (try? JSONSerialization.data(withJSONObject: built, options: [.withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) }
        let email = acct["email"] as? String ?? "unknown"
        let plan = (oauth["subscriptionType"] as? String) ?? ((acct["has_claude_max"] as? Bool) == true ? "max" : (acct["has_claude_pro"] as? Bool) == true ? "pro" : nil)
        if let i = accounts.firstIndex(where: { $0.id == uuid }) {
            accounts[i].email = email
            accounts[i].plan = plan
            accounts[i].orgName = org["name"] as? String
            accounts[i].signedOut = false
            accounts[i].error = nil
            if cfgAccount != nil || accounts[i].oauthAccountJSON == nil { accounts[i].oauthAccountJSON = json }
        } else {
            accounts.append(Account(id: uuid, email: email,
                                    name: acct["display_name"] as? String ?? acct["full_name"] as? String ?? "",
                                    plan: plan, orgName: org["name"] as? String, oauthAccountJSON: json))
        }
        save()
    }

    /// If the Keychain holds account X but ~/.claude.json still names Y (for example a
    /// running session refreshed X after a switch), make the config match the token.
    private func repairConfigIfNeeded(for id: String) {
        guard !suppressConfigRepair, !login.running,
              let want = accounts.first(where: { $0.id == id })?.oauthAccount,
              let cur = ClaudeConfig.oauthAccount(),
              (cur["accountUuid"] as? String) != id else { return }
        try? ClaudeConfig.setOAuthAccount(want)
    }

    static func oauthAccount(fromProfile p: [String: Any]) -> [String: Any] {
        let a = p["account"] as? [String: Any] ?? [:]
        let o = p["organization"] as? [String: Any] ?? [:]
        var out: [String: Any] = [:]
        out["accountUuid"] = a["uuid"]
        out["emailAddress"] = a["email"]
        out["organizationUuid"] = o["uuid"]
        out["organizationName"] = o["name"]
        out["displayName"] = a["display_name"]
        out["fullName"] = a["full_name"]
        out["hasExtraUsageEnabled"] = o["has_extra_usage_enabled"]
        out["billingType"] = o["billing_type"]
        out["accountCreatedAt"] = a["created_at"]
        out["subscriptionCreatedAt"] = o["subscription_created_at"]
        return out.compactMapValues { $0 is NSNull ? nil : $0 }
    }

    // MARK: Usage

    func refreshUsage(maxAge: TimeInterval) async {
        let live = Keychain.readLiveBlob()?["claudeAiOauth"] as? [String: Any]
        for a in accounts {
            if let u = a.usageAt, Date().timeIntervalSince(u) < maxAge, a.error == nil { continue }
            if let b = backoffUntil[a.id], b > Date() { continue }
            await refreshUsage(for: a.id, live: live)
        }
        save()
    }

    func refreshUsage(for id: String, live: [String: Any]?) async {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        var token: String?
        if id == activeID {
            // Never refresh the active login ourselves: Claude Code owns that token and
            // rotating it underneath running sessions would sign them out.
            if let live, ClaudeAPI.isFresh(live) { token = live["accessToken"] as? String }
            if token == nil {
                accounts[idx].error = nil
                return  // Claude Code refreshes it on its next request; keep last numbers.
            }
        } else {
            guard var oauth = vault[id] else { accounts[idx].error = "No saved login"; return }
            if !ClaudeAPI.isFresh(oauth) {
                do {
                    oauth = try await ClaudeAPI.refresh(oauth)
                    try Keychain.writeVault(id, oauth)
                    vault[id] = oauth
                    accounts[idx].signedOut = false
                } catch let e as HatrackError {
                    if case .signedOut = e { accounts[idx].signedOut = true }
                    accounts[idx].error = e.localizedDescription
                    backoffUntil[id] = Date().addingTimeInterval(600)
                    return
                } catch {
                    accounts[idx].error = error.localizedDescription
                    backoffUntil[id] = Date().addingTimeInterval(300)
                    return
                }
            }
            token = oauth["accessToken"] as? String
        }
        guard let token else { return }
        do {
            let u = try await ClaudeAPI.usage(token: token)
            accounts[idx].usage = u
            accounts[idx].usageAt = Date()
            accounts[idx].error = nil
        } catch let f as ClaudeAPI.HTTPFailure {
            if f.status == 429 {
                backoffUntil[id] = Date().addingTimeInterval(max(f.retryAfter ?? 300, 120))
            } else {
                accounts[idx].error = f.status == 401 ? "Token rejected, will retry" : "Usage HTTP \(f.status)"
                backoffUntil[id] = Date().addingTimeInterval(120)
            }
        } catch {
            accounts[idx].error = "Offline"
            backoffUntil[id] = Date().addingTimeInterval(60)
        }
    }

    // MARK: Switch

    func switchTo(_ id: String) async {
        guard id != activeID, !working, let target = accounts.first(where: { $0.id == id }) else { return }
        working = true
        errorText = nil
        defer { working = false }

        // 1. Save the current account's newest tokens first so nothing is lost.
        await captureLive()

        // 2. Make sure the account we hand to Claude Code has a token with time left on it.
        guard var oauth = vault[id] else { errorText = "No saved login for \(target.title)"; return }
        if !ClaudeAPI.isFresh(oauth, margin: 600) {
            do {
                oauth = try await ClaudeAPI.refresh(oauth)
                try Keychain.writeVault(id, oauth)
                vault[id] = oauth
            } catch {
                if let i = accounts.firstIndex(where: { $0.id == id }) { accounts[i].signedOut = true }
                errorText = "\(target.title): \(error.localizedDescription)"
                return
            }
        }

        // 3. Swap the login inside Claude Code's Keychain item, under Claude Code's own lock,
        //    keeping everything that is not account specific (MCP server logins).
        do {
            try ClaudeConfig.withStorageLock {
                var blob = Keychain.readLiveBlob() ?? [:]
                blob["claudeAiOauth"] = oauth
                try Keychain.writeLiveBlob(blob)
            }
            if let acct = target.oauthAccount { try ClaudeConfig.setOAuthAccount(acct) }
            // Same signal a /login in another terminal produces: running sessions run
            // their sibling login adoption on their next request. No restart needed.
            ClaudeConfig.nudgeRunningSessions()
        } catch {
            errorText = error.localizedDescription
            return
        }

        activeID = id
        lastSwitch = Date()
        sessions = Sessions.running()
        notice = sessions.isEmpty ? "Switched to \(target.title)"
            : "Switched to \(target.title). Open sessions use it from their next message."
        await refreshUsage(for: id, live: oauth)
        save()
    }

    // MARK: Accounts

    func remove(_ id: String) {
        guard id != activeID else { return }
        Keychain.delete(service: Keychain.vaultService, account: id)
        vault[id] = nil
        accounts.removeAll { $0.id == id }
        save()
    }

    func rename(_ id: String, to label: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].label = label.trimmingCharacters(in: .whitespaces)
        save()
    }

    func move(_ id: String, by delta: Int) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard accounts.indices.contains(j) else { return }
        accounts.swapAt(i, j)
        save()
    }

    func startLogin(email: String?) {
        errorText = nil
        do { try login.start(email: email) } catch { errorText = error.localizedDescription }
    }

    /// Save the account from the private sign in. Never touches the active login.
    private func afterLogin() async {
        guard let dir = login.configDir else { return }
        let service = Keychain.claudeService + "-" + SHA256.hash(data: Data(dir.path.precomposedStringWithCanonicalMapping.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(8)
        defer {
            Keychain.delete(service: service, account: Keychain.claudeAccount)
            try? FileManager.default.removeItem(at: dir)
        }
        guard login.exitCode == 0 else { return }

        var blob: [String: Any]?
        if let d = Keychain.read(service: service, account: Keychain.claudeAccount) {
            blob = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        if blob == nil, let d = try? Data(contentsOf: dir.appendingPathComponent(".credentials.json")) {
            blob = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
        }
        guard let oauth = blob?["claudeAiOauth"] as? [String: Any], let access = oauth["accessToken"] as? String else {
            errorText = "Signed in, but Hatrack could not read the new login. Try again."
            return
        }
        guard let profile = try? await ClaudeAPI.profile(token: access),
              let acct = profile["account"] as? [String: Any], let uuid = acct["uuid"] as? String else {
            errorText = "Signed in, but could not identify the account. Try again."
            return
        }
        let email = acct["email"] as? String ?? "unknown"
        if uuid == activeID {
            notice = "\(Account.mask(email)) is the account already in use."
            return
        }
        var cfg: [String: Any]?
        if let d = try? Data(contentsOf: dir.appendingPathComponent(".claude.json")),
           let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let o = root["oauthAccount"] as? [String: Any], (o["accountUuid"] as? String) == uuid { cfg = o }
        do { try Keychain.writeVault(uuid, oauth) } catch { errorText = error.localizedDescription; return }
        vault[uuid] = oauth
        let existed = accounts.contains { $0.id == uuid }
        upsert(uuid: uuid, oauth: oauth, profile: profile, cfgAccount: cfg)
        backoffUntil[uuid] = nil
        notice = existed ? "Signed in again to \(Account.mask(email))." : "Saved \(Account.mask(email)). Click Switch when you want to use it."
        await refreshUsage(for: uuid, live: nil)
        save()
    }

    func restartSessions(_ list: [ClaudeSession]) {
        let term = terminal
        Task.detached { Sessions.restart(list, terminal: term) }
        notice = list.count == 1 ? "Restarting 1 session" : "Restarting \(list.count) sessions"
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.sessions = Sessions.running() }
    }
}
