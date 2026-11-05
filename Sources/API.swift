import Foundation

/// The three Anthropic OAuth endpoints Claude Code itself uses for /usage and sign in.
enum ClaudeAPI {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let beta = "oauth-2025-04-20"

    struct HTTPFailure: Error { var status: Int; var retryAfter: TimeInterval?; var body: String }

    private static func send(_ req: URLRequest) async throws -> [String: Any] {
        var req = req
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(beta, forHTTPHeaderField: "anthropic-beta")
        req.setValue("Hatrack/1.0", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard status == 200 else {
            let ra = (http?.value(forHTTPHeaderField: "retry-after")).flatMap(TimeInterval.init)
            throw HTTPFailure(status: status, retryAfter: ra, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func get(_ url: URL, token: String) async throws -> [String: Any] {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await send(r)
    }

    static func usage(token: String) async throws -> Usage {
        Usage(json: try await get(usageURL, token: token))
    }

    static func profile(token: String) async throws -> [String: Any] {
        try await get(profileURL, token: token)
    }

    /// Exchange a refresh token. The server rotates it, so the caller must store the result
    /// or the account is lost.
    static func refresh(_ oauth: [String: Any]) async throws -> [String: Any] {
        guard let rt = oauth["refreshToken"] as? String else { throw HatrackError.signedOut("No refresh token saved") }
        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": rt, "client_id": clientID]
        if let scopes = oauth["scopes"] as? [String] { body["scope"] = scopes.joined(separator: " ") }
        var r = URLRequest(url: tokenURL)
        r.httpMethod = "POST"
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json: [String: Any]
        do { json = try await send(r) } catch let f as HTTPFailure {
            if f.status == 400 || f.status == 401 { throw HatrackError.signedOut("Signed out. Sign in to this account again.") }
            throw HatrackError.api("Token refresh failed (HTTP \(f.status))")
        }
        guard let access = json["access_token"] as? String else { throw HatrackError.api("Token refresh returned no access token") }
        var out = oauth
        out["accessToken"] = access
        if let newRT = json["refresh_token"] as? String { out["refreshToken"] = newRT }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        out["expiresAt"] = NSNumber(value: Int64((Date().timeIntervalSince1970 + expiresIn) * 1000))
        if let scope = json["scope"] as? String { out["scopes"] = scope.split(separator: " ").map(String.init) }
        return out
    }

    static func expiresAt(_ oauth: [String: Any]) -> Date? {
        guard let n = oauth["expiresAt"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: n.doubleValue / 1000)
    }

    static func isFresh(_ oauth: [String: Any], margin: TimeInterval = 120) -> Bool {
        guard let e = expiresAt(oauth) else { return false }
        return e.timeIntervalSinceNow > margin
    }
}

struct Limit: Codable, Hashable, Identifiable {
    var kind: String
    var group: String
    var percent: Double        // used, 0 to 100
    var resetsAt: Date?
    var id: String { kind }

    var left: Double { max(0, 100 - percent) }

    var title: String {
        switch kind {
        case "session": return "Session"
        case "weekly_all": return "Week"
        default:
            var k = kind
            if k.hasPrefix("weekly_") { k.removeFirst(7) }
            let words = k.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return (group == "weekly" ? "Week " : "") + words.joined(separator: " ")
        }
    }
}

struct Usage: Codable, Hashable {
    var limits: [Limit]

    var session: Limit? { limits.first { $0.kind == "session" } }
    var week: Limit? { limits.first { $0.kind == "weekly_all" } }

    init(limits: [Limit]) { self.limits = limits }

    init(json: [String: Any]) {
        var out: [Limit] = []
        if let arr = json["limits"] as? [[String: Any]] {
            for l in arr {
                guard let kind = l["kind"] as? String else { continue }
                out.append(Limit(kind: kind,
                                 group: l["group"] as? String ?? "",
                                 percent: (l["percent"] as? NSNumber)?.doubleValue ?? 0,
                                 resetsAt: Usage.date(l["resets_at"])))
            }
        }
        // Older servers only send the named windows.
        let named: [(String, String, String)] = [("five_hour", "session", "session"),
                                                 ("seven_day", "weekly_all", "weekly"),
                                                 ("seven_day_opus", "weekly_opus", "weekly"),
                                                 ("seven_day_sonnet", "weekly_sonnet", "weekly")]
        for (key, kind, group) in named where !out.contains(where: { $0.kind == kind }) {
            guard let w = json[key] as? [String: Any], let u = w["utilization"] as? NSNumber else { continue }
            out.append(Limit(kind: kind, group: group, percent: u.doubleValue, resetsAt: Usage.date(w["resets_at"])))
        }
        limits = out
    }

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        // Python style microseconds (6 digits) trip ISO8601DateFormatter, so trim to millis.
        let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: trimmed)
    }
}
