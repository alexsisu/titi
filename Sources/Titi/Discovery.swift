import AppKit

/// A Claude or Codex process running in an iTerm tab.
struct LiveSession: Identifiable, Hashable {
    var id: String { tty }
    let tool: String        // "Claude" | "Codex"
    let folder: String      // tilde path
    let tty: String         // "/dev/ttys005"
    var branch: String?
    var title: String?
    var started: Date?
    var lastActive: Date?   // last terminal I/O (tty mtime)

    var label: String { "\(tool) | \(folder)" }
}

/// Where the user was when they hit the shortcut: the front iTerm session.
struct CaptureContext {
    let tool: String?
    let folder: String
    let branch: String?
    let tty: String?
    let title: String?

    var label: String { tool.map { "\($0) | \(folder)" } ?? folder }
}

enum Discovery {
    struct ScanResult {
        var sessions: [LiveSession]
        var activity: [String: Date]
    }

    static func scan(folders: [String]) -> ScanResult {
        let sessions = liveSessions()
        let codex = codexActivity()
        var activity: [String: Date] = [:]
        for f in Set(folders + sessions.map(\.folder)) {
            let path = expandTilde(f)
            if let last = [claudeActivity(path), codex[path], gitActivity(path)].compactMap({ $0 }).max() {
                activity[f] = last
            }
        }
        return ScanResult(sessions: sessions, activity: activity)
    }

    static func toolFor(_ command: String) -> String? {
        let names = command.split(separator: " ").prefix(2).map { ($0 as NSString).lastPathComponent }
        if names.contains("claude") { return "Claude" }
        if names.contains("codex") { return "Codex" }
        return nil
    }

    static func liveSessions() -> [LiveSession] {
        var byTTY: [String: (pid: String, tool: String, etime: String)] = [:]
        for line in sh("/bin/ps", ["-axo", "pid=,tty=,etime=,command="]).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 4, parts[1] != "??", let tool = toolFor(parts[3]) else { continue }
            if byTTY[parts[1]] == nil { byTTY[parts[1]] = (parts[0], tool, parts[2]) }
        }
        guard !byTTY.isEmpty else { return [] }
        let cwds = cwdOf(pids: byTTY.values.map(\.pid))
        let titles = ITerm.sessionNames()
        var branches: [String: String?] = [:]
        var out: [LiveSession] = []
        for (tty, p) in byTTY {
            guard let cwd = cwds[p.pid] else { continue }
            let folder = tildify(cwd)
            if branches[folder] == nil { branches[folder] = gitBranch(cwd) }
            let dev = "/dev/" + tty
            out.append(LiveSession(
                tool: p.tool, folder: folder, tty: dev,
                branch: branches[folder] ?? nil,
                title: titles[dev].map(cleanTitle),
                started: Date().addingTimeInterval(-parseEtime(p.etime)),
                lastActive: mtime(dev)))
        }
        return out.sorted { ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
    }

    /// The front iTerm session: which folder (and agent, if any) the user was in.
    static func frontContext() -> CaptureContext? {
        guard ITerm.isRunning, let tty = ITerm.currentTTY(), tty.hasPrefix("/dev/") else { return nil }
        var agent: (pid: String, tool: String)?
        var shell: String?
        var last: String?
        for line in sh("/bin/ps", ["-t", String(tty.dropFirst(5)), "-o", "pid=,command="]).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 2 else { continue }
            last = parts[0]
            if agent == nil, let tool = toolFor(parts[1]) { agent = (parts[0], tool) }
            if parts[1].hasPrefix("-") || parts[1].hasPrefix("zsh") || parts[1].hasPrefix("bash") { shell = parts[0] }
        }
        guard let pid = agent?.pid ?? shell ?? last, let cwd = cwdOf(pids: [pid])[pid] else { return nil }
        return CaptureContext(
            tool: agent?.tool, folder: tildify(cwd), branch: gitBranch(cwd), tty: tty,
            title: ITerm.sessionNames()[tty].map(cleanTitle))
    }

    static func cwdOf(pids: [String]) -> [String: String] {
        guard !pids.isEmpty else { return [:] }
        var out: [String: String] = [:]
        var current: String?
        for line in sh("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fn", "-p", pids.joined(separator: ",")]).split(separator: "\n") {
            if line.hasPrefix("p") { current = String(line.dropFirst()) }
            if line.hasPrefix("n"), let c = current { out[c] = String(line.dropFirst()) }
        }
        return out
    }

    static func gitBranch(_ path: String) -> String? {
        let b = sh("/usr/bin/git", ["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]).trimmed
        return b.isEmpty || b == "HEAD" ? nil : b
    }

    static func gitActivity(_ path: String) -> Date? {
        guard let t = Double(sh("/usr/bin/git", ["-C", path, "log", "-1", "--format=%ct"]).trimmed) else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// Last message time across this folder's Claude sessions (~/.claude/projects/<slug>/*.jsonl).
    /// Reads the last `"timestamp"` in each file: file mtimes get bumped in bulk, so they can't be trusted.
    static func claudeActivity(_ path: String) -> Date? {
        let slug = path.map { "/_.".contains($0) ? "-" : String($0) }.joined()
        let dir = Config.home + "/.claude/projects/" + slug
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        return files.filter { $0.hasSuffix(".jsonl") }.compactMap { lastTimestamp(dir + "/" + $0) }.max()
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func lastTimestamp(_ file: String) -> Date? {
        guard let h = FileHandle(forReadingAtPath: file) else { return nil }
        defer { try? h.close() }
        let size = h.seekToEndOfFile()
        h.seek(toFileOffset: size > 16_384 ? size - 16_384 : 0)
        let tail = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        guard let r = tail.range(of: #""timestamp":"[^"]+""#, options: [.regularExpression, .backwards]) else { return nil }
        let value = tail[r].dropFirst(13).dropLast()
        return isoFractional.date(from: String(value))
    }

    /// Last Codex thread update per folder, from Codex's own SQLite state.
    static func codexActivity() -> [String: Date] {
        let dir = Config.home + "/.codex"
        guard let db = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter({ $0.hasPrefix("state_") && $0.hasSuffix(".sqlite") }).sorted().last else { return [:] }
        var out: [String: Date] = [:]
        let rows = sh("/usr/bin/sqlite3", ["-readonly", "-separator", "\t", dir + "/" + db,
                                           "select cwd, max(updated_at) from threads group by cwd"])
        for line in rows.split(separator: "\n") {
            let parts = line.split(separator: "\t").map(String.init)
            if parts.count == 2, let t = Double(parts[1]) { out[parts[0]] = Date(timeIntervalSince1970: t) }
        }
        return out
    }

    static func parseEtime(_ s: String) -> TimeInterval {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let nums = rest.split(separator: ":").compactMap { Double($0) }
        let secs = nums.reduce(0) { $0 * 60 + $1 }
        return days * 86400 + secs
    }

    /// "Checkout latency report (claude)" -> "Checkout latency report"
    static func cleanTitle(_ t: String) -> String {
        t.replacingOccurrences(of: #"\s*\((claude|codex|node)\)$"#, with: "", options: .regularExpression)
    }
}

enum ITerm {
    static let bundleID = "com.googlecode.iterm2"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func osa(_ script: String) -> String {
        sh("/usr/bin/osascript", ["-e", script]).trimmed
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// tty -> session name, for every iTerm session.
    static func sessionNames() -> [String: String] {
        guard isRunning else { return [:] }
        let out = osa("""
        tell application "iTerm2"
          set out to ""
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                set out to out & (tty of s) & " | " & (name of s) & linefeed
              end repeat
            end repeat
          end repeat
          return out
        end tell
        """)
        var names: [String: String] = [:]
        for line in out.split(separator: "\n") {
            guard let r = line.range(of: " | ") else { continue }
            names[String(line[..<r.lowerBound])] = String(line[r.upperBound...])
        }
        return names
    }

    static func currentTTY() -> String? {
        let t = osa("tell application \"iTerm2\" to tty of current session of current window")
        return t.isEmpty ? nil : t
    }

    /// Brings the iTerm window/tab/session with this tty to the front.
    @discardableResult
    static func select(tty: String) -> Bool {
        osa("""
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is \(quote(tty)) then
                  tell w to select
                  tell t to select
                  tell s to select
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "none"
        end tell
        """) == "ok"
    }

    /// Opens a new iTerm tab already cd'ed into the folder.
    static func openTab(in folder: String) {
        _ = osa("""
        tell application "iTerm2"
          activate
          if (count of windows) is 0 then
            create window with default profile
          else
            tell current window to create tab with default profile
          end if
          tell current session of current window to write text "cd " & quoted form of \(quote(expandTilde(folder)))
        end tell
        """)
    }
}
