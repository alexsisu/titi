import AppKit
import SwiftUI
import Vision

/// Read-only discovery report + a notes round-trip + the window's keys, in a scratch notes folder.
enum SelfTest {
    /// The process exit code: 0 when every check passed, 1 when any failed, 2 when it refused to run.
    static func run() -> Int32 {
        print("notes dir:", Config.notesDir.path)

        let t0 = Date()
        let scan = Discovery.scan(folders: Config.hotFolders + Config.watchedFolders)
        print(String(format: "scan took %.2fs", Date().timeIntervalSince(t0)))
        for s in scan.sessions {
            print("  live:", s.label, "| branch:", s.branch ?? "-", "| title:", s.title ?? "-",
                  "| open", ago(s.started), "| idle", ago(s.lastActive), "|", s.tty)
        }
        for (f, d) in scan.activity.sorted(by: { $0.value > $1.value }) {
            print("  activity:", f, ago(d))
        }
        if let c = Discovery.frontContext() {
            print("front iTerm context:", c.label, "| branch:", c.branch ?? "-", "| tty:", c.tty ?? "-")
        } else {
            print("front iTerm context: none")
        }

        // notes round-trip
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "  ok  " : "  FAIL", what)
            if !ok { failures += 1 }
        }
        guard !NotesFS.everUsed() else {
            print("refusing to write test notes into \(Config.notesDir.path): it already has notes. "
                  + "Run without TITI_NOTES_DIR (a scratch folder is used) or point it at an empty folder.")
            return 2
        }
        do {
            check(!NotesFS.everUsed(), "empty notes folder shows demo todos")
            let a = try NotesFS.write(group: "~/code/acme-api", filedUnder: "Claude | ~/code/acme-api",
                                      branch: "feature/x", tty: "/dev/ttys005", capturedIn: "test", focus: nil,
                                      about: "run the manual test", items: ["ask Dana", "check the table"])
            try NotesFS.write(group: "errands", filedUnder: "errands", branch: nil, capturedIn: "test", focus: nil,
                              about: nil, items: ["better indexes"])
            check(a.path.contains("/code_acme-api/"), "folder notes land in code_acme-api/")
            var notes = NotesFS.loadAll()
            check(notes.count == 4, "4 open todos loaded (got \(notes.count))")
            check(notes.contains { $0.isAbout && $0.text == "run the manual test" }, "about line parsed")
            check(notes.contains { $0.group == "errands" }, "list group parsed")
            check(notes.first { $0.isAbout }?.tty == "/dev/ttys005", "tty remembered for bring-back-the-tab")
            check((try? String(contentsOf: a, encoding: .utf8))?.range(of: #"captured: \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#,
                                                                       options: .regularExpression) != nil,
                  "captured time is written to the second")
            // simulate a Sublime edit that shifts lines: ticking must still hit the right todo
            let ask = notes.first { $0.text == "ask Dana" }!
            let body = try String(contentsOf: a, encoding: .utf8).replacingOccurrences(of: "---\n- [ ]", with: "---\n- [ ] added in sublime\n- [ ]")
            try body.write(to: a, atomically: true, encoding: .utf8)
            try NotesFS.complete(ask)
            let after = try String(contentsOf: a, encoding: .utf8)
            check(after.contains("- [x] ask Dana") && after.contains("- [ ] added in sublime"), "stale line index still ticks the right todo")
            notes = NotesFS.loadAll()
            if let c = notes.first(where: { $0.text == "check the table" }) { try NotesFS.edit(c, to: "check the table twice") }
            check(NotesFS.loadAll().contains { $0.text == "check the table twice" }, "editing a todo rewrites its line")
            notes = NotesFS.loadAll()
            for n in notes where n.group == "~/code/acme-api" { try NotesFS.complete(n) }
            notes = NotesFS.loadAll()
            check(notes.count == 1, "ticking everything moves that file to done/ (open left: \(notes.count))")
            let done = Config.notesDir.appendingPathComponent("done/code_acme-api").path
            check(((try? FileManager.default.contentsOfDirectory(atPath: done)) ?? []).count == 1, "file is in done/")
            if let u = notes.first { try NotesFS.remove(u) }
            check(NotesFS.loadAll().isEmpty, "removing the last todo moves its file to removed/")
            check(NotesFS.everUsed(), "after real use, demo todos don't come back")

            // Logbook: closed lines wherever their file ended up, with stamps
            var closed = NotesFS.loadClosed()
            check(closed.filter { $0.state == .done }.count == 4, "Logbook finds the 4 ticked lines in done/ (got \(closed.filter { $0.state == .done }.count))")
            check(closed.allSatisfy { $0.closedAt != nil }, "every line closed by titi carries a ✅/❌ stamp")
            check(closed.contains { $0.state == .removed && $0.text == "better indexes" }, "a removed line is listed as removed, not done")
            let doneText = (try? FileManager.default.contentsOfDirectory(atPath: done))?.first
                .flatMap { try? String(contentsOfFile: done + "/" + $0, encoding: .utf8) } ?? ""
            check(doneText.contains("- [x] ask Dana ✅ 20"), "the ticked line reads “- [x] ask Dana ✅ <date> <time>”")
            if let c = closed.first(where: { $0.text == "ask Dana" }), let o = try NotesFS.reopen(c) {
                check(o.file?.path.contains("/done/") == false && NotesFS.loadAll().contains { $0.text == "ask Dana" },
                      "reopening a line from done/ moves its file back and opens the line")
            } else {
                check(false, "reopen from done/")
            }
            closed = NotesFS.loadClosed()
            if let c = closed.first(where: { $0.text == "better indexes" }) { try NotesFS.reopen(c) }
            check(NotesFS.loadAll().contains { $0.text == "better indexes" }, "undoing a removal brings the line back from removed/")
            let sublime = Config.notesDir.appendingPathComponent("ticked elsewhere.md")
            try "- [x] ticked in sublime\n- [x] dated by hand ✅ 2026-10-24\n".write(to: sublime, atomically: true, encoding: .utf8)
            closed = NotesFS.loadClosed()
            check(closed.first { $0.text == "ticked in sublime" }?.closedAt == nil, "a line ticked in Sublime has no date (shown as date unknown)")
            check(closed.first { $0.text == "dated by hand" }?.closedAt != nil, "a date-only ✅ stamp still parses")

            // the report
            let day = workday()
            let md = Report.markdown(day: day, open: NotesFS.loadAll(), closed: closed, commits: [], focus: [])
            check(md.contains("## Done (3)") && md.contains("## Still open from today") && !md.contains("ticked in sublime"),
                  "report: 3 done today (one was reopened), today's open todos, undated ticks left out")
            let r1 = try Report.save(md, day: day)
            check(!NotesFS.loadAll().contains { $0.file?.path.contains("/reports/") == true }
                  && !NotesFS.loadClosed().contains { $0.file?.path.contains("/reports/") == true },
                  "a saved report's - [ ] lines never come back as todos")
            check(try Report.save(md, day: day) == r1, "regenerating overwrites the report we wrote")
            try (md + "\nmy own note\n").write(to: r1, atomically: true, encoding: .utf8)
            let r2 = try Report.save(md, day: day)
            check(r2 != r1 && r2.lastPathComponent.contains("(2)"), "a hand-edited report is kept; the new one goes next to it")

            // 04:00 day boundary
            let cal = Calendar.current
            let at = { (d: Int, h: Int) in cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: 30))! }
            check(workday(at(25, 2)) == cal.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 4))!,
                  "02:30 still counts for the previous workday")
            check(workday(at(25, 4)) == cal.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 4))!,
                  "04:30 starts a new workday (also on the day the clocks go back)")
            check(workdayEnd(workday(at(25, 12))) == cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 4))!,
                  "the workday ends at 04:00 the next morning")
            windowKeys(check)
            try movingNotes(check)
            migration(check)
            icons(check)
            commands(check)
            notesAtScale(check)
            thingsRowAge(check)
            try todoDetails(check)
            detailsKeys(check)
            detailsCaret(check)
            detailsOnScreen(check)
        } catch {
            check(false, "notes round-trip threw \(error)")
        }
        // forget the scratch reports, so the real app's bookkeeping only lists real ones
        let d = UserDefaults.standard
        if var w = d.dictionary(forKey: "reportDigests") {
            w = w.filter { !$0.key.contains("/titi-selftest-") && !$0.key.hasPrefix(Config.notesDir.path) }
            d.set(w, forKey: "reportDigests")
        }
        print(failures == 0 ? "selftest passed" : "selftest: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }

    /// Commands titi runs (ps, lsof, git, osascript, claude -p) can hang: none may hold up a scan or a button for
    /// good. Every case here is bounded even if `sh` regresses (the longest takes 5 s).
    static func commands(_ check: (Bool, String) -> Void) {
        func timed(_ f: () -> String) -> (String, TimeInterval) {
            let t0 = Date()
            let out = f()
            return (out, Date().timeIntervalSince(t0))
        }
        let (slept, t1) = timed { sh("/bin/sleep", ["5"], timeout: 0.5) }
        check(slept.isEmpty && t1 < 2.5, "a command still running after its timeout is stopped (\(String(format: "%.1f", t1))s)")
        let (big, _) = timed { sh("/bin/sh", ["-c", "head -c 300000 /dev/zero | tr '\\0' a"]) }
        check(big.count == 300_000, "output bigger than a pipe's buffer comes back whole (\(big.count) bytes)")
        let (flood, t2) = timed { sh("/bin/sh", ["-c", "head -c 3000000 /dev/zero"], maxBytes: 100_000) }
        check(flood.isEmpty && t2 < 2.5, "output past the cap is dropped, not kept (\(flood.count) bytes, \(String(format: "%.1f", t2))s)")
        let (hi, t3) = timed { sh("/bin/sh", ["-c", "sleep 3 & echo hi"]) }
        check(hi.trimmed == "hi" && t3 < 2, "a background child holding the output doesn't block (\(String(format: "%.1f", t3))s)")
        check(sh("/nonexistent/tool", []).isEmpty, "a missing command gives an empty answer")

        // a command run from the UI's run loop freezes titi until it returns, so sh() logs a warning there
        check(!blocksUI(), "plain main-thread code (--report, the self-test) doesn't count as blocking the UI")
        let fromBackground = Counter()
        let ran = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            if blocksUI() { fromBackground.add() }
            ran.signal()
        }
        ran.wait()
        check(fromBackground.value == 0, "…nor does a background thread")
        let fromRunLoop = Counter()
        DispatchQueue.main.async { if blocksUI() { fromRunLoop.add() } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(fromRunLoop.value == 1, "…but main-thread code called by the run loop does, so sh() warns there")

        // the front iTerm tab is looked up on every popover open: a slow lookup must not stack up behind itself
        let s = Store(persist: false)
        let calls = Counter()
        let slow: @Sendable () -> CaptureContext? = {
            calls.add()
            Thread.sleep(forTimeInterval: 0.3)
            return nil
        }
        s.detectContext(using: slow)
        s.detectContext(using: slow)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        s.detectContext(using: slow)
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        check(calls.value == 2, "one front-tab lookup at a time; the next starts once it is done (\(calls.value) ran)")
    }

    /// The to-do list view shows how old each todo is, in light grey like the app view's "12d".
    static func thingsRowAge(_ check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        let n = Note(id: "age-test", text: "water the plants", group: "General", filedUnder: "General", branch: nil,
                     created: Date().addingTimeInterval(-12 * 86400 - 600), isAbout: false, file: nil, line: nil)
        let host = NSHostingView(rootView: ThingsTodo(note: n).environmentObject(Store(persist: false))
            .frame(width: 600).background(Color.white))   // OCR needs it opaque
        host.appearance = NSAppearance(named: .aqua)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 60), styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        let shown = recognizedText(in: host)
        check(shown.contains("12d"), "a to-do list row shows its age in days (\(shown))")
    }

    /// Details are the indented lines under a todo. titi reads them, writes them two spaces in, keeps them with their
    /// line through done and reopen, erases them with it, and never overwrites a block another app changed.
    static func todoDetails(_ check: (Bool, String) -> Void) throws {
        let dir = Config.notesDir.appendingPathComponent("detailstest", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("2026-11-13 09-00 details.md")
        try ["---", "group: detailstest", "---",
             "- [ ] first", "  one", "", "  two",
             "- [ ] second", "\tthree", "",
             "- [x] closed one ✅ 2026-11-12 10:00", "  kept with it",
             "plain text at the edge",
             "- [ ] third", ""].joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        func open() -> [Note] { NotesFS.loadAll().filter { $0.group == "detailstest" } }
        func closed() -> [Note] { NotesFS.loadClosed().filter { $0.group == "detailstest" } }
        func disk(_ n: Note? = nil) -> String { (try? String(contentsOf: n?.file ?? url, encoding: .utf8)) ?? "" }

        var o = open()
        let first = o.first { $0.text == "first" }
        check(first?.details == "one\n\ntwo",
              "details: the indented lines under a todo, a blank line inside kept (\(first?.details.debugDescription ?? "nil"))")
        check(o.first { $0.text == "second" }?.details == "three", "a tab indents too, and a blank line after the block isn't part of it")
        check(o.first { $0.text == "third" }?.details == "", "a todo with nothing indented under it has no details")
        check(o.count == 3, "details lines are never read as todos (\(o.count) open)")
        check(closed().first { $0.text == "closed one" }?.details == "kept with it", "a Logbook line has its details too")

        guard let first else { return check(false, "details: the test file didn't load") }
        try NotesFS.edit(first, to: "first, renamed", details: "new one\n  indented\n- [ ] not a todo\n\n")
        check(disk().contains("- [ ] first, renamed\n  new one\n    indented\n  - [ ] not a todo\n- [ ] second\n"),
              "saving writes each detail line two spaces in, trailing blank lines dropped")
        o = open()
        check(o.count == 3 && o.first { $0.text == "first, renamed" }?.details == "new one\n  indented\n- [ ] not a todo",
              "the details read back as typed, and a “- [ ]” inside them stays text")
        if let r = o.first(where: { $0.text == "first, renamed" }) { try NotesFS.edit(r, to: r.text, details: "") }
        check(disk().contains("- [ ] first, renamed\n- [ ] second\n"), "emptying the details removes the block")
        if let s = open().first(where: { $0.text == "second" }) { try NotesFS.edit(s, to: "second, renamed") }
        check(disk().contains("- [ ] second, renamed\n\tthree\n"), "a title-only edit leaves the details as they are")
        if let s = open().first(where: { $0.text == "second, renamed" }) { try NotesFS.edit(s, to: "second,\nrenamed") }
        check(disk().contains("- [ ] second, renamed\n\tthree\n") && open().first { $0.text == "second, renamed" }?.details == "three",
              "a line break typed into a title becomes a space, so the details stay attached")

        // another app (Sublime) changed the block after titi read it: titi must not write over it
        let stale = open().first { $0.text == "second, renamed" }
        try disk().replacingOccurrences(of: "\tthree\n", with: "\tthree, edited in sublime\n").write(to: url, atomically: true, encoding: .utf8)
        var refused = false
        if let stale {
            do { try NotesFS.edit(stale, to: "second, renamed", details: "mine") } catch let e as NotesFS.DetailsChanged {
                refused = e.onDisk == "three, edited in sublime"
            }
        }
        check(refused && disk().contains("\tthree, edited in sublime\n") && !disk().contains("  mine"),
              "details another app changed meanwhile are never overwritten")

        for n in open() { try NotesFS.complete(n) }
        let ticked = closed().first { $0.text == "second, renamed" }
        check(ticked?.details == "three, edited in sublime" && ticked?.file?.path.contains("/done/") == true
              && disk(ticked).contains("- [x] second, renamed ✅ "),
              "ticking keeps the details under the line, and they move to done/ with the file")
        if let ticked, let back = try NotesFS.reopen(ticked) {
            check(back.details == "three, edited in sublime" && open().first { $0.text == "second, renamed" }?.details == "three, edited in sublime",
                  "reopening brings the details back with the line")
            try NotesFS.complete(back)
        } else {
            check(false, "reopen a line with details")
        }

        let gone = closed().first { $0.text == "closed one" }
        if let gone { try NotesFS.erase(gone) }
        let left = disk(closed().first)
        check(!left.contains("kept with it") && left.contains("- [x] closed one") == false
              && left.contains("plain text at the edge") && left.contains("\tthree, edited in sublime"),
              "deleting a Logbook line for good erases its details and nothing after them")
        check(ConfirmRemoveBox.explanation(for: [gone ?? first]).contains("details")
              && !ConfirmRemoveBox.explanation(for: closed().filter { $0.details.isEmpty }).contains("details"),
              "the delete-for-good box says the details go too, only when there are some")
        if let c = closed().first(where: { $0.text == "second, renamed" }), let f = c.file {
            try (try String(contentsOf: f, encoding: .utf8))
                .replacingOccurrences(of: "\tthree, edited in sublime\n", with: "\tthree, edited in sublime\n\tand a line added later\n")
                .write(to: f, atomically: true, encoding: .utf8)
            var refusedErase = false
            do { try NotesFS.erase(c) } catch is NotesFS.DetailsChanged { refusedErase = true }
            let after = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            check(refusedErase && after.contains("- [x] second, renamed") && after.contains("and a line added later"),
                  "delete for good refuses a line whose details changed since titi read them")
        }
        try NotesFS.write(group: "flattest", filedUnder: "flattest", branch: nil, capturedIn: "test", focus: nil, about: nil,
                          items: ["one\ntwo"])
        let flat = NotesFS.loadAll().filter { $0.group == "flattest" }.map(\.text)
        check(flat == ["one two"], "a new todo with a line break in it is saved as one line (\(flat))")

        var secret = first
        secret.state = .done
        secret.closedAt = Date()
        secret.details = "private detail"
        let md = Report.markdown(day: workday(), open: [], closed: [secret], commits: [], focus: [])
        check(md.contains(first.text) && !md.contains("private detail"), "the report lists titles only, never details")
    }

    /// The editor: ↩ edits the title, Tab or ↓ goes to Details, ↑ on its first line or ⇧Tab goes back, ↩ in Details
    /// is a new line, and ⌘↩ or esc saves both. The Logbook shows details read-only. Search finds text in details.
    static func detailsKeys(_ check: (Bool, String) -> Void) {
        func key(_ code: UInt16, _ chars: String = "", _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                             keyCode: code)!
        }
        let ret = key(36, "\r"), tab = key(48, "\t"), backTab = key(48, "\t", .shift), down = key(125), up = key(126),
            esc = key(53), cmdRet = key(36, "\r", .command)
        guard let url = try? NotesFS.write(group: "detailskeys", filedUnder: "detailskeys", branch: nil, capturedIn: "test",
                                           focus: nil, about: nil, items: ["pack for the trip", "call the vet"]) else {
            return check(false, "details keys: could not write the test note")
        }
        let s = Store(persist: false)
        s.reloadNotes()
        func note() -> Note? { s.notes.first { NotesFS.samePath($0.file, url) && $0.text == "pack for the trip" } }
        func onDisk() -> String { note().flatMap { n in n.file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } } ?? "" }
        guard let n = note() else { return check(false, "details keys: the test note didn't load") }
        s.select("*all")
        s.pane = .list
        s.cursor = "t:" + n.id

        _ = s.handleAppKey(ret, textEditing: false)
        check(s.editingID == n.id && s.editFocus == .title, "↩ edits the title first")
        _ = s.handleAppKey(tab, textEditing: true)
        check(s.editFocus == .details, "Tab in the title goes to Details")
        _ = s.handleAppKey(backTab, textEditing: true)
        check(s.editFocus == .title, "⇧Tab goes back to the title")
        _ = s.handleAppKey(down, textEditing: true)
        check(s.editFocus == .details, "↓ in the title goes to Details")
        s.caretOnFirstLine = false
        let inside = s.handleAppKey(up, textEditing: true)
        check(!inside && s.editFocus == .details, "↑ below Details' first line just moves the caret")
        s.caretOnFirstLine = true
        _ = s.handleAppKey(up, textEditing: true)
        check(s.editFocus == .title, "↑ on Details' first line goes back to the title")
        _ = s.handleAppKey(tab, textEditing: true)
        let newline = s.handleAppKey(ret, textEditing: true)
        check(!newline && s.editingID == n.id, "↩ in Details is left to the editor: a new line, not save")
        s.editDetails = "passport\nchargers"
        _ = s.handleAppKey(esc, textEditing: true)
        check(s.editingID == nil && note()?.details == "passport\nchargers" && onDisk().contains("- [ ] pack for the trip\n  passport\n  chargers"),
              "esc closes the editor and keeps what you typed")

        s.cursor = "t:" + (note()?.id ?? "")
        _ = s.handleAppKey(ret, textEditing: false)
        check(s.editDetails == "passport\nchargers", "editing again starts from the saved details")
        s.editDetails = "passport\nchargers\numbrella"
        _ = s.handleAppKey(cmdRet, textEditing: true)
        check(s.editingID == nil && note()?.details == "passport\nchargers\numbrella", "⌘↩ saves and closes")

        // the file changes in Sublime while the editor is open: keep what you typed, write nothing, say so
        if let m = note() { s.beginEdit(m) }
        let sublime = onDisk().replacingOccurrences(of: "  umbrella", with: "  umbrella, the big one")
        if let f = note()?.file { try? sublime.write(to: f, atomically: true, encoding: .utf8) }
        s.editDetails = "only mine"
        s.commitEdit()
        let both = "passport\nchargers\numbrella, the big one\n\nonly mine"
        check(s.editingID != nil && s.editDetails == both && onDisk().contains("umbrella, the big one")
              && !onDisk().contains("only mine") && (s.toast ?? "").contains("changed"),
              "details changed on disk while editing: nothing is written, and the editor shows the file's version above yours")
        s.commitEdit()
        check(s.editingID == nil && note()?.details == both, "saving then keeps what the editor shows")

        s.pane = .search
        s.appQuery = "only mine"
        check(s.listRows().contains { if case .task(let t) = $0 { return t.text == "pack for the trip" }; return false },
              "the app's search finds text in details")
        s.appQuery = ""

        // every other way out of the editor saves what you typed too
        s.select("*all")
        if let m = note() { s.beginEdit(m) }
        s.editDetails = "typed, then ticked"
        if let m = note() { s.complete(m) }
        check(s.editingID == nil && s.closed.first { $0.text == "pack for the trip" }?.details == "typed, then ticked",
              "ticking the todo you're editing saves its details first")
        if let c = s.closed.first(where: { $0.text == "pack for the trip" }) { s.reopen(c) }
        if let m = note() { s.beginEdit(m) }
        s.editDetails = "half typed"
        if let m = note() { s.beginEdit(m) }
        check(s.editDetails == "half typed", "opening the editor that's already open keeps what you typed")
        s.select("General")
        check(s.editingID == nil && note()?.details == "half typed", "switching lists saves the editor")
        s.select("*all")
        if let m = note() { s.beginEdit(m) }
        s.editDetails = "before the window closed"
        s.closeEditor()
        check(s.editingID == nil && note()?.details == "before the window closed",
              "closing the window (or freezing the report) saves the editor")
        if let m = note() { s.beginEdit(m) }
        s.editDetails = "first editor"
        if let other = s.notes.first(where: { $0.text == "call the vet" }) { s.beginEdit(other) }   // its line moved down
        check(note()?.details == "first editor" && s.editingID == s.notes.first { $0.text == "call the vet" }?.id,
              "opening another todo's editor saves the first one, and the second opens on its line as it is now")
        s.closeEditor()

        if let m = note() { s.beginEdit(m) }
        s.editDetails = "saved by cmd-s"
        let cmdS = s.handleAppKey(key(1, "s", .command), textEditing: true)
        check(cmdS && s.editingID == nil && s.report == nil && note()?.details == "saved by cmd-s",
              "⌘S in the editor saves the editor, and only that")
        if let m = note() { s.beginEdit(m) }
        s.editDetails = "saved by cmd-n"
        s.startAdd()
        check(s.editingID == nil && s.adding != nil && note()?.details == "saved by cmd-n", "⌘N saves the editor before the new-todo row opens")
        _ = s.handleAppKey(esc, textEditing: true)

        s.select("*all")
        s.pane = .list
        let vetBefore = s.notes.first { $0.text == "call the vet" }
        if let m = note() { s.beginEdit(m) }
        s.editDetails = "saved by cmd-n\nplus\nthree more\nlines"
        if let v = vetBefore { s.click("t:" + v.id, []) }
        let vetAfter = s.notes.first { $0.text == "call the vet" }
        check(s.editingID == nil && vetAfter != nil && vetAfter?.id != vetBefore?.id && s.cursor == "t:" + (vetAfter?.id ?? ""),
              "clicking another row saves the editor and picks that row, even though its line moved")

        func editInSublime(_ from: String, _ to: String) {
            if let f = note()?.file { try? onDisk().replacingOccurrences(of: from, with: to).write(to: f, atomically: true, encoding: .utf8) }
        }
        if let m = note() { s.beginEdit(m) }
        s.editDetails = "mine, clicked away"
        editInSublime("  lines\n", "  lines, from sublime\n")
        if let v = s.notes.first(where: { $0.text == "call the vet" }) { s.click("t:" + v.id, []) }
        check(s.editingID != nil && s.editDetails.contains("lines, from sublime") && s.editDetails.hasSuffix("mine, clicked away")
              && !onDisk().contains("clicked away"),
              "a click elsewhere when the file's details changed keeps the editor open, both versions in it, nothing written")
        s.select("General")
        check(s.editingID == nil && onDisk().contains("  lines, from sublime\n") && onDisk().contains("  mine, clicked away"),
              "leaving anyway (another list, the window, quitting) saves both versions")
        check((s.toast ?? "").contains("both"), "…and says so (\(s.toast ?? "no toast"))")
        if let m = note() { s.beginEdit(m) }
        s.editDetails = "typed before quitting"
        editInSublime("  mine, clicked away\n", "  sublime again\n")
        s.closeEditor()
        check(s.editingID == nil && onDisk().contains("  sublime again\n") && onDisk().contains("  typed before quitting"),
              "a conflict found on the way out keeps both versions too")
        s.select("*all")

        if let m = note() { s.complete(m) }
        s.select("*logbook")
        s.pane = .list
        let row = s.listRows().first { if case .closed(let c) = $0 { return c.text == "pack for the trip" }; return false }
        s.cursor = row?.id
        _ = s.handleAppKey(ret, textEditing: false)
        let shown = s.shownDetailsID
        check(shown != nil && shown == s.closed.first { $0.text == "pack for the trip" }?.id && s.editingID == nil,
              "↩ on a Logbook line shows its details, read-only")
        _ = s.handleAppKey(ret, textEditing: false)
        check(s.shownDetailsID == nil, "↩ again hides them")
        _ = s.handleAppKey(ret, textEditing: false)
        _ = s.handleAppKey(down, textEditing: false)
        check(s.shownDetailsID == nil, "moving to another line hides them")

        // opening and closing the editor without a change writes nothing, even for details titi would write tidier
        let blanky = Config.notesDir.appendingPathComponent("detailskeys/blank first.md")
        let text = "---\ngroup: detailskeys\n---\n- [ ] blank line first\n\n  then the details\n"
        try? text.write(to: blanky, atomically: true, encoding: .utf8)
        s.reloadNotes()
        if let b = s.notes.first(where: { $0.text == "blank line first" }) {
            s.beginEdit(b)
            _ = s.handleAppKey(esc, textEditing: true)
        }
        check((try? String(contentsOf: blanky, encoding: .utf8)) == text, "esc with nothing changed leaves the file alone")

        func vet() -> Note? { s.notes.first { NotesFS.samePath($0.file, url) && $0.text == "call the vet" } }
        func rewrite(_ change: (inout [String]) -> Void) {
            var ls = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
            change(&ls)
            try? ls.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        s.select("*all")
        if let v = vet() { s.beginEdit(v) }
        s.editDetails = "followed"
        rewrite { $0.insert("- [ ] added above in sublime", at: $0.firstIndex { $0.hasPrefix("- [") } ?? $0.count) }
        s.reloadNotes()
        check(s.editingID != nil && s.editingID == vet()?.id, "a reload that moves the edited todo's line keeps the editor on it")
        s.closeEditor()
        check(vet()?.details == "followed", "…and the save lands under it")
        // the common Sublime edit: a todo added right above, so the todo above takes the edited one's old id
        guard let pair = try? NotesFS.write(group: "detailskeys", filedUnder: "detailskeys", branch: nil, capturedIn: "test",
                                            focus: nil, about: nil, items: ["first of a pair", "second of a pair"]) else {
            return check(false, "details keys: could not write the pair")
        }
        s.reloadNotes()
        func second() -> Note? { s.notes.first { NotesFS.samePath($0.file, pair) && $0.text == "second of a pair" } }
        if let n2 = second() { s.beginEdit(n2) }
        s.editDetails = "stays on the second"
        var pairLines = ((try? String(contentsOf: pair, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        pairLines.insert("- [ ] new on top", at: pairLines.firstIndex(of: "- [ ] first of a pair") ?? 0)
        try? pairLines.joined(separator: "\n").write(to: pair, atomically: true, encoding: .utf8)
        s.reloadNotes()
        check(s.editingID == second()?.id, "a todo added right above the edited one: the editor stays on the edited one")
        s.closeEditor()
        check(second()?.details == "stays on the second", "…and saves into it")

        if let v = vet() { s.beginEdit(v) }
        s.editDetails = "typed for a line that's gone"
        let doomed = vet()
        rewrite { ls in
            guard let i = ls.firstIndex(of: "- [ ] call the vet") else { return }
            ls.removeSubrange(i..<NotesFS.detailsEnd(ls, after: i))
            ls.insert("- [ ] took its place", at: i)
        }
        if let d = doomed { s.complete(d) }
        check(s.editingID == nil && s.notes.contains { $0.text == "took its place" } && !s.closed.contains { $0.text == "took its place" },
              "ticking a todo whose line was deleted meanwhile ticks nothing else")
    }

    /// The Details box: ↑ leaves it only from its first line as drawn, and typing stays as typed (no smart quotes).
    static func detailsCaret(_ check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 300))
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 300), styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.contentView = tv
        tv.string = "a first paragraph long enough to wrap onto several lines\nsecond"
        if let lm = tv.layoutManager, let tc = tv.textContainer { lm.ensureLayout(for: tc) }
        func at(_ i: Int) -> Bool {
            tv.setSelectedRange(NSRange(location: i, length: 0))
            return tv.caretOnFirstLine
        }
        check(at(0) && at(4), "↑ leaves Details from its first line")
        check(!at(45), "…but on the second line of a wrapped first paragraph it just moves up")
        check(!at((tv.string as NSString).length), "…and from the last line too")
        tv.plainTyping()
        check(!tv.isAutomaticQuoteSubstitutionEnabled && !tv.isAutomaticDashSubstitutionEnabled && !tv.isAutomaticTextReplacementEnabled,
              "the editors keep -- and \" as typed (details hold commands)")
        check(!tv.isAutomaticSpellingCorrectionEnabled, "…and never autocorrect a word (a command name isn't a typo)")
    }

    /// What the rows draw: the editor with its Details box, and a Logbook line's details read-only, in both views.
    static func detailsOnScreen(_ check: (Bool, String) -> Void) {
        _ = NSApplication.shared
        func drawn<V: View>(_ v: V, _ s: Store, height: CGFloat = 120) -> String {
            let host = NSHostingView(rootView: v.environmentObject(s).frame(width: 640).background(Color.white))
            host.appearance = NSAppearance(named: .aqua)
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: height), styleMask: [.borderless],
                               backing: .buffered, defer: false)
            win.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            return recognizedText(in: host)
        }
        var n = Note(id: "details-ocr", text: "pack for the trip", group: "General", filedUnder: "General", branch: nil,
                     created: Date().addingTimeInterval(-3 * 86400), isAbout: false, file: nil, line: nil)
        n.details = "passport and chargers"
        let s = Store(persist: false)
        s.beginEdit(n)
        let things = drawn(ThingsTodo(note: n), s)
        check(things.contains("passport and chargers"), "the to-do list's editor shows the details under the title (\(things))")
        let app = drawn(TodoRow(note: n), s)
        check(app.contains("passport and chargers"), "the app view's editor shows them too (\(app))")
        s.editingID = nil

        var c = n
        c.id = "details-ocr-closed"
        c.state = .done
        c.closedAt = Date()
        s.shownDetailsID = c.id
        let log = drawn(ThingsTodo(note: c), s)
        check(log.contains("passport and chargers"), "a Logbook line in the to-do list shows its details read-only (\(log))")
        let appLog = drawn(ClosedRow(note: c), s)
        check(appLog.contains("passport and chargers"), "…and in the app view (\(appLog))")
        s.shownDetailsID = nil
        let folded = drawn(ThingsTodo(note: c), s)
        check(!folded.contains("passport"), "folded, a row shows only its title (\(folded))")
    }

    /// The text OCR reads in a view drawn offscreen, lowercased, pieces joined with " | ".
    static func recognizedText(in view: NSView) -> String {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return "" }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let cg = rep.cgImage else { return "" }
        let req = VNRecognizeTextRequest()
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ").lowercased()
    }

    /// Every popover open rereads the notes on the main thread, and done/ and removed/ only grow: a reload must cost
    /// about what changed, not the whole history. Runs last, in a folder of its own inside the scratch notes.
    static func notesAtScale(_ check: (Bool, String) -> Void) {
        let fm = FileManager.default
        let dir = Config.notesDir.appendingPathComponent("done/scale", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        func note(_ text: String) -> String { "---\ngroup: scale\n---\n- [x] \(text) ✅ 2026-10-01 10:00\n" }
        for i in 0..<2000 { try? note("old \(i)").write(to: dir.appendingPathComponent("n\(i).md"), atomically: false, encoding: .utf8) }
        func seconds(_ f: () -> Void) -> TimeInterval {
            let t0 = Date()
            f()
            return Date().timeIntervalSince(t0)
        }
        let first = seconds { _ = NotesFS.loadClosed() }
        let again = seconds { _ = NotesFS.loadClosed() }
        check(again < first / 4, String(format: "rereading 2,000 unchanged notes costs under a quarter of the first read (%.0f → %.0f ms)",
                                         first * 1000, again * 1000))
        try? note("new 7").write(to: dir.appendingPathComponent("n7.md"), atomically: true, encoding: .utf8)
        let closed = NotesFS.loadClosed()
        check(closed.contains { $0.text == "new 7" } && !closed.contains { $0.text == "old 7" },
              "a note edited since the last read is read again")
    }

    /// Counts calls from any thread.
    final class Counter: @unchecked Sendable {   // `lock` guards `n`
        private let lock = NSLock()
        private var n = 0
        func add() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Design 1c: the menu-bar glyph and the app icon's PNGs (drawn into a scratch folder).
    static func icons(_ check: (Bool, String) -> Void) {
        let glyph = TitiIcon.menuBar()
        check(glyph.isTemplate && glyph.size == NSSize(width: 18, height: 18), "the menu-bar glyph is an 18 pt template image")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("titi-selftest-icon-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try TitiIcon.writeIconset(to: dir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
            let sizes = names.compactMap { n -> Int? in
                guard let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(n) as CFURL, nil),
                      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
                return img.width
            }
            check(names.count == 10 && Set(sizes) == [16, 32, 64, 128, 256, 512, 1024], "the iconset has all 10 sizes (\(sizes))")
        } catch {
            check(false, "the iconset could not be drawn: \(error)")
        }
        // pixels of the 1024 master: transparent corner, green tile, cream ring, green gap, cream dot
        guard let img = TitiIcon.appIcon(pixels: 1024, points: 512), let data = img.dataProvider?.data,
              let p = CFDataGetBytePtr(data) else { return check(false, "the app icon could not be drawn") }
        func px(_ x: Int, _ y: Int) -> [UInt8] { let o = y * img.bytesPerRow + x * 4; return [p[o], p[o + 1], p[o + 2], p[o + 3]] }
        check(px(20, 20)[3] == 0 && px(150, 512) == [0x2f, 0x5d, 0x50, 255] && px(512 + 236, 512) == [0xf3, 0xf1, 0xec, 255]
              && px(512 + 160, 512) == [0x2f, 0x5d, 0x50, 255] && px(512, 512) == [0xf3, 0xf1, 0xec, 255],
              "the app icon is the cream ring and dot on the green tile, transparent outside it")
    }

    /// The rename from clomodoro: old settings come over once, without overwriting. One throwaway domain only.
    static func migration(_ check: (Bool, String) -> Void) {
        let dst = "titi-selftest-migrate"
        defer {   // the scratch domain and its file go, so nothing is left in ~/Library/Preferences
            UserDefaults.standard.removePersistentDomain(forName: dst)
            try? FileManager.default.removeItem(atPath: Config.home + "/Library/Preferences/\(dst).plist")
        }
        guard let d = UserDefaults(suiteName: dst) else { return check(false, "migration: no scratch defaults") }
        // keys of its own, so whatever the app's real settings hold can't mask a bug
        let old: [String: Any] = ["selftest.lists": ["errands", "reading"], "selftest.mode": "things", "selftest.view": "*logbook"]
        d.set("*all", forKey: "selftest.view")
        Migration.settings(into: d, from: old)
        check(d.stringArray(forKey: "selftest.lists") == ["errands", "reading"] && d.string(forKey: "selftest.mode") == "things",
              "your lists and settings come over from clomodoro")
        check(d.string(forKey: "selftest.view") == "*all", "…without overwriting one already set in titi")
        Migration.settings(into: d, from: ["selftest.lists": ["changed later"]])
        check(d.stringArray(forKey: "selftest.lists") == ["errands", "reading"], "…and only once")
    }

    /// Settings → Notes folder, between two fresh scratch folders only.
    static func movingNotes(_ check: (Bool, String) -> Void) throws {
        let fm = FileManager.default
        let old = fm.temporaryDirectory.appendingPathComponent("titi-selftest-move-a-" + UUID().uuidString, isDirectory: true)
        let new = fm.temporaryDirectory.appendingPathComponent("titi-selftest-move-b-" + UUID().uuidString, isDirectory: true)
        let real = URL(fileURLWithPath: Config.defaultNotesDir).resolvingSymlinksInPath().path
        guard ![old, new].contains(where: { $0.resolvingSymlinksInPath().path.hasPrefix(real) }) else {
            return check(false, "moving notes: refusing to test near the real notes folder")
        }
        defer { for d in [old, new] { try? fm.removeItem(at: d) } }   // the two scratch folders made here
        func put(_ dir: URL, _ rel: String, _ text: String) throws {
            let u = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: u, atomically: true, encoding: .utf8)
        }
        func text(_ dir: URL, _ rel: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(rel), encoding: .utf8) }
        try put(old, "a.md", "- [ ] old a\n")
        try put(old, "code_X/b.md", "- [ ] old b\n")
        try put(old, "done/c.md", "- [x] old c\n")
        try put(old, "reports/2026-10-25.md", "# report\n")
        try put(old, ".git/HEAD", "ref\n")
        try put(new, "a.md", "- [ ] already there\n")
        try put(new, "done/d.md", "- [x] already done\n")

        check(NotesFS.problem(movingFrom: old, to: old) != nil, "Settings refuses the same folder")
        check(NotesFS.problem(movingFrom: old, to: old.appendingPathComponent("sub")) != nil, "…a folder inside it")
        check(NotesFS.problem(movingFrom: old, to: old.deletingLastPathComponent()) != nil, "…a folder around it")
        check(NotesFS.problem(movingFrom: old, to: URL(fileURLWithPath: Config.home)) != nil, "…and the home folder")
        check(NotesFS.problem(movingFrom: old, to: new) == nil, "a folder of its own is fine")

        let s = Store(persist: false)
        let setting = UserDefaults.standard.string(forKey: "notesDir")
        let done = new.appendingPathComponent("done").path
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: done)   // can't write into done/: the move fails
        let failed = (try? s.moveNotes(from: old, to: new)) == nil
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: done)
        check(failed && text(old, "a.md") == "- [ ] old a\n" && text(new, "a (2).md") == nil,
              "all or nothing: when one move fails, the notes already moved go back")

        let count = try s.moveNotes(from: old, to: new)
        check(count == 4, "moving counts the 4 notes (\(count))")
        check(text(new, "a.md") == "- [ ] already there\n" && text(new, "a (2).md") == "- [ ] old a\n",
              "a note whose name is taken arrives as “(2)”; the one already there is untouched")
        check(text(new, "code_X/b.md") != nil && text(new, "reports/2026-10-25.md") != nil, "project folders and reports/ move")
        check(text(new, "done/c.md") != nil && text(new, "done/d.md") != nil, "done/ merges file by file")
        let left = (try? fm.contentsOfDirectory(atPath: old.path)) ?? []
        check(left == [".git"] && text(new, ".git/HEAD") == nil, "hidden .git stays behind; the old folder stays, emptied (\(left))")
        check(UserDefaults.standard.string(forKey: "notesDir") == setting, "the self-test never saves the folder setting")

        // the app's own reports keep counting as its own after a move (scratch keys; cleaned up at the end)
        let d = UserDefaults.standard
        var w = d.dictionary(forKey: "reportDigests") as? [String: String] ?? [:]
        w[old.appendingPathComponent("reports/2026-10-25.md").path] = "digest-x"
        d.set(w, forKey: "reportDigests")
        Report.reportsMoved(from: old, [(rel: "reports", to: new.appendingPathComponent("reports"))])
        let after = d.dictionary(forKey: "reportDigests") as? [String: String] ?? [:]
        check(after[new.appendingPathComponent("reports/2026-10-25.md").path] == "digest-x"
              && after[old.appendingPathComponent("reports/2026-10-25.md").path] == nil,
              "a moved report keeps its digest, so freezing again still overwrites it")
    }

    /// The app window's keyboard, driven with synthetic key events (no window needed).
    static func windowKeys(_ check: (Bool, String) -> Void) {
        func key(_ code: UInt16, _ chars: String = "", _ mods: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0,
                             context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false,
                             keyCode: code)!
        }
        let tab = key(48, "\t"), down = key(125), left = key(123), ret = key(36, "\r"), back = key(51, "\u{7f}")
        let s = Store(persist: false)
        s.reloadNotes()
        let folder = "~/code/acme-api"

        _ = s.handleAppKey(tab, textEditing: true)
        check(s.pane == .sidebar, "Tab: search → sidebar")
        _ = s.handleAppKey(tab, textEditing: false)
        check(s.pane == .list && s.cursor != nil, "Tab: sidebar → list, cursor on the first row")
        _ = s.handleAppKey(key(48, "\t", .shift), textEditing: false)
        check(s.pane == .sidebar, "⇧Tab goes back to the sidebar")
        _ = s.handleAppKey(down, textEditing: false)
        check(Array(s.sidebarKeys().prefix(3)) == ["*all", "*logbook", "*focus"],
              "the app's sidebar starts TODOs, Logbook, Focus (no Active, Where you were or Today)")
        check(s.appSelection == "*logbook", "↓ in the sidebar picks the next view")
        _ = s.handleAppKey(key(3, "f"), textEditing: false)
        check(s.pane == .search && s.appQuery == "f", "typing a letter in the sidebar starts a search")
        s.appQuery = ""

        s.select(folder)
        s.pane = .list
        s.cursor = nil
        _ = s.handleAppKey(back, textEditing: false)
        check(s.confirmRemove.isEmpty, "⌫ with no row picked does nothing")
        s.startAdd()
        check(s.adding == folder && s.pane == .list, "⌘N opens a new-todo row for the selected folder")
        s.addText = "made with cmd-n"
        s.saveAdd()
        let made = s.notes.first { $0.text == "made with cmd-n" }
        check(made?.group == folder && s.adding == folder, "↩ files it in that folder and keeps the row open")
        _ = s.handleAppKey(key(53), textEditing: true)
        check(s.adding == nil, "esc closes the new-todo row")

        s.cursor = "t:" + (made?.id ?? "")
        _ = s.handleAppKey(back, textEditing: false)
        check(s.confirmRemove.map(\.text) == ["made with cmd-n"], "⌫ on the picked todo asks first")
        _ = s.handleAppKey(key(12, "q"), textEditing: false)
        check(!s.confirmRemove.isEmpty, "the confirmation box swallows other keys")
        _ = s.handleAppKey(ret, textEditing: false)
        check(s.confirmRemove.isEmpty && !s.notes.contains { $0.text == "made with cmd-n" }, "↩ confirms: the todo is removed")
        _ = s.handleAppKey(key(6, "z", .command), textEditing: false)
        let back1 = s.notes.first { $0.text == "made with cmd-n" }
        check(back1 != nil, "⌘Z brings it back")

        s.cursor = "t:" + (back1?.id ?? "")
        _ = s.handleAppKey(key(40, "k", .command), textEditing: false)
        check(s.closed.contains { $0.text == "made with cmd-n" && $0.state == .done }, "⌘K ticks it")
        check(s.doneToday >= 1, "it counts as done today")
        _ = s.handleAppKey(key(20, "3", .command), textEditing: false)
        check(s.appSelection == "*focus", "⌘3 opens Focus")
        _ = s.handleAppKey(key(19, "2", .command), textEditing: false)
        check(s.appSelection == "*logbook", "⌘2 opens the Logbook")
        s.cursor = s.listRows().first { if case .closed(let n) = $0 { return n.text == "made with cmd-n" }; return false }?.id
        _ = s.handleAppKey(key(49, " "), textEditing: false)
        check(s.notes.contains { $0.text == "made with cmd-n" }, "Space on a Logbook line reopens it")

        s.select("*all")
        s.pane = .search
        s.appQuery = "made with"
        _ = s.handleAppKey(ret, textEditing: true)
        check(s.pane == .list && s.notes.filter { $0.text.hasPrefix("made with") }.count == 1,
              "↩ in search with matches steps into them instead of creating a duplicate")
        s.pane = .search
        s.appQuery = "brand new from search"
        _ = s.handleAppKey(ret, textEditing: true)
        check(s.notes.first { $0.text == "brand new from search" }?.group == "General" && s.appSelection == "General",
              "↩ with no match creates it (in General from TODOs)")
        s.select(folder)
        s.pane = .search
        s.appQuery = "another one for the folder"
        _ = s.handleAppKey(ret, textEditing: true)
        check(s.notes.first { $0.text == "another one for the folder" }?.group == folder,
              "…and in the selected folder when one is selected")

        s.pane = .list
        _ = s.handleAppKey(left, textEditing: false)
        check(s.pane == .sidebar, "← in a folder's list goes back to the sidebar")
        s.select("*all")
        s.pane = .list
        s.cursorToFirst()
        _ = s.handleAppKey(left, textEditing: false)
        check(s.pane == .sidebar, "← in TODOs goes straight back to the sidebar")
        s.pane = .search
        let swallowed = s.handleAppKey(key(6, "z", .command), textEditing: true)
        check(!swallowed, "⌘Z while typing in search is left to the text field")

        s.pane = .list
        let letter = s.handleAppKey(key(3, "f"), textEditing: true)
        let enter = s.handleAppKey(ret, textEditing: true)
        check(!letter && !enter && s.pane == .list && s.appQuery.isEmpty,
              "keys typed into another text field (the Focus goal) are left alone")

        s.select("*all")
        s.pane = .list
        s.cursorToFirst()
        let doneBefore = s.closed.count
        s.report = "# report"
        let space = s.handleAppKey(key(49, " "), textEditing: false)
        let cmdK = s.handleAppKey(key(40, "k", .command), textEditing: false)
        let copy = s.handleAppKey(key(8, "c", .command), textEditing: false)
        check(space && cmdK && !copy && s.closed.count == doneBefore,
              "while the report is up, Space and ⌘K are swallowed and ⌘C still copies")
        _ = s.handleAppKey(key(53), textEditing: false)
        check(s.report == nil, "esc closes the report")

        // ⌘O's second step: the same window as a Things-style to-do list
        s.select(folder)
        s.enterThings()
        check(s.windowMode == .things && s.appSelection == folder && s.pane == .list,
              "the Things view opens on the folder selected in the app")
        check(Array(s.sidebarKeys().prefix(2)) == ["*all", "*logbook"], "its sidebar starts TODOs, Logbook")
        _ = s.handleAppKey(tab, textEditing: false)
        let side = s.pane
        _ = s.handleAppKey(tab, textEditing: false)
        check(side == .sidebar && s.pane == .list, "Tab only moves between the sidebar and the list (no search bar)")
        let typed = s.handleAppKey(key(3, "f"), textEditing: false)
        check(!typed && s.appQuery.isEmpty, "typing a letter there doesn't start a search")
        _ = s.handleAppKey(key(18, "1", .command), textEditing: false)
        let todos = s.listRows().compactMap { if case .task(let n) = $0 { return n }; return nil }
        check(s.appSelection == "*all" && todos.count == s.notes.count
              && zip(todos, todos.dropFirst()).allSatisfy { $0.created >= $1.created } && Set(todos.map(\.group)).count > 1,
              "⌘1 is TODOs: every open todo from every folder, newest first")
        s.startAdd()
        check(s.adding == "General" && s.appSelection == "*all", "⌘N in TODOs files into General and stays in TODOs")
        _ = s.handleAppKey(key(53), textEditing: true)
        _ = s.handleAppKey(key(19, "2", .command), textEditing: false)
        check(s.appSelection == "*logbook", "⌘2 is the Logbook")
        s.windowMode = .app
        s.select("*focus")
        s.enterThings()
        check(s.appSelection == "*all", "from Focus, the Things view opens on TODOs")

        // tray → window: land where the popover's cursor was
        s.windowMode = .app
        let picked = s.notes.first { $0.group == folder }!
        s.enterFromTray(cursor: "t:" + picked.id)
        check(s.appSelection == "*all" && s.cursor == "t:" + picked.id && s.pane == .list,
              "a todo picked in the tray stays picked in TODOs")
        s.enterFromTray(cursor: "g:" + folder)
        check(s.appSelection == folder && s.pane == .list, "a folder picked in the tray opens that folder")
        s.enterFromTray(cursor: "s:/dev/no-such-tty")
        check(s.appSelection == "*all", "an unknown session lands on TODOs")
        s.tab = .focus
        s.enterFromTray(cursor: nil)
        check(s.appSelection == "*focus", "from the tray's Focus tab with nothing picked: Focus")
        s.tab = .active

        // window → tray: the cursor lands on a row the popover shows
        s.select("*all")
        s.expanded.remove(folder)
        s.cursor = "t:" + picked.id
        s.cursorForTray()
        check(s.cursor == "t:" + picked.id && s.rows().contains { $0.id == s.cursor },
              "back in the tray, the todo picked in TODOs is shown (its folder opens)")
        s.cursor = "c:no-such-line"
        s.cursorForTray()
        check(s.cursor == nil, "a Logbook line has no row in the tray, so the cursor goes")

        // Page Up / Page Down / Home / End
        for i in 0..<30 { _ = s.createTodo("page filler \(i)", in: "General") }
        s.select("*all")
        s.pane = .list
        s.pageHeight = 600
        s.cursorToFirst()
        let nav = s.listRows().filter(\.navigable).map(\.id)
        _ = s.handleAppKey(key(121), textEditing: false)
        let afterPage = nav.firstIndex(of: s.cursor ?? "") ?? -1
        check(afterPage > 5, "Page Down jumps a screenful down the list (row \(afterPage))")
        _ = s.handleAppKey(key(116), textEditing: false)
        check(s.cursor == nav.first, "Page Up jumps back")
        _ = s.handleAppKey(key(119), textEditing: false)
        check(s.cursor == nav.last, "End goes to the last todo")
        _ = s.handleAppKey(key(115), textEditing: false)
        check(s.cursor == nav.first, "Home goes to the first")
        s.pane = .sidebar
        _ = s.handleAppKey(key(119), textEditing: false)
        check(s.appSelection == s.sidebarKeys().last, "End in the sidebar goes to the last folder or list")
        _ = s.handleAppKey(key(116), textEditing: false)
        check(s.appSelection != s.sidebarKeys().last, "Page Up in the sidebar moves up")

        // multi-selection: ⇧↓ extends, ⌘/⌃-click picks single rows, one ⌘Z undoes it all
        s.select("*all")
        s.pane = .list
        s.cursorToFirst()
        let all = s.listRows().filter(\.navigable).map(\.id)
        _ = s.handleAppKey(key(125, "", .shift), textEditing: false)
        _ = s.handleAppKey(key(125, "", .shift), textEditing: false)
        check(s.selection == Set(all.prefix(3)), "⇧↓ twice selects three todos")
        let openBefore = s.notes.count
        _ = s.handleAppKey(key(40, "k", .command), textEditing: false)
        check(s.notes.count == openBefore - 3 && s.selection.isEmpty, "⌘K ticks all three")
        _ = s.handleAppKey(key(6, "z", .command), textEditing: false)
        check(s.notes.count == openBefore, "one ⌘Z brings all three back")
        let r = s.listRows().filter(\.navigable).map(\.id)
        s.click(r[0], [])
        s.click(r[2], .command)
        s.click(r[4], .control)
        check(s.selection == [r[0], r[2], r[4]], "⌘-click and ⌃-click add single todos")
        s.click(r[2], .command)
        check(s.selection == [r[0], r[4]], "⌘-click again drops one")
        _ = s.handleAppKey(back, textEditing: false)
        check(s.confirmRemove.count == 2, "⌫ asks once for all the picked todos")
        _ = s.handleAppKey(ret, textEditing: false)
        check(s.notes.count == openBefore - 2, "↩ removes both")
        _ = s.handleAppKey(key(6, "z", .command), textEditing: false)
        check(s.notes.count == openBefore, "one ⌘Z brings both back")
        s.click(r[1], [])
        s.click(r[3], .shift)
        check(s.selection == Set(r[1...3]), "⇧-click selects a range")
        _ = s.handleAppKey(down, textEditing: false)
        check(s.selection.isEmpty, "a plain ↓ drops the selection")
        s.pane = .sidebar
        _ = s.handleAppKey(key(0, "a", .command), textEditing: false)
        check(s.pane == .list && s.selection.count == s.notes.count && s.selection.allSatisfy { $0.hasPrefix("t:") },
              "⌘A selects every todo in the list")
        let everyOpen = s.notes.count
        _ = s.handleAppKey(key(40, "k", .command), textEditing: false)
        check(s.notes.isEmpty, "⌘K then ticks all \(everyOpen) of them")
        _ = s.handleAppKey(key(6, "z", .command), textEditing: false)
        check(s.notes.count == everyOpen, "…and one ⌘Z brings them all back")
        s.pane = .search
        let inSearch = s.handleAppKey(key(0, "a", .command), textEditing: true)
        check(!inSearch, "⌘A in the search bar is left to the text (select all of it)")
        s.pane = .list
        s.clearSelection()

        // two lines of one capture, ticked together (the file moves to done/) and reopened together from the Logbook
        guard let pairFile = try? NotesFS.write(group: "pair", filedUnder: "pair", branch: nil, capturedIn: "test",
                                                focus: nil, about: nil, items: ["pair one", "pair two"]) else {
            check(false, "write a two-line capture")
            return
        }
        s.reloadNotes()
        s.complete(s.notes.filter { $0.group == "pair" })
        check(!FileManager.default.fileExists(atPath: pairFile.path) && s.closed.filter { $0.group == "pair" }.count == 2,
              "ticking both lines of one capture moves its file to done/")
        s.select("*logbook")
        s.pane = .list
        s.selection = Set(s.listRows().filter { if case .closed(let n) = $0 { return n.group == "pair" }; return false }.map(\.id))
        _ = s.handleAppKey(key(49, " "), textEditing: false)
        check(s.notes.filter { $0.group == "pair" }.count == 2 && FileManager.default.fileExists(atPath: pairFile.path),
              "reopening both from the Logbook brings the file back with both lines open")
        _ = s.handleAppKey(key(6, "z", .command), textEditing: false)
        check(s.closed.filter { $0.group == "pair" }.count == 2, "…and one ⌘Z closes both again")

        // ⌫ in the Logbook deletes for good, after asking: the line leaves its file, and a file left empty goes
        func pairRows() -> [String] {
            s.listRows().filter { if case .closed(let n) = $0 { return n.group == "pair" }; return false }.map(\.id)
        }
        s.clearSelection()
        s.cursor = pairRows().first
        _ = s.handleAppKey(back, textEditing: false)
        check(s.confirmRemove.count == 1 && s.confirmRemove.allSatisfy { $0.state != .open },
              "⌫ on a Logbook line asks before deleting it")
        _ = s.handleAppKey(key(53), textEditing: false)
        check(s.confirmRemove.isEmpty && pairRows().count == 2, "esc keeps it")
        _ = s.handleAppKey(back, textEditing: false)
        _ = s.handleAppKey(ret, textEditing: false)
        let pairDone = s.closed.first { $0.group == "pair" }?.file
        let pairLeft = pairDone.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        check(pairRows().count == 1 && pairLeft.components(separatedBy: "\n").filter { $0.hasPrefix("- [") }.count == 1,
              "↩ erases that one line from its file; the other line stays")
        s.cursor = pairRows().first
        _ = s.handleAppKey(back, textEditing: false)
        _ = s.handleAppKey(ret, textEditing: false)
        check(pairRows().isEmpty && pairDone.map { !FileManager.default.fileExists(atPath: $0.path) } == true,
              "deleting the last line of a file deletes the file")
        let mixed = Config.notesDir.appendingPathComponent("with my own text.md")
        try? "- [x] erase me ✅ 2026-10-01 10:00\nsome notes of mine\n".write(to: mixed, atomically: true, encoding: .utf8)
        s.reloadNotes()
        s.cursor = s.closed.first { $0.text == "erase me" }.map { "c:" + $0.id }
        _ = s.handleAppKey(back, textEditing: false)
        _ = s.handleAppKey(ret, textEditing: false)
        let mixedLeft = (try? String(contentsOf: mixed, encoding: .utf8)) ?? ""
        check(mixedLeft.contains("some notes of mine") && !mixedLeft.contains("erase me"),
              "a file with text of your own stays; only the line goes")

        // the quick note: straight into the todo box; Tab goes to "Project" and back, never typing a tab
        let cap = CaptureModel(store: s, fromEnd: false, context: nil)
        check(cap.startField == .notes && cap.target.group == "General", "⌥⌘N starts in the todo box, project General")
        cap.focusChanged(.target)
        check(!cap.showTargets && cap.field == .notes, "macOS focusing “Project” first doesn't open its list")
        cap.ready = true
        let tabbed = cap.handleKey(tab)
        check(tabbed && cap.field == .target, "Tab in the todo box jumps to “Project”")
        cap.focusChanged(.target)
        _ = cap.handleKey(tab)
        check(cap.field == .notes && cap.target.group == "General", "Tab again goes back to the todos, still General")
        cap.focusChanged(.target)
        cap.query = "test-list-x"
        _ = cap.handleKey(tab)
        check(cap.target.label == "test-list-x" && cap.field == .target && !cap.showTargets,
              "typing a filter then Tab takes the match and stays on “Project”")
        var closedPanel = false
        cap.onDone = { closedPanel = true }
        _ = cap.handleKey(ret)
        check(cap.field == .notes && !closedPanel, "↩ there with no todos written goes back to the todo box")
        check(!cap.handleKey(ret), "↩ in the todo box is a new line")
        cap.field = .target
        _ = cap.handleKey(down)
        check(cap.showTargets && cap.query.isEmpty && cap.filtered.count > 1, "↓ on a picked project opens the whole list again")

        func quickNote(_ text: String, _ keys: [NSEvent]) -> (saved: Note?, closed: Bool) {
            let m = CaptureModel(store: s, fromEnd: false, context: nil)
            var closed = false
            m.onDone = { closed = true }
            m.ready = true
            m.notes = text
            _ = m.handleKey(tab)
            m.focusChanged(.target)
            m.query = "errands"
            for k in keys { _ = m.handleKey(k) }
            s.reloadNotes()
            return (s.notes.first { $0.text == text }, closed)
        }
        let viaEnter = quickNote("saved with enter in project", [ret])
        check(viaEnter.saved?.group == "errands" && viaEnter.closed, "↩ in the “Project” list picks the project and saves")
        let viaTab = quickNote("saved with tab then enter", [tab, ret])
        check(viaTab.saved?.group == "errands" && viaTab.closed, "Tab picks it, then ↩ saves")

        // what the "Project" list really draws (rendered offscreen, read back with OCR): typing a filter must redraw
        // the rows, not just the section headers above them
        _ = NSApplication.shared
        let shown = CaptureModel(store: s, fromEnd: false, context: nil)
        shown.ready = true
        shown.focusChanged(.target)
        let host = NSHostingView(rootView: TargetList(model: shown).background(Color.white))   // OCR needs it opaque
        host.appearance = NSAppearance(named: .aqua)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300), styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.contentView = host
        func drawn() -> String {
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            let size = host.bounds.size
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2,
                                             pixelsHigh: Int(size.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return "" }
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let cg = rep.cgImage else { return "" }
            let req = VNRecognizeTextRequest()
            try? VNImageRequestHandler(cgImage: cg).perform([req])
            return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | ").lowercased()
        }
        let before = drawn()
        check(before.contains("general") && before.contains("errands"), "the “Project” list draws every project (\(before))")
        shown.query = "errands"
        let after = drawn()
        check(after.contains("errands") && !after.contains("general"), "typing a filter redraws the rows (\(after))")
        shown.query = "zz brand new list"
        let fresh = drawn()
        check(fresh.contains("create list") && !fresh.contains("errands"), "…and offers to create a new list (\(fresh))")
    }
}
