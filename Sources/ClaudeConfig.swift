import Foundation

/// Claude Code's files on disk: ~/.claude.json (which account the CLI shows as signed in)
/// and the write lock it takes around credential writes.
enum ClaudeConfig {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var configDir: URL {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        return home.appendingPathComponent(".claude")
    }
    static var globalConfig: URL { home.appendingPathComponent(".claude.json") }

    static func oauthAccount() -> [String: Any]? {
        guard let d = try? Data(contentsOf: globalConfig),
              let root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return root["oauthAccount"] as? [String: Any]
    }

    /// Replace only the `oauthAccount` key, keep everything else, and swap the file in atomically.
    static func setOAuthAccount(_ account: [String: Any]) throws {
        let url = globalConfig
        guard let d = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
            throw HatrackError.config("Could not read ~/.claude.json")
        }
        root["oauthAccount"] = account
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".claude.json.hatrack-\(getpid())")
        try out.write(to: tmp)
        let perms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
        try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: tmp.path)
        if rename(tmp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw HatrackError.config("Could not write ~/.claude.json")
        }
    }

    /// Claude Code guards credential writes with proper-lockfile on `<configDir>/.storage-write`,
    /// which is a directory named `.storage-write.lock` that counts as stale after 15 s.
    /// Taking the same lock means a switch can never interleave with a token refresh.
    static func withStorageLock<T>(_ body: () throws -> T) throws -> T {
        let lock = configDir.appendingPathComponent(".storage-write.lock").path
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        var held = false
        for _ in 0..<60 {
            if mkdir(lock, 0o755) == 0 { held = true; break }
            if let m = (try? FileManager.default.attributesOfItem(atPath: lock))?[.modificationDate] as? Date,
               Date().timeIntervalSince(m) > 15 {
                rmdir(lock)
                continue
            }
            usleep(100_000)
        }
        guard held else { throw HatrackError.config("Claude Code is busy writing its login. Try again in a moment.") }
        defer { rmdir(lock) }
        return try body()
    }

    /// Make every running Claude Code session adopt the new login on its next request.
    ///
    /// Before each API call Claude Code runs a change check (2.1.318: `sC`). On macOS it stats
    /// `<configDir>/.credentials.json`: if the mtime moved, it drops its in memory token and
    /// the 30 s Keychain cache and reads the Keychain again. If the mtime did not move and the
    /// token it holds is still valid, it keeps using that token for hours. So bumping the
    /// mtime (content untouched) is what makes a switch live with no restart. When the file
    /// does not exist the stat fails and Claude Code re-reads the Keychain on every check
    /// anyway (through its 30 s cache), so there is nothing to do.
    @discardableResult
    static func nudgeRunningSessions() -> Bool {
        let path = configDir.appendingPathComponent(".credentials.json").path
        guard FileManager.default.fileExists(atPath: path) else { return false }
        return utimes(path, nil) == 0
    }

    static func claudeBinary() -> String? {
        let candidates = [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home.appendingPathComponent(".claude/local/claude").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
