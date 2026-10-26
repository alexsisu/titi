import CryptoKit
import Foundation

/// One finished focus block from focus-log.jsonl.
struct FocusEntry {
    let start: Date?
    let end: Date
    let minutes: Int
    let goal: String
    let group: String
    let pauses: Int
    let outcome: String
}

/// Append-only log of focus blocks.
enum FocusLog {
    static var url: URL { Config.supportDir.appendingPathComponent("focus-log.jsonl") }

    static func append(_ f: FocusBlock, outcome: String) {
        let iso = ISO8601DateFormatter()
        let entry: [String: Any] = [
            "start": f.started.map { iso.string(from: $0) } ?? "",
            "end": iso.string(from: Date()),
            "minutes": Int(((f.total - f.remaining) / 60).rounded()),
            "goal": f.goal, "group": f.group ?? "", "label": f.label,
            "pauses": f.pauses, "outcome": outcome,
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        data.append(0x0A)
        try? FileManager.default.createDirectory(at: Config.supportDir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Blocks that ended inside [from, to). Times in the log are UTC; comparing Dates keeps this in local time.
    static func entries(from: Date, to: Date) -> [FocusEntry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let iso = ISO8601DateFormatter()
        return text.split(separator: "\n").compactMap { line in
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let end = (o["end"] as? String).flatMap(iso.date(from:)), end >= from, end < to else { return nil }
            return FocusEntry(start: (o["start"] as? String).flatMap(iso.date(from:)), end: end,
                              minutes: o["minutes"] as? Int ?? 0, goal: o["goal"] as? String ?? "",
                              group: o["group"] as? String ?? "", pauses: o["pauses"] as? Int ?? 0,
                              outcome: o["outcome"] as? String ?? "")
        }
    }

    static func countToday() -> Int {
        let start = workday()
        return entries(from: start, to: workdayEnd(start)).count
    }
}

/// The end-of-day report: plain Markdown built only from the notes files, the focus log and git.
enum Report {
    struct Commit: Hashable {
        let hash: String
        let time: Date
        let subject: String
    }

    struct CommitGroup: Identifiable, Hashable {
        var id: String { folder + "|" + (branch ?? "") }
        let folder: String
        let branch: String?
        var commits: [Commit]
    }

    private static func fmt(_ f: String) -> DateFormatter {
        let d = DateFormatter()
        d.dateFormat = f
        return d
    }
    static let hm = fmt("HH:mm")
    static let fileDay = fmt("yyyy-MM-dd")
    static let title = fmt("EEE d MMM yyyy")

    /// Your own commits on local branches, each repo matched by its own user.email. Merges are left out, and a
    /// commit reachable from several checkouts is listed once, under the first folder.
    static func commits(folders: [String], from: Date, to: Date) -> [CommitGroup] {
        let iso = ISO8601DateFormatter()
        var seen: Set<String> = []
        var out: [CommitGroup] = []
        for f in folders {
            let path = expandTilde(f)
            guard FileManager.default.fileExists(atPath: path + "/.git") else { continue }
            let email = sh("/usr/bin/git", ["-C", path, "config", "user.email"]).trimmed
            guard !email.isEmpty else { continue }
            let log = sh("/usr/bin/git", ["-C", path, "log", "--branches", "--source", "--no-merges",
                                          "--since=" + iso.string(from: from), "--until=" + iso.string(from: to),
                                          "--author=" + email, "--format=%H%x09%ct%x09%S%x09%s"])
            var groups: [String: CommitGroup] = [:]
            var order: [String] = []
            for line in log.split(separator: "\n") {
                let p = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                guard p.count == 4, let t = Double(p[1]), seen.insert(p[0]).inserted else { continue }
                let branch = p[2].hasPrefix("refs/heads/") ? String(p[2].dropFirst(11)) : p[2]
                if groups[branch] == nil {
                    groups[branch] = CommitGroup(folder: f, branch: branch.isEmpty ? nil : branch, commits: [])
                    order.append(branch)
                }
                groups[branch]?.commits.append(Commit(hash: String(p[0].prefix(10)),
                                                      time: Date(timeIntervalSince1970: t), subject: p[3]))
            }
            out += order.compactMap { groups[$0] }
        }
        return out
    }

    static func markdown(day: Date, open: [Note], closed: [Note], commits: [CommitGroup], focus: [FocusEntry],
                         now: Date = Date()) -> String {
        let end = workdayEnd(day)
        let inDay = { (d: Date?) in d.map { $0 >= day && $0 < end } ?? false }
        let done = closed.filter { $0.state == .done && inDay($0.closedAt) }.sorted { $0.closedAt! < $1.closedAt! }
        let removed = closed.filter { $0.state == .removed && inDay($0.closedAt) }
        var md = "# Daily report · \(title.string(from: day))\n"
        md += "_workday from 04:00 · generated \(hm.string(from: now)) by titi_\n"

        md += "\n## Done (\(done.count))\n"
        if done.isEmpty { md += "\nnothing ticked yet\n" }
        var groups: [String: [Note]] = [:]
        var order: [String] = []
        for n in done {
            let k = n.group + (n.branch.map { " · " + shortBranch($0) } ?? "")
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(n)
        }
        for k in order {
            md += "\n### \(k)\n"
            for n in groups[k]! { md += "- \(n.isAbout ? "⏯ " : "")\(n.text) ✅ \(hm.string(from: n.closedAt!))\n" }
        }

        if !focus.isEmpty {
            let mins = focus.reduce(0) { $0 + $1.minutes }
            let pauses = focus.reduce(0) { $0 + $1.pauses }
            md += "\n## Focus (\(focus.count) block\(focus.count == 1 ? "" : "s") · \(mins) timer min · \(pauses) interruption\(pauses == 1 ? "" : "s"))\n"
            for f in focus {
                let span = (f.start.map { hm.string(from: $0) + "–" } ?? "") + hm.string(from: f.end)
                md += "- \(span) \(f.goal) (\(f.minutes) min, \(f.pauses) pause\(f.pauses == 1 ? "" : "s")) · \(f.outcome)\n"
            }
        }

        let count = commits.reduce(0) { $0 + $1.commits.count }
        if count > 0 {
            md += "\n## Commits (\(count))\n"
            for g in commits {
                md += "\n### \(g.folder)\(g.branch.map { " · " + shortBranch($0) } ?? "")\n"
                for c in g.commits { md += "- \(c.hash) \(hm.string(from: c.time)) \(c.subject)\n" }
            }
        }

        let resume = open.filter(\.isAbout).sorted { $0.created > $1.created }
        if !resume.isEmpty {
            md += "\n## Resume next\n"
            for n in resume { md += "- [ ] \(n.text) (\(n.group)\(n.branch.map { " · " + shortBranch($0) } ?? ""))\n" }
        }
        let started = open.filter { !$0.isAbout && inDay($0.created) }.sorted { $0.created < $1.created }
        if !started.isEmpty {
            md += "\n## Still open from today\n"
            for n in started { md += "- [ ] \(n.text) (\(n.group))\n" }
        }
        if !removed.isEmpty {
            md += "\n## Dropped (\(removed.count))\n"
            for n in removed { md += "- ~~\(n.text)~~ (\(n.group))\n" }
        }
        return md
    }

    static var dir: URL { Config.notesDir.appendingPathComponent("reports", isDirectory: true) }

    /// Writes reports/YYYY-MM-DD.md. A report file you edited by hand is never overwritten: the new one goes
    /// next to it as "YYYY-MM-DD (2).md". "Edited" = its content no longer matches what titi last wrote there.
    static func save(_ md: String, day: Date) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var written = UserDefaults.standard.dictionary(forKey: "reportDigests") as? [String: String] ?? [:]
        let base = fileDay.string(from: day)
        var n = 1
        var url = dir.appendingPathComponent(base + ".md")
        while let existing = try? String(contentsOf: url, encoding: .utf8), written[url.path] != digest(existing) {
            n += 1
            url = dir.appendingPathComponent("\(base) (\(n)).md")
        }
        try md.write(to: url, atomically: true, encoding: .utf8)
        written[url.path] = digest(md)
        UserDefaults.standard.set(written, forKey: "reportDigests")
        return url
    }

    /// After the notes folder moved: the reports titi wrote keep counting as its own, so freezing again still
    /// overwrites today's file instead of starting a "(2)".
    static func reportsMoved(from old: URL, _ moved: [(rel: String, to: URL)]) {
        let d = UserDefaults.standard
        guard var written = d.dictionary(forKey: "reportDigests") as? [String: String] else { return }
        for m in moved {
            let before = old.appendingPathComponent(m.rel).path
            for (key, value) in written where key == before || key.hasPrefix(before + "/") {
                written.removeValue(forKey: key)
                written[m.to.path + key.dropFirst(before.count)] = value
            }
        }
        d.set(written, forKey: "reportDigests")
    }

    private static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Folders worth asking git about: the hot ones plus any folder with a todo or a live session.
    static func gitFolders(notes: [Note], sessions: [LiveSession]) -> [String] {
        var out: [String] = []
        for f in Config.hotFolders + sessions.map(\.folder) + notes.map(\.group) where f.hasPrefix("~") && !out.contains(f) {
            out.append(f)
        }
        return out
    }

    /// `Titi --report [YYYY-MM-DD]`: the report on stdout, nothing written.
    static func printCLI(_ arg: String?) {
        var day = workday()
        if let arg {
            guard let d = fileDay.date(from: arg) else {
                print("usage: Titi --report [YYYY-MM-DD]")
                return
            }
            day = workday(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: d) ?? d)
        }
        let open = NotesFS.loadAll()
        let end = workdayEnd(day)
        let commits = Report.commits(folders: gitFolders(notes: open, sessions: []), from: day, to: end)
        print(markdown(day: day, open: open, closed: NotesFS.loadClosed(), commits: commits,
                       focus: FocusLog.entries(from: day, to: end)), terminator: "")
    }
}
