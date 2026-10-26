import AppKit
import Combine

enum Tab { case active, focus, forgotten }

/// Which part of the app window has the keyboard. Tab cycles search → sidebar → list.
enum Pane { case search, sidebar, list }

/// The window's two faces. ⌘O goes tray → app (search, views, the tray's list) → Things-style to-do list → tray.
enum WindowMode: String { case app, things }

/// What ⌘Z puts back.
enum UndoStep {
    case reopen(Note)              // a todo was ticked or removed: open it again
    case close(Note, done: Bool)   // a closed todo was reopened: tick or remove it again
    case many([UndoStep])          // several todos changed at once (a multi-selection): one ⌘Z undoes them all
}

func copyToClipboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

struct FocusBlock {
    enum Mode { case idle, running, paused, timeUp }
    var mode: Mode = .idle
    var total: TimeInterval = TimeInterval(Config.defaultMinutes * 60)
    var remaining: TimeInterval = TimeInterval(Config.defaultMinutes * 60)
    var goal = ""
    var group: String?         // folder or list the block is about
    var label = ""
    var noteID: String?
    var resumeTTY: String?     // the iTerm tab you were in when you paused
    var pauses = 0
    var started: Date?
}

struct GroupInfo: Identifiable {
    var id: String { key }
    let key: String
    let isFolder: Bool
    var tasks: [Note]
    var sessions: [LiveSession]
    var last: Date?
    var tools: [String] { Array(Set(sessions.map(\.tool))).sorted() }
}

enum Row: Identifiable {
    case header(String)
    case about(Note)
    case group(GroupInfo, expanded: Bool)
    case task(Note)
    case session(LiveSession)
    case message(String, String)
    case closed(Note)              // a done or removed line (Logbook, Today, search)
    case create(String)            // "＋ Create …" at the end of search results

    var id: String {
        switch self {
        case .header(let t): return "h:" + t
        case .about(let n): return "a:" + n.id
        case .group(let g, _): return "g:" + g.key
        case .task(let n): return "t:" + n.id
        case .session(let s): return "s:" + s.tty
        case .message(let k, _): return "m:" + k
        case .closed(let n): return "c:" + n.id
        case .create: return "create"
        }
    }

    var navigable: Bool {
        switch self {
        case .about, .group, .task, .session, .closed, .create: return true
        default: return false
        }
    }
}

struct ForgottenItem: Identifiable {
    enum Kind: String, CaseIterable {
        case todo = "Todos nobody touched"
        case session = "Sessions left open"
        case branch = "Branches never merged"
        case folder = "Folders gone quiet"
    }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let ref: String
    var isDemo = false
}

/// A project (folder or list) a capture can go to.
struct NotesFolderError: LocalizedError {
    let errorDescription: String?
    init(_ s: String) { errorDescription = s }
}

struct Target: Identifiable, Hashable {
    var id: String { section + "|" + label }
    let group: String
    let label: String
    let sub: String?
    let section: String
    var isNew = false
}

final class Store: ObservableObject {
    @Published var notes: [Note] = []
    @Published var closed: [Note] = []
    @Published var focusToday: [FocusEntry] = []
    @Published var sessions: [LiveSession] = []
    @Published var activity: [String: Date] = [:]
    @Published var scannedAt = Date.distantPast
    @Published var scanning = false
    @Published var lastContext: CaptureContext?

    // popover state
    @Published var tab: Tab = .active
    @Published var query = ""
    @Published var expanded: Set<String> = []
    @Published var cursor: String?
    @Published var popoverOpenCount = 0
    @Published var hoverID: String?

    // app window (it shares `cursor` with the popover, so ⌘O keeps your place)
    @Published var appSelection = "*all" { didSet { remember(appSelection, "appSelection") } }
    @Published var appQuery = "" { didSet { if appQuery != oldValue { cursor = nil; clearSelection() } } }
    /// Extra rows picked with ⇧↑↓, ⇧-click or ⌘/⌃-click. Empty = just the cursor row.
    @Published var selection: Set<String> = []
    private var anchor: String?   // where a ⇧ range starts
    @Published var pane = Pane.search
    @Published var windowMode = WindowMode.app { didSet { remember(windowMode.rawValue, "windowMode") } }
    @Published var quietExpanded = false
    @Published var editingID: String?
    @Published var editText = ""
    @Published var adding: String?        // ⌘N: the folder or list the inline new-todo row files into
    @Published var addText = ""
    @Published var confirmRemove: [Note] = []
    @Published var toast: String?
    @Published var report: String?        // a frozen report, shown over the list
    @Published var reportURL: URL?
    @Published var narrating = false
    private var undoStack: [UndoStep] = []
    /// Set when typing outside the search bar started a search: the field selects all its text when it gets the
    /// keyboard, so the key monitor moves the caret to the end before the next letter lands.
    var caretToEnd = false
    /// The window's height, for how far Page Up / Page Down jump.
    var pageHeight: CGFloat = 600

    /// About one screenful of rows, minus a few so you keep your bearings.
    private func pageRows(rowHeight: CGFloat) -> Int { max(3, Int(pageHeight / rowHeight) - 4) }
    private var toastSeq = 0

    // focus
    @Published var focus = FocusBlock()
    @Published var pickedNoteID: String?
    @Published var newGoal = ""
    @Published var minutes = Config.defaultMinutes
    @Published var blocksToday = 0

    @Published var userLists: [String] = UserDefaults.standard.stringArray(forKey: "userLists") ?? []
    @Published var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "hidden") ?? [])
    @Published var revived: [String: Date] = (UserDefaults.standard.dictionary(forKey: "revived") as? [String: Date]) ?? [:]
    @Published var demoForgotten: [ForgottenItem] = [
        ForgottenItem(id: "demo-branch", kind: .branch,
                      title: "retry-backoff-for-webhooks",
                      detail: "~/code/acme-api · last commit 41d ago · never merged (demo)",
                      ref: "", isDemo: true),
    ]

    var onOpenCapture: ((Bool) -> Void)?
    var onTimeUp: (() -> Void)?
    var onClosePopover: (() -> Void)?
    var onOpenApp: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Where the notes live (Settings can move them).
    @Published var notesFolder = Config.notesDir
    private var lastTick = Date()

    /// `persist`: remember the window's view (app or to-do list) and selection across launches. The self-test
    /// turns it off so it never touches the real app's state.
    private let persist: Bool

    init(persist: Bool = true) {
        self.persist = persist
        blocksToday = FocusLog.countToday()
        if persist {
            let d = UserDefaults.standard
            windowMode = d.string(forKey: "windowMode").flatMap(WindowMode.init(rawValue:)) ?? .app
            appSelection = d.string(forKey: "appSelection") ?? "*all"
            let known = windowMode == .things ? Self.thingsViews : Self.views + ["*forgotten"]
            if appSelection.hasPrefix("*"), !known.contains(appSelection) {
                appSelection = "*all"   // a view that's gone (Active, Where you were, Today, Inbox) or not in this mode
            }
        }
    }

    private func remember(_ value: String, _ key: String) {
        if persist { UserDefaults.standard.set(value, forKey: key) }
    }

    // MARK: loading

    func reloadNotes() {
        let real = NotesFS.loadAll()
        notes = real.isEmpty && !NotesFS.everUsed() ? Self.demoNotes() : real
        closed = NotesFS.loadClosed()
        reloadFocusLog()
    }

    func reloadFocusLog() {
        let start = workday()
        focusToday = FocusLog.entries(from: start, to: workdayEnd(start))
        blocksToday = focusToday.count
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let folders = Config.hotFolders + Config.watchedFolders
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Discovery.scan(folders: folders)
            DispatchQueue.main.async {
                self.sessions = r.sessions
                self.activity = r.activity
                self.scannedAt = Date()
                self.scanning = false
            }
        }
    }

    func detectContext() {
        DispatchQueue.global(qos: .userInitiated).async {
            let c = Discovery.frontContext()
            DispatchQueue.main.async { self.lastContext = c }
        }
    }

    // MARK: groups

    var aboutNotes: [Note] { notes.filter(\.isAbout).sorted { $0.created > $1.created } }
    var queryLower: String { query.trimmed.lowercased() }
    var allLists: [String] {
        var set = Set(["General"] + userLists)
        notes.filter { !$0.group.hasPrefix("~") }.forEach { set.insert($0.group) }
        return set.sorted()
    }

    func allGroups() -> [GroupInfo] {
        var folders = Set(Config.hotFolders + Config.watchedFolders)
        sessions.forEach { folders.insert($0.folder) }
        notes.filter { $0.group.hasPrefix("~") }.forEach { folders.insert($0.group) }
        var out: [GroupInfo] = []
        for f in folders where !hidden.contains(f) {
            let tasks = notes.filter { $0.group == f }.sorted { $0.created > $1.created }
            let live = sessions.filter { $0.folder == f && !hidden.contains("session:" + $0.tty) }
            let last = ([activity[f], revived[f], tasks.first?.created] + live.map(\.lastActive)).compactMap { $0 }.max()
            out.append(GroupInfo(key: f, isFolder: true, tasks: tasks, sessions: live, last: last))
        }
        for l in allLists {
            let tasks = notes.filter { $0.group == l }.sorted { $0.created > $1.created }
            out.append(GroupInfo(key: l, isFolder: false, tasks: tasks, sessions: [], last: tasks.first?.created))
        }
        return out.sorted { ($0.last ?? .distantPast) > ($1.last ?? .distantPast) }
    }

    /// General first, then your lists alphabetically.
    var orderedLists: [String] { ["General"] + allLists.filter { $0 != "General" } }

    func isQuiet(_ g: GroupInfo) -> Bool {
        guard g.isFolder, g.tasks.isEmpty, g.sessions.isEmpty else { return false }
        guard let last = g.last else { return true }
        return Date().timeIntervalSince(last) > Config.quietAfter
    }

    var activeGroups: [GroupInfo] { allGroups().filter { !isQuiet($0) } }

    func rows() -> [Row] {
        let q = queryLower
        var out: [Row] = []
        if q.isEmpty, !aboutNotes.isEmpty {
            out.append(.header("Where you were"))
            out += aboutNotes.map { .about($0) }
        }
        out.append(.header("Folders & lists"))
        var shown = 0
        for g in activeGroups {
            let hay = ([g.key] + g.sessions.map { "\($0.tool) \($0.branch ?? "") \($0.title ?? "")" })
                .joined(separator: " ").lowercased()
            let nameHit = q.isEmpty || hay.contains(q)
            let hits = q.isEmpty ? g.tasks : g.tasks.filter { $0.text.lowercased().contains(q) }
            if !q.isEmpty && !nameHit && hits.isEmpty { continue }
            shown += 1
            let open = expanded.contains(g.key) || (!q.isEmpty && !hits.isEmpty)
            out.append(.group(g, expanded: open))
            guard open else { continue }
            let tasks = (!q.isEmpty && !nameHit) ? hits : g.tasks
            out += tasks.map { .task($0) }
            if tasks.isEmpty && g.sessions.isEmpty { out.append(.message(g.key, "no todos here")) }
            out += g.sessions.map { .session($0) }
        }
        if shown == 0 { out.append(.message("none", "nothing matches “\(query)” · ⌥⌘N to capture it")) }
        return out
    }

    // MARK: keyboard (Active items)

    /// Arrow keys move, → opens a folder, ← closes it, ↩ toggles / focuses / brings the tab.
    func handleKey(_ ev: NSEvent) -> Bool {
        guard tab == .active else { return false }
        let rows = rows()
        let current = rows.first { $0.id == cursor }
        switch ev.keyCode {
        case 125: moveCursor(1, rows); return true
        case 126: moveCursor(-1, rows); return true
        case 124:
            guard case .group(let g, _)? = current else { return false }
            expanded.insert(g.key)
            return true
        case 123:
            switch current {
            case .group(let g, _)?: expanded.remove(g.key)
            case .task(let n)?: expanded.remove(n.group); cursor = "g:" + n.group
            case .session(let s)?: expanded.remove(s.folder); cursor = "g:" + s.folder
            default: return false
            }
            return true
        case 36, 76:
            switch current {
            case .group(let g, _)?:
                if ev.modifierFlags.contains(.command) && g.isFolder { bringTab(folder: g.key) } else { toggle(g.key) }
            case .task(let n)?, .about(let n)?: focusOn(n)
            case .session(let s)?: bringTab(session: s)
            default: return false
            }
            return true
        case 53:
            guard !query.isEmpty else { return false }
            query = ""
            return true
        default:
            return false
        }
    }

    private func moveCursor(_ d: Int, _ rows: [Row]) {
        let nav = rows.filter(\.navigable).map(\.id)
        guard !nav.isEmpty else { return }
        if let c = cursor, let i = nav.firstIndex(of: c) {
            cursor = i + d < 0 ? nil : nav[min(i + d, nav.count - 1)]
        } else if d > 0 {
            cursor = nav.first
        }
    }

    func setHover(_ id: String, _ on: Bool) {
        if on { hoverID = id } else if hoverID == id { hoverID = nil }
    }

    func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    // MARK: terminal

    func bringTab(session s: LiveSession) {
        onClosePopover?()
        DispatchQueue.global(qos: .userInitiated).async { ITerm.select(tty: s.tty) }
    }

    /// The tab you typed in most recently for that folder, or a new tab cd'ed into it.
    func bringTab(folder: String, preferring tty: String? = nil) {
        onClosePopover?()
        let candidates = sessions.filter { $0.folder == folder }
        // only trust the remembered tty while it still runs an agent in that same folder
        let preferred = tty.flatMap { t in candidates.first { $0.tty == t } }
        DispatchQueue.global(qos: .userInitiated).async {
            if let preferred, ITerm.select(tty: preferred.tty) { return }
            let best = candidates.max { (mtime($0.tty) ?? .distantPast) < (mtime($1.tty) ?? .distantPast) }
            if let best, ITerm.select(tty: best.tty) { return }
            ITerm.openTab(in: folder)
        }
    }

    /// Back to the tab the note was written in (falls back to the folder rule).
    func bringTab(note: Note) {
        guard note.group.hasPrefix("~") else { return }
        bringTab(folder: note.group, preferring: note.tty)
    }

    // MARK: todos

    /// Ticks todos (⌘K). One ⌘Z opens them all again.
    func complete(_ ns: [Note]) {
        change(ns, { $0 == 1 ? "Done ✓ · in the Logbook · ⌘Z to undo" : "\($0) done ✓ · ⌘Z to undo" }) { n in
            try NotesFS.complete(n).map { .reopen($0) }
        }
    }

    func complete(_ n: Note) { complete([n]) }

    /// ⌫ after the confirmation: each line becomes "- [-] …". Nothing is erased; ⌘Z opens them again.
    func removeTodos(_ ns: [Note]) {
        change(ns, { $0 == 1 ? "Removed · ⌘Z brings it back" : "\($0) removed · ⌘Z brings them back" }) { n in
            try NotesFS.remove(n).map { .reopen($0) }
        }
    }

    func removeTodo(_ n: Note) { removeTodos([n]) }

    /// Opens done or removed lines again (⌘K in the Logbook).
    func reopen(_ cs: [Note]) {
        change(cs, { $0 == 1 ? "Reopened · ⌘Z to undo" : "\($0) reopened · ⌘Z to undo" }) { c in
            try NotesFS.reopen(c).map { .close($0, done: c.state == .done) }
        }
    }

    func reopen(_ c: Note) { reopen([c]) }

    /// Applies `op` to each todo, as one undo step, then rereads the files.
    private func change(_ ns: [Note], _ message: (Int) -> String, _ op: (Note) throws -> UndoStep?) {
        let demo = Set(ns.filter(\.isDemo).map(\.id))
        notes.removeAll { demo.contains($0.id) }   // demo todos live only in memory
        let real = ns.filter { !$0.isDemo }
        clearSelection()
        guard !real.isEmpty else { return }
        keepPlace {
            var steps: [UndoStep] = []
            for n in real {
                if let step = try? op(relocated(n)) { steps.append(step) }
            }
            if !steps.isEmpty {
                undoStack.append(steps.count == 1 ? steps[0] : .many(steps))
                say(message(steps.count))
            }
            reloadNotes()
        }
    }

    func undo() {
        guard let step = undoStack.popLast() else {
            say("Nothing to undo")
            return
        }
        keepPlace {
            apply(step)
            reloadNotes()
        }
        say("Undone")
    }

    private func apply(_ step: UndoStep) {
        switch step {
        case .reopen(let c): _ = try? NotesFS.reopen(relocated(c))
        case .close(let o, let done): _ = try? (done ? NotesFS.complete(relocated(o)) : NotesFS.remove(relocated(o)))
        case .many(let steps): steps.reversed().forEach(apply)
        }
    }

    /// The same line after its file moved (done/ ↔ its folder) while several todos of one capture changed together.
    private func relocated(_ n: Note) -> Note {
        guard let f = n.file, !FileManager.default.fileExists(atPath: f.path) else { return n }
        let name = f.deletingPathExtension().lastPathComponent
        let pool = n.state == .open ? NotesFS.loadAll() : NotesFS.loadClosed()
        return pool.first {
            $0.text == n.text && $0.state == n.state && $0.isAbout == n.isAbout
                && $0.file?.deletingPathExtension().lastPathComponent.hasPrefix(name) == true
        } ?? n
    }

    // MARK: multi-selection

    /// The rows an action applies to: the selection, or just the cursor row.
    var picked: Set<String> { selection.isEmpty ? Set([cursor].compactMap { $0 }) : selection }

    /// ⌘A: every todo in the list (in the Logbook, every closed line), so ⌘K, Space and ⌫ act on all of them.
    func selectAllRows() {
        let ids = listRows().filter {
            switch $0 {
            case .task, .about, .closed: return true
            default: return false
            }
        }.map(\.id)
        guard !ids.isEmpty else { return }
        selection = Set(ids)
        anchor = ids.first
        if !ids.contains(cursor ?? "") { cursor = ids.first }
    }

    func clearSelection() {
        if !selection.isEmpty { selection = [] }
        anchor = nil
    }

    /// A click on a row: plain = just that row, ⇧ = a range from the last click, ⌘ or ⌃ = add or drop that row.
    func click(_ id: String, _ mods: NSEvent.ModifierFlags) {
        let nav = listRows().filter(\.navigable).map(\.id)
        if mods.contains(.shift), let a = anchor ?? cursor, let i = nav.firstIndex(of: a), let j = nav.firstIndex(of: id) {
            selection = Set(nav[min(i, j)...max(i, j)])
            anchor = a
        } else if mods.contains(.command) || mods.contains(.control) {
            if selection.isEmpty, let c = cursor { selection = [c] }
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else {
            clearSelection()
            anchor = id
        }
        cursor = id
    }

    /// The open todos among the picked rows, and the closed ones.
    private func pickedNotes() -> (open: [Note], closed: [Note]) {
        let ids = picked
        var open: [Note] = []
        var closed: [Note] = []
        for row in listRows() where ids.contains(row.id) {
            switch row {
            case .task(let n), .about(let n): if !open.contains(n) { open.append(n) }
            case .closed(let c): closed.append(c)
            default: break
            }
        }
        return (open, closed)
    }

    /// ⌘K / Space: tick the picked todos; when only closed ones are picked (Logbook), reopen them.
    func toggleDonePicked() {
        let p = pickedNotes()
        if !p.open.isEmpty { complete(p.open) } else if !p.closed.isEmpty { reopen(p.closed) }
    }

    /// After a row disappears, the cursor stays at the same height in the window's list.
    private func keepPlace(_ change: () -> Void) {
        let before = listRows().filter(\.navigable).map(\.id)
        let i = cursor.flatMap { before.firstIndex(of: $0) }
        change()
        let after = listRows().filter(\.navigable).map(\.id)
        guard let i, let c = cursor, !after.contains(c) else { return }
        cursor = after.isEmpty ? nil : after[min(i, after.count - 1)]
    }

    func say(_ text: String) {
        toast = text
        toastSeq += 1
        let seq = toastSeq
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if self.toastSeq == seq { self.toast = nil } }
    }

    func addList(_ name: String) {
        guard !name.isEmpty, !userLists.contains(name) else { return }
        userLists.append(name)
        if persist { UserDefaults.standard.set(userLists, forKey: "userLists") }
    }

    func captureTargets(context: CaptureContext?) -> [Target] {
        var out = [CaptureModel.general]
        var seen: Set<String> = ["General"]
        if let c = context {
            out.append(Target(group: c.folder, label: c.label, sub: c.branch.map(shortBranch), section: "Active session"))
            seen.insert(c.label)
        }
        for l in allLists where !seen.contains(l) {
            out.append(Target(group: l, label: l, sub: nil, section: "Your lists"))
            seen.insert(l)
        }
        for s in sessions where !seen.contains(s.label) {
            out.append(Target(group: s.folder, label: s.label, sub: s.branch.map(shortBranch), section: "Running now"))
            seen.insert(s.label)
        }
        for g in activeGroups where g.isFolder && g.sessions.isEmpty && !seen.contains(g.key) {
            out.append(Target(group: g.key, label: g.key, sub: nil, section: "Recent projects"))
        }
        return out
    }

    /// The "about to" line stays with where you were; the notes go where you filed them.
    func saveCapture(about: String, lines: [String], target: Target, context: CaptureContext?, fromEnd: Bool) {
        let here = context?.folder ?? "General"
        let hereLabel = context?.label ?? "General"
        let capturedIn = [context?.label, context?.branch, context?.title].compactMap { $0 }.joined(separator: " · ")
        let focusLine = focus.mode == .idle ? nil : "\"\(focus.goal)\" (paused, \(fmtTime(focus.remaining)) left)"
        if target.isNew { addList(target.group) }
        let targetBranch = target.group == here ? context?.branch : sessions.first { $0.folder == target.group }?.branch
        let tty = context?.tty
        if focus.mode == .paused, let tty { focus.resumeTTY = tty }
        do {
            if !about.isEmpty && target.group != here {
                try NotesFS.write(group: here, filedUnder: hereLabel, branch: context?.branch, tty: tty,
                                  capturedIn: capturedIn, focus: focusLine, about: about, items: [])
                if !lines.isEmpty {
                    try NotesFS.write(group: target.group, filedUnder: target.label, branch: targetBranch, tty: tty,
                                      capturedIn: capturedIn, focus: focusLine, about: nil, items: lines)
                }
            } else {
                try NotesFS.write(group: target.group, filedUnder: target.label, branch: targetBranch, tty: tty,
                                  capturedIn: capturedIn, focus: focusLine, about: about.isEmpty ? nil : about, items: lines)
            }
        } catch {
            NSLog("titi: could not write note: \(error)")
        }
        if fromEnd || focus.mode == .timeUp {
            logBlock("not yet")
            focus = FocusBlock()
        }
        reloadNotes()
    }

    // MARK: focus

    var canStart: Bool { pickedNoteID != nil || !newGoal.trimmed.isEmpty }

    func focusOn(_ n: Note) {
        guard focus.mode == .idle else { return }
        pickedNoteID = n.id
        newGoal = ""
        tab = .focus
    }

    func startFocus() {
        var f = FocusBlock()
        f.total = TimeInterval(minutes * 60)
        f.remaining = f.total
        f.started = Date()
        if let id = pickedNoteID, let n = notes.first(where: { $0.id == id }) {
            f.goal = n.text
            f.group = n.group
            f.label = n.filedUnder
            f.noteID = n.id
            f.resumeTTY = n.tty
        } else {
            let goal = newGoal.trimmed
            guard !goal.isEmpty else { return }
            f.goal = goal
            f.group = lastContext?.folder
            f.label = lastContext?.label ?? "General"
            f.resumeTTY = lastContext?.tty
        }
        f.mode = .running
        focus = f
        pickedNoteID = nil
        newGoal = ""
        lastTick = Date()
        onClosePopover?()
    }

    func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        lastTick = now
        guard focus.mode == .running else { return }
        focus.remaining -= dt * Config.speed
        if focus.remaining <= 0 {
            focus.remaining = 0
            focus.mode = .timeUp
            onTimeUp?()
        }
    }

    func pauseForCapture() {
        if focus.mode == .running {
            focus.mode = .paused
            focus.pauses += 1
        }
    }

    func interrupt() {
        onClosePopover?()
        onOpenCapture?(false)
    }

    func resume() {
        guard focus.mode == .paused else { return }
        focus.mode = .running
        lastTick = Date()
        if let g = focus.group, g.hasPrefix("~") {
            bringTab(folder: g, preferring: focus.resumeTTY)
        } else {
            onClosePopover?()
        }
    }

    func stopFocus() {
        logBlock("stopped")
        focus = FocusBlock()
    }

    func nailed() {
        logBlock("nailed it")
        if let id = focus.noteID, let n = notes.first(where: { $0.id == id }) { complete(n) }
        focus = FocusBlock()
        onClosePopover?()
    }

    func extend() {
        focus.total += 600
        focus.remaining = 600
        focus.mode = .running
        lastTick = Date()
        onClosePopover?()
    }

    func notYet() {
        onClosePopover?()
        onOpenCapture?(true)
    }

    private func logBlock(_ outcome: String) {
        FocusLog.append(focus, outcome: outcome)
        reloadFocusLog()
    }

    // MARK: app window

    /// Newest first. Todos with the same time keep a fixed order: file order within a capture, else by file name.
    var sortedNotes: [Note] {
        notes.sorted { a, b in
            if a.created != b.created { return a.created > b.created }
            if a.file == b.file { return (a.line ?? 0) < (b.line ?? 0) }
            return (a.file?.lastPathComponent ?? a.id) > (b.file?.lastPathComponent ?? b.id)
        }
    }

    var doneToday: Int {
        let start = workday()
        return closed.filter { $0.state == .done && ($0.closedAt ?? .distantPast) >= start }.count
    }

    /// The views on top of the sidebar: TODOs ⌘1, Logbook ⌘2, Focus ⌘3.
    static let views = ["*all", "*logbook", "*focus"]
    /// The Things view's: TODOs (every open todo, newest first, whatever the folder) and the Logbook; ⌘1, ⌘2.
    static let thingsViews = ["*all", "*logbook"]

    /// The second ⌘O: the same window as a Things-style to-do list, on the folder or list selected in the app,
    /// else on TODOs.
    func enterThings() {
        let key = Self.thingsViews.contains(appSelection) || !appSelection.hasPrefix("*") ? appSelection : "*all"
        let keep = cursor
        windowMode = .things
        select(key)
        if let keep, listRows().contains(where: { $0.id == keep }) { cursor = keep } else { cursorToFirst() }
        pane = .list
    }

    /// Tray → window: land where the popover's cursor was. A todo stays picked in TODOs, a folder or session opens
    /// that folder; with no cursor, TODOs (or Focus, if the tray was on its Focus tab).
    func enterFromTray(cursor c: String?) {
        let id = String((c ?? "").dropFirst(2))
        switch c?.prefix(2) {
        case "g:":
            select(id)
            cursorToFirst()
        case "s:":
            select(sessions.first { $0.tty == id }?.folder ?? "*all")
            cursorToFirst()
        case "t:", "a:":
            select("*all")
            cursor = "t:" + id
        default:
            select(tab == .focus && windowMode == .app ? "*focus" : "*all")
        }
        pane = cursor == nil ? .search : .list
    }

    /// Window → tray: keep the cursor on a row the popover shows. A todo's folder opens there; a Logbook line or
    /// a todo in a quiet folder has no row in the tray, so the cursor goes.
    func cursorForTray() {
        guard let c = cursor else { return }
        let id = String(c.dropFirst(2))
        if c.hasPrefix("t:"), let n = notes.first(where: { $0.id == id }) { expanded.insert(n.group) }
        let shown = rows().map(\.id)
        if !shown.contains(c) { cursor = shown.contains("a:" + id) ? "a:" + id : nil }
    }

    /// The sidebar in keyboard order.
    func sidebarKeys() -> [String] {
        let groups = allGroups()
        if windowMode == .things {
            return Self.thingsViews + groups.filter { $0.isFolder && !isQuiet($0) }.map(\.key)
                + orderedLists.filter { $0 != "General" }
        }
        return Self.views + orderedLists
            + groups.filter { $0.isFolder && !isQuiet($0) }.map(\.key)
            + (quietExpanded ? groups.filter { isQuiet($0) }.map(\.key) : [])
    }

    func select(_ key: String) {
        appSelection = key
        appQuery = ""
        cursor = nil
        clearSelection()
        adding = nil
        report = nil
    }

    /// Where ⌘N files a new todo: the selected folder or list, else General.
    var addTarget: String { appSelection.hasPrefix("*") ? "General" : appSelection }

    /// Where ↩ in the search bar creates a todo when nothing matches.
    var createTarget: String { appSelection.hasPrefix("*") ? "General" : appSelection }

    /// The window's list: search results, a view, or one folder or list.
    func listRows() -> [Row] {
        let q = appQuery.trimmed.lowercased()
        if !q.isEmpty { return searchRows(q) }
        let list: [Row]
        switch appSelection {
        case "*logbook": return logbookRows()
        case "*focus", "*forgotten": return []
        case "*all": list = sortedNotes.map { .task($0) }
        default: list = sortedNotes.filter { $0.group == appSelection }.map { .task($0) }
        }
        return list.isEmpty ? [.message("empty", "nothing open here · ⌘N adds a todo")] : list
    }

    /// Open and closed matches everywhere, then an explicit "Create" row.
    private func searchRows(_ q: String) -> [Row] {
        let hit = { (n: Note) in (n.text + " " + n.group + " " + (n.branch ?? "") + " " + n.filedUnder).lowercased().contains(q) }
        let open = sortedNotes.filter(hit)
        let done = closed.filter(hit).sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        var out: [Row] = [.header("Open · \(open.count)")]
        out += open.map { .task($0) }
        if !done.isEmpty {
            out.append(.header("Closed · \(done.count)"))
            out += done.map { .closed($0) }
        }
        out.append(.create(appQuery.trimmed))
        return out
    }

    /// Closed lines by workday, newest first. Lines ticked outside titi have no date and go last.
    private func logbookRows() -> [Row] {
        let dated = closed.filter { $0.closedAt != nil }.sorted { $0.closedAt! > $1.closedAt! }
        var perDay: [Date: (done: Int, removed: Int)] = [:]
        for n in dated {
            let d = workday(n.closedAt!)
            if n.state == .done { perDay[d, default: (0, 0)].done += 1 } else { perDay[d, default: (0, 0)].removed += 1 }
        }
        var out: [Row] = []
        var day: Date?
        for n in dated {
            let d = workday(n.closedAt!)
            if d != day {
                day = d
                let c = perDay[d]!
                out.append(.header(dayLabel(d) + " · \(c.done) done" + (c.removed > 0 ? " · \(c.removed) removed" : "")))
            }
            out.append(.closed(n))
        }
        let unknown = closed.filter { $0.closedAt == nil }
        if !unknown.isEmpty {
            out.append(.header("Date unknown · ticked outside titi · \(unknown.count)"))
            out += unknown.map { .closed($0) }
        }
        return out.isEmpty ? [.message("empty", "nothing closed yet · ⌘K ticks the selected todo")] : out
    }

    private static let dayTitle: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()

    func dayLabel(_ d: Date) -> String {
        let today = workday()
        if d == today { return "Today" }
        if d == workday(today.addingTimeInterval(-3600)) { return "Yesterday" }
        return Self.dayTitle.string(from: d)
    }

    // MARK: app window keys

    func cursorRow() -> Row? {
        guard let c = cursor else { return nil }
        return listRows().first { $0.id == c }
    }

    func cursorToFirst() {
        cursor = listRows().first(where: \.navigable)?.id
    }

    /// Every key in the app window comes here first, before any text field sees it. Bare keys act only when no
    /// text field has the keyboard, and nothing destructive happens without a row you picked. True = swallowed.
    func handleAppKey(_ ev: NSEvent, textEditing: Bool) -> Bool {
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command)
        let key = ev.keyCode
        let ch = ev.charactersIgnoringModifiers?.lowercased() ?? ""

        if !confirmRemove.isEmpty {   // the confirmation box owns the keyboard
            if key == 36 || key == 76 {
                let ns = confirmRemove
                confirmRemove = []
                removeTodos(ns)
            } else if key == 53 {
                confirmRemove = []
            }
            return true
        }
        if editingID != nil || adding != nil {   // the edit field and the new-todo row get everything but esc
            guard key == 53 else { return false }
            if editingID != nil { editingID = nil } else { adding = nil; addText = "" }
            return true
        }
        if report != nil, key == 53 {
            report = nil
            return true
        }
        // another text field has the keyboard (the Focus goal, selectable text): leave its keys alone
        if textEditing, pane != .search { return false }
        if report != nil, pane != .search, key != 48, !(cmd && ["1", "2", "3", "l"].contains(ch)) {
            // the report covers the list: no key may act on rows you can't see
            return !cmd || ch == "k" || ch == "z" || [51, 117, 36, 76].contains(key)
        }

        if cmd {
            switch ch {
            case "1", "2", "3":
                let views = windowMode == .things ? Self.thingsViews : Self.views
                guard Int(ch)! <= views.count else { return false }
                select(views[Int(ch)! - 1])
                pane = .list
                cursorToFirst()
                return true
            case "a":
                guard pane != .search else { return false }   // the search bar selects its text
                selectAllRows()
                pane = .list
                return true
            case "l":
                guard windowMode == .app else { return false }   // the Things view has no search bar
                pane = .search
                return true
            case "k":
                guard pane == .list else { return false }
                toggleDonePicked()
                return true
            case "z" where !mods.contains(.shift):
                guard pane != .search else { return false }   // the search field's own undo
                undo()
                return true
            default:
                break
            }
            guard pane == .list else { return false }
            switch key {
            case 51, 117:   // ⌘⌫ removes too
                askRemove()
                return true
            case 36, 76:
                cmdReturn()
                return true
            default:
                return false
            }
        }

        if key == 48 {   // Tab / ⇧Tab
            let order: [Pane] = windowMode == .things ? [.sidebar, .list] : [.search, .sidebar, .list]
            let i = order.firstIndex(of: pane) ?? 0
            pane = order[(i + (mods.contains(.shift) ? order.count - 1 : 1)) % order.count]
            if pane == .list, cursorRow() == nil { cursorToFirst() }
            return true
        }

        switch pane {
        case .search: return searchKey(key, ev, textEditing: textEditing)
        case .sidebar: return sidebarKey(key, ev)
        case .list: return listKey(key, ev)
        }
    }

    private func searchKey(_ key: UInt16, _ ev: NSEvent, textEditing: Bool) -> Bool {
        let q = appQuery.trimmed
        switch key {
        case 125:   // ↓ into the results, or into the sidebar
            if q.isEmpty {
                pane = .sidebar
            } else {
                pane = .list
                cursorToFirst()
            }
            return true
        case 36, 76:   // ↩ creates only when nothing matches; otherwise it steps into the results
            if q.isEmpty || listRows().contains(where: { if case .create = $0 { return false }; return $0.navigable }) {
                pane = .list
                cursorToFirst()
            } else {
                createFromQuery()
            }
            return true
        case 53:
            guard !appQuery.isEmpty else { return false }
            appQuery = ""
            return true
        default:
            // until the field has the keyboard, keep the letters yourself
            return textEditing ? false : typeToSearch(ev)
        }
    }

    private func sidebarKey(_ key: UInt16, _ ev: NSEvent) -> Bool {
        let keys = sidebarKeys()
        let i = keys.firstIndex(of: appSelection) ?? 0
        switch key {
        case 116, 121, 115, 119:   // Page Up, Page Down, Home, End
            let page = pageRows(rowHeight: 26)
            let to = [116: i - page, 121: i + page, 115: 0, 119: keys.count - 1][Int(key)]!
            select(keys[min(max(to, 0), keys.count - 1)])
            return true
        case 125:
            select(keys[min(i + 1, keys.count - 1)])
            return true
        case 126:
            if i > 0 { select(keys[i - 1]) } else if windowMode == .app { pane = .search }
            return true
        case 124, 36, 76:
            pane = .list
            cursorToFirst()
            return true
        case 53:
            return true
        default:
            return typeToSearch(ev)
        }
    }

    private func listKey(_ key: UInt16, _ ev: NSEvent) -> Bool {
        let rows = listRows()
        let row = rows.first { $0.id == cursor }
        switch key {
        case 125, 126, 116, 121, 115, 119:   // ↓ ↑ Page Up, Page Down, Home, End
            let nav = rows.filter(\.navigable).map(\.id)
            guard !nav.isEmpty else { return true }
            guard let c = cursor, let i = nav.firstIndex(of: c) else {
                cursor = key == 119 ? nav.last : nav.first   // End picks the last row, anything else the first
                return true
            }
            let page = pageRows(rowHeight: 38)
            let to = min(max([125: i + 1, 126: i - 1, 116: i - page, 121: i + page, 115: 0, 119: nav.count - 1][Int(key)]!, 0),
                         nav.count - 1)
            if ev.modifierFlags.contains(.shift) {   // ⇧ extends the selection from where it started
                let a = anchor.flatMap { nav.firstIndex(of: $0) } ?? i
                anchor = nav[a]
                selection = Set(nav[min(a, to)...max(a, to)])
            } else {
                clearSelection()
            }
            cursor = nav[to]
            return true
        case 124:
            return true
        case 123:   // ← back to the sidebar
            pane = .sidebar
            return true
        case 36, 76:
            switch row {
            case .group(let g, _)?: toggle(g.key)
            case .session(let s)?: bringTab(session: s)
            case .task(let n)?, .about(let n)?: beginEdit(n)
            case .create?: createFromQuery()
            default: break
            }
            return true
        case 49:   // space = ⌘K
            toggleDonePicked()
            return true
        case 51, 117:
            askRemove()
            return true
        case 53:
            if !selection.isEmpty {
                clearSelection()
            } else if appQuery.isEmpty {
                pane = .sidebar
            } else {
                appQuery = ""
                pane = .search
            }
            return true
        default:
            return typeToSearch(ev)
        }
    }

    /// Typing a letter outside a text field starts a search, like Notational Velocity.
    private func typeToSearch(_ ev: NSEvent) -> Bool {
        guard windowMode == .app, let s = ev.characters, !s.isEmpty,
              s.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
        else { return false }
        appQuery += s
        pane = .search
        caretToEnd = true
        return true
    }

    private func cmdReturn() {
        switch cursorRow() {
        case .task(let n)?, .about(let n)?: startFocus(note: n)
        case .group(let g, _)? where g.isFolder: bringTab(folder: g.key)
        case .session(let s)?: bringTab(session: s)
        default: break
        }
    }

    /// ⌫ asks first, and only for todos you picked.
    func askRemove() {
        confirmRemove = pickedNotes().open
    }

    // MARK: creating and editing

    /// ⌘N: an empty row at the top of the list that files into the selected folder or list.
    func startAdd() {
        let target = addTarget
        // the lists that show every folder stay put; the new todo appears on top of them
        if !appQuery.isEmpty || (appSelection.hasPrefix("*") && appSelection != "*all") { select(target) }
        report = nil
        addText = ""
        adding = target
        pane = .list
    }

    /// ↩ in the new-todo row: write it and keep the row open for the next one.
    func saveAdd() {
        guard let g = adding else { return }
        let text = addText.trimmed
        guard !text.isEmpty else {
            adding = nil
            return
        }
        if let n = createTodo(text, in: g) { cursor = "t:" + n.id }
        addText = ""
        say("Added to \(g)")
    }

    /// The search text becomes a todo in the selected folder or list (General for the views on top).
    func createFromQuery() {
        let text = appQuery.trimmed
        guard !text.isEmpty else { return }
        let g = createTarget
        guard let n = createTodo(text, in: g) else { return }
        select(g)
        pane = .list
        cursor = "t:" + n.id
        say("Created in \(g)")
    }

    @discardableResult
    func createTodo(_ text: String, in g: String) -> Note? {
        let live = sessions.first { $0.folder == g }
        let branch = g.hasPrefix("~") ? (live?.branch ?? Discovery.gitBranch(expandTilde(g))) : nil
        do {
            let url = try NotesFS.write(group: g, filedUnder: live?.label ?? g, branch: branch, tty: nil,
                                        capturedIn: "titi window", focus: nil, about: nil, items: [text])
            reloadNotes()
            return notes.first { NotesFS.samePath($0.file, url) }
        } catch {
            NSLog("titi: could not create todo: \(error)")
            return nil
        }
    }

    func beginEdit(_ n: Note) {
        editText = n.text
        editingID = n.id
    }

    func commitEdit() {
        defer { editingID = nil }
        guard let id = editingID, let n = notes.first(where: { $0.id == id }) else { return }
        let text = editText.trimmed
        guard !text.isEmpty, text != n.text else { return }
        if n.isDemo {
            if let i = notes.firstIndex(where: { $0.id == id }) { notes[i].text = text }
        } else {
            try? NotesFS.edit(n, to: text)
            let line = n.line
            reloadNotes()
            if let m = notes.first(where: { $0.file == n.file && $0.line == line }) {
                cursor = (cursor?.hasPrefix("a:") == true ? "a:" : "t:") + m.id
            }
        }
    }

    func startFocus(note: Note) {
        guard focus.mode == .idle else { return }
        pickedNoteID = note.id
        startFocus()
    }

    // MARK: settings

    /// Settings → Notes folder: every note moves from `old` into `new` (NotesFS.moveAll: merges, never overwrites,
    /// all or nothing) and the app uses `new` from now on. Returns how many notes moved. The self-test's store
    /// (`persist` off) moves files between scratch folders but never saves the setting.
    @discardableResult
    func moveNotes(from old: URL = Config.notesDir, to new: URL) throws -> Int {
        if persist, let env = Config.notesDirFromEnv { throw NotesFolderError("The folder is set by TITI_NOTES_DIR (\(env)).") }
        if let p = NotesFS.problem(movingFrom: old, to: new) { throw NotesFolderError(p) }
        let count = NotesFS.countNotes(in: old)
        let moved = try NotesFS.moveAll(from: old, to: new)
        if persist {
            Report.reportsMoved(from: old, moved)
            UserDefaults.standard.set(new.path, forKey: "notesDir")
        }
        undoStack = []   // it points at the old paths
        notesFolder = Config.notesDir
        reloadNotes()
        say("Moved \(count) notes to \(tildify(new.path))")
        return count
    }

    // MARK: report

    /// ⌘S: today's report, saved to reports/YYYY-MM-DD.md and copied to the clipboard.
    func freezeReport() {
        windowMode = .app   // the report lives in the app view, over whatever view you're on
        appQuery = ""
        adding = nil
        editingID = nil
        pane = .list
        let day = workday()
        let open = notes.filter { !$0.isDemo }
        let closed = self.closed
        let focus = focusToday
        let folders = Report.gitFolders(notes: notes, sessions: sessions)
        say("Building today's report…")
        DispatchQueue.global(qos: .userInitiated).async {
            let commits = Report.commits(folders: folders, from: day, to: workdayEnd(day))
            let md = Report.markdown(day: day, open: open, closed: closed, commits: commits, focus: focus)
            let url = try? Report.save(md, day: day)
            DispatchQueue.main.async {
                self.report = md
                self.reportURL = url
                copyToClipboard(md)
                self.say(url.map { "Saved to reports/\($0.lastPathComponent) and copied" } ?? "Copied (the file could not be saved)")
            }
        }
    }

    func copyReport() {
        guard let md = report else { return }
        copyToClipboard(md)
        say("Copied")
    }

    func openReportFile() {
        if let u = reportURL { NSWorkspace.shared.open(u) }
    }

    /// Optional: `claude -p` writes a few summary lines under the report. The facts above stay as they are.
    func narrate() {
        guard let md = report, !narrating else { return }
        narrating = true
        say("Asking claude -p for a summary…")
        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("titi-report.md")
            try? md.write(to: tmp, atomically: true, encoding: .utf8)
            let prompt = "Summarise this workday report in at most 5 short lines for a standup. Use only facts from the report."
            let out = sh("/bin/zsh", ["-lc", "claude -p \(shellQuote(prompt)) < \(shellQuote(tmp.path))"]).trimmed
            DispatchQueue.main.async {
                self.narrating = false
                guard !out.isEmpty else {
                    self.say("claude -p gave no answer")
                    return
                }
                let full = md + "\n## Summary\n" + out + "\n"
                self.report = full
                self.reportURL = (try? Report.save(full, day: workday())) ?? self.reportURL
                copyToClipboard(full)
                self.say("Summary added, saved and copied")
            }
        }
    }

    // MARK: forgotten

    func forgottenItems() -> [ForgottenItem] {
        var out: [ForgottenItem] = []
        let now = Date()
        for n in notes where !n.isDemo && now.timeIntervalSince(n.created) > Config.forgottenTodoAfter {
            out.append(ForgottenItem(id: "todo:" + n.id, kind: .todo, title: n.text,
                                     detail: "\(n.filedUnder) · untouched \(ago(n.created))", ref: n.id))
        }
        for s in sessions where !hidden.contains("session:" + s.tty) {
            guard let idle = s.lastActive, now.timeIntervalSince(idle) > Config.staleSessionAfter else { continue }
            let what = [s.branch.map(shortBranch), s.title].compactMap { $0 }.first ?? "session"
            out.append(ForgottenItem(id: "session:" + s.tty, kind: .session, title: s.label,
                                     detail: "\(what) · open \(ago(s.started)), idle \(ago(idle))", ref: s.tty))
        }
        out += demoForgotten
        for g in allGroups() where isQuiet(g) {
            out.append(ForgottenItem(id: "folder:" + g.key, kind: .folder, title: g.key,
                                     detail: g.last.map { "quiet for \(ago($0))" } ?? "no activity found", ref: g.key))
        }
        return out
    }

    func revive(_ it: ForgottenItem) {
        switch it.kind {
        case .todo:
            if let n = notes.first(where: { $0.id == it.ref }) { try? NotesFS.revive(n) }
            reloadNotes()
        case .session:
            if let s = sessions.first(where: { $0.tty == it.ref }) { bringTab(session: s) }
        case .folder:
            revived[it.ref] = Date()
            if persist { UserDefaults.standard.set(revived, forKey: "revived") }
        case .branch:
            demoForgotten.removeAll { $0.id == it.id }
        }
    }

    /// Never deletes anything on disk: todos move to removed/, everything else is just hidden.
    func remove(_ it: ForgottenItem) {
        switch it.kind {
        case .todo:
            if let n = notes.first(where: { $0.id == it.ref }) { removeTodo(n) }
        case .session:
            hide("session:" + it.ref)
        case .folder:
            hide(it.ref)
        case .branch:
            demoForgotten.removeAll { $0.id == it.id }
        }
    }

    private func hide(_ key: String) {
        hidden.insert(key)
        if persist { UserDefaults.standard.set(Array(hidden), forKey: "hidden") }
    }

    // MARK: demo

    /// Shown only while general_todos/ has no notes yet, so the mock isn't empty. Never written to disk.
    static func demoNotes() -> [Note] {
        func n(_ text: String, _ group: String, _ label: String, _ branch: String?, _ minutesAgo: Double, about: Bool = false) -> Note {
            Note(id: "demo:" + text, text: text, group: group, filedUnder: label, branch: branch,
                 created: Date().addingTimeInterval(-minutesAgo * 60), isAbout: about, file: nil, line: nil, isDemo: true)
        }
        return [
            n("rerun the flaky checkout test before opening the PR", "~/code/acme-api",
              "Claude | ~/code/acme-api", "feature/faster-checkout", 120, about: true),
            n("compare p95 latency with last week's baseline", "~/code/acme-api",
              "Claude | ~/code/acme-api", "feature/faster-checkout", 121),
            n("sync with Sam about the cache eviction policy", "~/code/acme-web",
              "Codex | ~/code/acme-web", "fix/cache-eviction", 1440),
            n("write the onboarding checklist", "onboarding", "onboarding", nil, 7200),
            n("ask Dana how the invoices are exported", "General", "General", nil, 40),
        ]
    }
}
