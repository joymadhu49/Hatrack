import Foundation

/// Keychain access goes through /usr/bin/security on purpose.
///
/// Claude Code creates and rewrites its "Claude Code-credentials" item with the `security`
/// tool, so that tool is on the item's access list and can read it without a password
/// prompt. Calling SecItem APIs from this app would instead ask for the login password,
/// and the answer would not survive a rebuild. The app's own vault items are written the
/// same way so every item behaves alike.
enum Keychain {
    static let claudeService = "Claude Code-credentials"
    static let vaultService = "Hatrack"
    static var claudeAccount: String { NSUserName() }

    /// `security -i` reads one command per line from stdin, which keeps the secret out of
    /// the process list. Claude Code uses the same route and falls back to argv when the
    /// line would be too long for the tool's line buffer.
    private static let stdinLineLimit = 4000

    static func read(service: String, account: String) -> Data? {
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"])
        guard r.status == 0 else { return nil }
        var s = r.stdout
        while s.hasSuffix("\n") { s.removeLast() }
        guard !s.isEmpty else { return nil }
        return s.data(using: .utf8)
    }

    static func write(service: String, account: String, data: Data) throws {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        let r: Shell.Result
        if line.utf8.count < stdinLineLimit {
            r = Shell.run("/usr/bin/security", ["-i"], stdin: line)
        } else {
            r = Shell.run("/usr/bin/security", ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        }
        // `security -i` exits 0 even when a command inside it fails, so read the item back.
        guard r.status == 0, read(service: service, account: account) == data else {
            throw HatrackError.keychain("Could not save to the Keychain (\(service)). \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    static func delete(service: String, account: String) {
        _ = Shell.run("/usr/bin/security", ["delete-generic-password", "-s", service, "-a", account])
    }

    // MARK: Claude Code's live login

    static func readLiveBlob() -> [String: Any]? {
        guard let d = read(service: claudeService, account: claudeAccount) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func writeLiveBlob(_ blob: [String: Any]) throws {
        let d = try JSONSerialization.data(withJSONObject: blob, options: [.withoutEscapingSlashes])
        try write(service: claudeService, account: claudeAccount, data: d)
    }

    // MARK: Hatrack vault (one item per account, holds that account's claudeAiOauth object)

    static func readVault(_ id: String) -> [String: Any]? {
        guard let d = read(service: vaultService, account: id) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    static func writeVault(_ id: String, _ oauth: [String: Any]) throws {
        let d = try JSONSerialization.data(withJSONObject: oauth, options: [.withoutEscapingSlashes, .sortedKeys])
        try write(service: vaultService, account: id, data: d)
    }
}

enum HatrackError: LocalizedError {
    case keychain(String)
    case config(String)
    case api(String)
    case signedOut(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let s), .config(let s), .api(let s), .signedOut(let s): return s
        }
    }
}

enum Shell {
    struct Result { var status: Int32; var stdout: String; var stderr: String }

    @discardableResult
    static func run(_ path: String, _ args: [String], stdin: String? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let inPipe = Pipe()
        p.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe
        do { try p.run() } catch { return Result(status: -1, stdout: "", stderr: error.localizedDescription) }
        if let stdin {
            inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
            try? inPipe.fileHandleForWriting.close()
        }
        // Drain both pipes before waiting so a large output cannot deadlock the child.
        var o = Data(), e = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.wait()
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      stdout: String(decoding: o, as: UTF8.self),
                      stderr: String(decoding: e, as: UTF8.self))
    }
}
