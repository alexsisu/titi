import Foundation

/// One todo line inside a capture file: open ("- [ ] "), done ("- [x] ") or removed ("- [-] ").
struct Note: Identifiable, Hashable {
    enum State { case open, done, removed }
    var id: String
    var text: String
    var group: String          // "~/code/acme-api" | "General" | list name
    var filedUnder: String     // "Claude | ~/code/acme-api"
    var branch: String?
    var created: Date
    var isAbout: Bool          // "I was about to…" line
    var file: URL?
    var line: Int?
    var isDemo = false
    var tty: String? = nil     // iTerm tab it was written in
    var state = State.open
    var closedAt: Date? = nil  // from the ✅ / ❌ stamp; nil when it was ticked outside titi
    var raw: String? = nil     // the closed line exactly as written, to find it again
}

/// Notes are plain Markdown: one file per capture, one `- [ ]` line per todo.
enum NotesFS {
    static let aboutPrefix = "⏯ I was about to: "
    static let doneStamp = " ✅ "
    static let removedStamp = " ❌ "
    /// done/ and removed/ hold files with nothing open left; reports/ holds end-of-day reports, never todos.
    static let buckets = ["done", "removed"]
    static let notTodos = ["done", "removed", "reports"]
    private static let fm = FileManager.default
    private static var root: URL { Config.notesDir }

    private static let stampFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()
    static let capturedFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    /// `captured:` is written to the second so todos made in the same minute keep their order; older files have
    /// minutes only and still parse.
    private static let capturedSeconds: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "General" -> root, "~/code/acme-api" -> "code_acme-api", list -> its name.
    static func subdir(for group: String) -> String {
        if group == "General" { return "" }
        if group.hasPrefix("~/") { return String(group.dropFirst(2)).replacingOccurrences(of: "/", with: "_") }
        return sanitize(group)
    }

    static func sanitize(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/:|\\\n\"")).joined(separator: "-").trimmed
    }

    @discardableResult
    static func write(group: String, filedUnder: String, branch: String?, tty: String? = nil, capturedIn: String,
                      focus: String?, about: String?, items: [String]) throws -> URL {
        let now = Date()
        let first = about ?? items.first ?? "note"
        let slug = sanitize(first.split(separator: " ").prefix(5).joined(separator: " "))
        let dir = root.appendingPathComponent(subdir(for: group), isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = stampFormat.string(from: now)
        var url = dir.appendingPathComponent("\(stamp) \(slug).md")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(stamp) \(slug) (\(n)).md")
            n += 1
        }
        var s = "---\ncaptured: \(capturedSeconds.string(from: now))\nfiled_under: \(filedUnder)\ngroup: \(group)\n"
        if let branch { s += "branch: \(branch)\n" }
        if let tty { s += "tty: \(tty)\n" }
        if !capturedIn.isEmpty { s += "captured_in: \(capturedIn)\n" }
        if let focus { s += "focus: \(focus)\n" }
        s += "---\n"
        if let about { s += "- [ ] \(aboutPrefix)\(about)\n" }
        for item in items { s += "- [ ] \(item)\n" }
        try s.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// True once any capture was ever written (open, done or removed): demo todos stop showing.
    static func everUsed() -> Bool {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return false }
        for case let url as URL in e where url.pathExtension == "md" { return true }
        return false
    }

    /// Every open todo. Files in done/, removed/ and reports/ are skipped.
    static func loadAll() -> [Note] {
        files(skipping: notTodos).flatMap { parse($0.url, rel: $0.rel) }
    }

    /// Every done or removed line, wherever its file ended up (live folders, done/ or removed/).
    static func loadClosed() -> [Note] {
        files(skipping: ["reports"]).flatMap { parse($0.url, rel: $0.rel, closed: true) }
    }

    private static func files(skipping skip: [String]) -> [(url: URL, rel: String)] {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                    options: [.skipsHiddenFiles]) else { return [] }
        var out: [(URL, String)] = []
        for case let url as URL in e {
            let rel = relative(url)
            if skip.contains(rel.split(separator: "/").first.map(String.init) ?? "") {
                if url.hasDirectoryPath { e.skipDescendants() }
                continue
            }
            if url.pathExtension == "md" { out.append((url, rel)) }
        }
        return out
    }

    private static func relative(_ url: URL) -> String {
        let r = url.resolvingSymlinksInPath().path
        let base = root.resolvingSymlinksInPath().path + "/"
        return r.hasPrefix(base) ? String(r.dropFirst(base.count)) : url.lastPathComponent
    }

    /// The same file, even when one path goes through a symlink (/var vs /private/var).
    static func samePath(_ a: URL?, _ b: URL) -> Bool {
        a?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path
    }

    static func parse(_ url: URL, rel: String, closed: Bool = false) -> [Note] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n")
        var meta: [String: String] = [:]
        var body = 0
        if lines.first == "---" {
            var i = 1
            while i < lines.count, lines[i] != "---" {
                if let r = lines[i].range(of: ": ") {
                    meta[String(lines[i][..<r.lowerBound])] = String(lines[i][r.upperBound...])
                }
                i += 1
            }
            body = i + 1
        }
        var dir = (rel as NSString).deletingLastPathComponent
        if let b = buckets.first(where: { dir == $0 || dir.hasPrefix($0 + "/") }) { dir = String(dir.dropFirst(b.count)).trimmingCharacters(in: ["/"]) }
        let group = meta["group"] ?? (dir.isEmpty ? "General" : dir)
        let created = meta["captured"].flatMap { capturedSeconds.date(from: $0) ?? capturedFormat.date(from: $0) }
            ?? mtime(url.path) ?? Date()
        var notes: [Note] = []
        for (i, line) in lines.enumerated() where i >= body {
            let state: Note.State
            switch line.prefix(6) {
            case "- [ ] " where !closed: state = .open
            case "- [x] " where closed, "- [X] " where closed: state = .done
            case "- [-] " where closed: state = .removed
            default: continue
            }
            var t = String(line.dropFirst(6))
            var closedAt: Date?
            if closed { (t, closedAt) = splitStamp(t) }
            let about = t.hasPrefix(aboutPrefix)
            if about { t = String(t.dropFirst(aboutPrefix.count)) }
            guard !t.trimmed.isEmpty else { continue }
            notes.append(Note(id: url.path + "#\(i)", text: t, group: group,
                              filedUnder: meta["filed_under"] ?? group, branch: meta["branch"],
                              created: created, isAbout: about, file: url, line: i, tty: meta["tty"],
                              state: state, closedAt: closedAt, raw: closed ? line : nil))
        }
        return notes
    }

    /// "task ✅ 2026-10-25 14:32" -> ("task", that time). A date without a time counts as noon, so it stays
    /// inside its own day whatever the 04:00 day boundary does.
    static func splitStamp(_ t: String) -> (String, Date?) {
        guard let r = t.range(of: #" (✅|❌) \d{4}-\d{2}-\d{2}( \d{2}:\d{2})?$"#, options: .regularExpression) else { return (t, nil) }
        let stamp = String(t[r].dropFirst(3)).trimmed
        let date = capturedFormat.date(from: stamp)
            ?? dayFormat.date(from: stamp).map { $0.addingTimeInterval(12 * 3600) }
        return (String(t[..<r.lowerBound]), date)
    }

    /// Ticks the line ("- [x] task ✅ 2026-10-25 14:32"); a file with nothing left open moves to done/.
    /// Returns the closed line, for undo.
    @discardableResult
    static func complete(_ n: Note) throws -> Note? {
        try mark(n, state: .done)
    }

    /// Marks the line removed ("- [-] task ❌ …"); a file with nothing left open moves to removed/.
    @discardableResult
    static func remove(_ n: Note) throws -> Note? {
        try mark(n, state: .removed)
    }

    private static func mark(_ n: Note, state: Note.State) throws -> Note? {
        guard let url = n.file, let remembered = n.line else { return nil }
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        // the file may have been edited since it was read: only touch the line that still says exactly this
        let expected = "- [ ] " + (n.isAbout ? aboutPrefix : "") + n.text
        let i = remembered < lines.count && lines[remembered] == expected ? remembered : lines.firstIndex(of: expected)
        guard let i else { return nil }
        let now = Date()
        let done = state == .done
        lines[i] = (done ? "- [x] " : "- [-] ") + lines[i].dropFirst(6)
            + (done ? doneStamp : removedStamp) + capturedFormat.string(from: now)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        var dest = url
        if !lines.contains(where: { $0.hasPrefix("- [ ] ") }) { dest = try moveAside(url, to: done ? "done" : "removed") }
        var c = n
        c.id = dest.path + "#\(i)"
        c.file = dest
        c.line = i
        c.state = state
        c.closedAt = now
        c.raw = lines[i]
        return c
    }

    /// Opens a done or removed line again. A file sitting in done/ or removed/ moves back where it came from.
    /// Returns the open line.
    @discardableResult
    static func reopen(_ c: Note) throws -> Note? {
        guard let url = c.file, let remembered = c.line, let raw = c.raw else { return nil }
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let i = remembered < lines.count && lines[remembered] == raw ? remembered : lines.firstIndex(of: raw)
        guard let i else { return nil }
        lines[i] = "- [ ] " + (c.isAbout ? aboutPrefix : "") + c.text
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        var dest = url
        let rel = relative(url)
        if let b = buckets.first(where: { rel.hasPrefix($0 + "/") }) {
            dest = freePath(root.appendingPathComponent(String(rel.dropFirst(b.count + 1))))
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: url, to: dest)
        }
        var o = c
        o.id = dest.path + "#\(i)"
        o.file = dest
        o.line = i
        o.state = .open
        o.closedAt = nil
        o.raw = nil
        return o
    }

    /// Rewrites one todo's text, keeping it open.
    static func edit(_ n: Note, to text: String) throws {
        guard let url = n.file, let remembered = n.line else { return }
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let prefix = "- [ ] " + (n.isAbout ? aboutPrefix : "")
        let expected = prefix + n.text
        let i = remembered < lines.count && lines[remembered] == expected ? remembered : lines.firstIndex(of: expected)
        guard let i else { return }
        lines[i] = prefix + text
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Bumps the capture date so a forgotten todo counts as fresh again.
    static func revive(_ n: Note) throws {
        guard let url = n.file else { return }
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let stamp = "captured: " + capturedSeconds.string(from: Date())
        if let i = lines.firstIndex(where: { $0.hasPrefix("captured: ") }) {
            lines[i] = stamp
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } else {
            try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        }
    }

    private static func moveAside(_ url: URL, to bucket: String) throws -> URL {
        let dest = freePath(root.appendingPathComponent(bucket).appendingPathComponent(relative(url)))
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    /// "x.md", or "x (2).md", "x (3).md"… if that name is taken (a folder: "x (2)").
    static func freePath(_ url: URL) -> URL {
        var dest = url
        var n = 2
        let ext = url.hasDirectoryPath ? "" : url.pathExtension
        let base = ext.isEmpty ? url.path : url.deletingPathExtension().path
        while fm.fileExists(atPath: dest.path) {
            dest = URL(fileURLWithPath: "\(base) (\(n))" + (ext.isEmpty ? "" : "." + ext))
            n += 1
        }
        return dest
    }

    // MARK: changing the notes folder (Settings)

    /// Why `new` can't take the notes from `old`, or nil when it can.
    static func problem(movingFrom old: URL, to new: URL) -> String? {
        let a = old.resolvingSymlinksInPath().standardizedFileURL.path
        let b = new.resolvingSymlinksInPath().standardizedFileURL.path
        if a == b { return "That is already the notes folder." }
        if b == "/" || b == Config.home { return "Pick a folder of its own, not \(tildify(b))." }
        if b.hasPrefix(a + "/") { return "That folder is inside the current notes folder." }
        if a.hasPrefix(b + "/") { return "The current notes folder is inside that one." }
        return nil
    }

    /// How many notes (Markdown files) a folder holds, hidden folders left out.
    static func countNotes(in dir: URL) -> Int {
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return 0 }
        return e.reduce(0) { $0 + (($1 as? URL)?.pathExtension == "md" ? 1 : 0) }
    }

    /// Moves everything visible in `old` into `new`: folders with the same name merge, and a file never overwrites
    /// one already there (it arrives as "x (2).md"). Hidden items (.git, .DS_Store) and `old` itself stay.
    /// All or nothing: if one move fails, the ones done are moved back and the error is rethrown.
    /// Returns each moved file or folder as (path relative to `old`, where it went).
    @discardableResult
    static func moveAll(from old: URL, to new: URL) throws -> [(rel: String, to: URL)] {
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        var moved: [(from: URL, rel: String, to: URL)] = []
        var merged: [URL] = []   // source folders emptied into an existing one
        func merge(_ src: URL, into dst: URL, rel: String) throws {
            let items = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = item.lastPathComponent
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                let target = dst.appendingPathComponent(name, isDirectory: isDir)
                var targetIsDir: ObjCBool = false
                let taken = fm.fileExists(atPath: target.path, isDirectory: &targetIsDir)
                if isDir && taken && targetIsDir.boolValue {
                    try merge(item, into: target, rel: rel + name + "/")
                    merged.append(item)
                } else {
                    let dest = taken ? freePath(target) : target
                    try fm.moveItem(at: item, to: dest)
                    moved.append((item, rel + name, dest))
                }
            }
        }
        do {
            try merge(old, into: new, rel: "")
        } catch {
            for m in moved.reversed() {
                try? fm.createDirectory(at: m.from.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: m.to, to: m.from)
            }
            throw error
        }
        // only now, and only folders left with nothing at all in them (not even hidden files), deepest first
        for dir in merged where (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
            try? fm.removeItem(at: dir)
        }
        return moved.map { ($0.rel, $0.to) }
    }
}
