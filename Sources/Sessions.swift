import AppKit
import Foundation

/// A running interactive Claude Code process, from ~/.claude/sessions/<pid>.json.
struct ClaudeSession: Identifiable, Hashable {
    var pid: Int32
    var sessionId: String
    var cwd: String
    var name: String
    var status: String
    var id: Int32 { pid }
    var isBusy: Bool { status == "busy" }
    var folder: String { (cwd as NSString).lastPathComponent }
}

enum Sessions {
    static func running() -> [ClaudeSession] {
        let dir = ClaudeConfig.configDir.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [ClaudeSession] = []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let pid = (j["pid"] as? NSNumber)?.int32Value,
                  (j["kind"] as? String) == "interactive",
                  kill(pid, 0) == 0, isClaude(pid) else { continue }
            out.append(ClaudeSession(pid: pid,
                                     sessionId: j["sessionId"] as? String ?? "",
                                     cwd: j["cwd"] as? String ?? NSHomeDirectory(),
                                     name: j["name"] as? String ?? "",
                                     status: j["status"] as? String ?? "idle"))
        }
        return out.sorted { $0.pid < $1.pid }
    }

    /// Session files can outlive their process and the pid can be reused, so check the
    /// executable is really claude before ever signalling it.
    private static func isClaude(_ pid: Int32) -> Bool {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        let path = String(cString: buf)
        return path.contains("/claude") || path.hasSuffix("claude")
    }

    /// Quit each session and reopen it with `claude --resume <id>` in a new terminal window,
    /// so it starts with the newly active account and keeps its conversation.
    static func restart(_ sessions: [ClaudeSession], terminal: String) {
        guard let claude = ClaudeConfig.claudeBinary() else { return }
        for s in sessions {
            kill(s.pid, SIGTERM)
        }
        // Give each process a moment to flush its transcript before resuming it elsewhere.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, sessions.contains(where: { kill($0.pid, 0) == 0 }) { usleep(100_000) }
        for s in sessions {
            let resume = s.sessionId.isEmpty ? "--continue" : "--resume \(s.sessionId)"
            let cmd = "cd \(shq(s.cwd)) && \(shq(claude)) \(resume); exec $SHELL -l"
            open(command: cmd, cwd: s.cwd, terminal: terminal)
        }
    }

    static func openNew(terminal: String, command: String) {
        open(command: command, cwd: NSHomeDirectory(), terminal: terminal)
    }

    private static func open(command: String, cwd: String, terminal: String) {
        if terminal == "Ghostty", FileManager.default.fileExists(atPath: "/Applications/Ghostty.app") {
            Shell.run("/usr/bin/open", ["-na", "Ghostty", "--args", "--working-directory=\(cwd)", "-e", "/bin/zsh", "-lc", command])
        } else {
            let esc = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            Shell.run("/usr/bin/osascript", ["-e", "tell application \"Terminal\" to do script \"\(esc)\"",
                                             "-e", "tell application \"Terminal\" to activate"])
        }
    }

    static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// Runs `claude auth login` as a child process. Without a TTY it prints the sign in URL
/// and then accepts a pasted code on stdin, so no terminal window is needed.
final class LoginRunner: ObservableObject {
    @Published var url: URL?
    @Published var output = ""
    @Published var running = false
    @Published var exitCode: Int32?

    private var process: Process?
    private var stdin: Pipe?
    var onExit: ((Int32) -> Void)?
    /// Private config folder for this sign in, so it never replaces Claude Code's active login.
    private(set) var configDir: URL?

    func start(email: String?) throws {
        guard let claude = ClaudeConfig.claudeBinary() else { throw HatrackError.config("Claude Code is not installed") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        var args = ["auth", "login", "--claudeai"]
        if let email, !email.isEmpty { args += ["--email", email] }
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":" + (claude as NSString).deletingLastPathComponent
        env.removeValue(forKey: "CLAUDE_CODE_OAUTH_TOKEN")
        env["NO_COLOR"] = "1"
        // Sign in inside a throwaway config folder. Claude Code then keeps this login in its
        // own Keychain item ("Claude Code-credentials-<sha256(dir)[:8]>") and its own
        // .claude.json, so the global login and every open session stay as they are.
        let dir = Store.supportDir.appendingPathComponent("signin-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        env["CLAUDE_CONFIG_DIR"] = dir.path
        env["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = dir.path
        configDir = dir
        p.environment = env
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inp
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { h.readabilityHandler = nil; return }
            let s = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { self?.consume(s) }
        }
        p.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.running = false
                self?.exitCode = p.terminationStatus
                self?.onExit?(p.terminationStatus)
            }
        }
        try p.run()
        process = p
        stdin = inp
        running = true
        exitCode = nil
        output = ""
        url = nil
    }

    private func consume(_ s: String) {
        // Strip terminal escapes (the URL arrives wrapped in an OSC 8 hyperlink).
        let clean = s.replacingOccurrences(of: #"\u{1B}\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[A-Za-z]"#, with: "", options: .regularExpression)
        output += clean
        if url == nil, let r = output.range(of: #"https://\S+"#, options: .regularExpression) {
            url = URL(string: String(output[r]))
        }
    }

    func submit(code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, let stdin else { return }
        stdin.fileHandleForWriting.write((c + "\n").data(using: .utf8)!)
    }

    func cancel() {
        process?.terminate()
        running = false
    }
}
