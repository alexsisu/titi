import SwiftUI

/// The full window: Notational Velocity's search-or-create bar on top, Things-like views and your folders on the
/// left, the selected list on the right. Active is the tray popover's own list, full size.
struct AppWindowView: View {
    @EnvironmentObject var store: Store
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search open and closed todos…   ↩ creates it in \(store.createTarget) when nothing matches",
                          text: $store.appQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                FocusPill()
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            Text("Tab search → sidebar → list · ← back · ⌘N new · ⌘K done · ⌫ remove · ⇧↑↓ / ⌘-click / ⌘A select · ⌘Z undo · ⌘↩ focus · ⌘S report · ⌘O")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 7)
            Divider()
            HStack(spacing: 0) {
                SidebarView().frame(width: 280)
                Divider()
                MainPane().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { searchFocused = store.pane == .search }
        .onChange(of: store.pane) { _, p in searchFocused = p == .search }
        .onChange(of: searchFocused) { _, f in
            if f, store.editingID == nil, store.adding == nil { store.pane = .search }
        }
    }
}

struct FocusPill: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let f = store.focus
        let mins = Int((f.remaining / 60).rounded(.up))
        switch f.mode {
        case .idle:
            Text("no focus running · ⌘↩ on a todo").font(.caption).foregroundStyle(.secondary)
        case .timeUp:
            Menu {
                Button("✓ Nailed it") { store.nailed() }
                Button("+10 min") { store.extend() }
                Button("Not yet: note where I am") { store.notYet() }
            } label: {
                Text("⏰ time's up · \(f.goal)").foregroundStyle(.red).lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize()
        case .running, .paused:
            Menu {
                if f.mode == .paused {
                    Button("▶ Resume") { store.resume() }
                } else {
                    Button("I got interrupted") { store.interrupt() }
                }
                Button("✓ Nailed it") { store.nailed() }
                Button("Stop") { store.stopFocus() }
            } label: {
                Text("\(f.mode == .paused ? "⏸" : "●") Focus \(mins)m · \(f.goal)")
                    .foregroundStyle(f.mode == .paused ? .orange : .red).lineLimit(1)
            }
            .menuStyle(.borderlessButton).frame(maxWidth: 320).fixedSize(horizontal: true, vertical: false)
        }
    }
}

// MARK: sidebar

struct SidebarView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let groups = store.allGroups()
        let folders = groups.filter { $0.isFolder && !store.isQuiet($0) }
        let quiet = groups.filter { store.isQuiet($0) }
        let f = store.focus
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SideItem(key: "*all", icon: "tray.full", name: "TODOs", count: store.notes.count,
                             plainCount: true, shortcut: "⌘1")
                    SideItem(key: "*logbook", icon: "checkmark.square", name: "Logbook",
                             note: "\(store.doneToday) done today", shortcut: "⌘2")
                    SideItem(key: "*focus", icon: "timer", name: "Focus",
                             note: f.mode == .idle ? nil : "\(f.mode == .paused ? "⏸" : "●") \(Int((f.remaining / 60).rounded(.up)))m",
                             shortcut: "⌘3")

                    SideHeader(text: "Lists")
                    ForEach(store.orderedLists, id: \.self) { l in
                        SideItem(key: l, icon: l == "General" ? "tray" : "list.bullet", name: l,
                                 suffix: l == "General" ? "default" : nil,
                                 count: store.notes.filter { $0.group == l }.count)
                    }

                    SideHeader(text: "Folders · newest first")
                    ForEach(folders) { g in
                        SideItem(key: g.key, icon: "folder", name: String(g.key.dropFirst(2)),
                                 tools: g.tools, count: g.tasks.count, age: ago(g.last))
                    }

                    Button { store.quietExpanded.toggle() } label: {
                        HStack {
                            Text("GOING QUIET (\(quiet.count))").font(.caption2.weight(.semibold))
                            Image(systemName: "chevron.right").font(.caption2)
                                .rotationEffect(.degrees(store.quietExpanded ? 90 : 0))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 3)
                    if store.quietExpanded {
                        ForEach(quiet) { g in
                            SideItem(key: g.key, icon: "folder", name: String(g.key.dropFirst(2)), age: ago(g.last))
                                .opacity(0.6)
                        }
                    }

                    Button { store.select("*forgotten") } label: {
                        Text("◌ forgotten (\(store.forgottenItems().count))").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .opacity(store.hoverID == "app-ghost" || store.appSelection == "*forgotten" ? 1 : 0.3)
                    .onHover { store.setHover("app-ghost", $0) }
                    .padding(12)
                }
                .padding(.vertical, 6)
            }
            .onChange(of: store.appSelection) { _, k in proxy.scrollTo(k) }
        }
        .background(Color.primary.opacity(0.03))
    }
}

struct SideHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 3)
    }
}

struct SideItem: View {
    @EnvironmentObject var store: Store
    let key: String
    let icon: String
    let name: String
    var suffix: String? = nil
    var tools: [String] = []
    var count = 0
    var plainCount = false
    var note: String? = nil
    var age: String? = nil
    var shortcut: String? = nil

    var body: some View {
        let on = store.appQuery.isEmpty && store.appSelection == key
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            Text(name).lineLimit(1).truncationMode(.middle)
            if let suffix { Text(suffix).font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 4)
            ForEach(tools, id: \.self) { t in
                Circle().fill(t == "Claude" ? Color.orange : Color.blue).frame(width: 6, height: 6).help(t + " running here")
            }
            if count > 0 {
                if plainCount {
                    Text("\(count)").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(count)").font(.caption2.weight(.bold)).foregroundStyle(.black)
                        .padding(.horizontal, 5).background(Capsule().fill(Color.orange))
                }
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            if let age { Text(age).font(.caption).foregroundStyle(.secondary).frame(minWidth: 22, alignment: .trailing) }
            if let shortcut { Text(shortcut).font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
        .background(on ? Color.accentColor.opacity(store.pane == .sidebar ? 0.55 : 0.22) : Color.clear)
        .contentShape(Rectangle())
        .id(key)
        .onTapGesture {
            store.select(key)
            store.pane = .sidebar
        }
    }
}

// MARK: main pane

struct MainPane: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let q = store.appQuery.trimmed
        if let md = store.report, q.isEmpty {
            ReportView(markdown: md)
        } else if store.appSelection == "*forgotten" && q.isEmpty {
            ForgottenView(onBack: { store.select("*all") })
        } else if store.appSelection == "*focus" && q.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PaneHeader()
                Divider()
                FocusTabView()
            }
        } else {
            let rows = store.listRows()
            VStack(alignment: .leading, spacing: 0) {
                PaneHeader()
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        // the same cards in a frame as the to-do list view
                        LazyVStack(alignment: .leading, spacing: 6) {
                            Color.clear.frame(height: 0).id("top")
                            if let target = store.adding {
                                AddRow(target: target).modifier(TodoCard(on: true, active: true))
                            }
                            ForEach(rows) { row in
                                WindowRow(row: row).id(row.id)
                            }
                        }
                        .modifier(ListFrame())
                        .padding(14)
                    }
                    .onChange(of: store.cursor) { _, c in
                        if let c { proxy.scrollTo(c) }
                    }
                    .onChange(of: store.adding) { _, a in   // ⌘N in a long list: back to the top, where the box is
                        if a != nil { withAnimation { proxy.scrollTo("top", anchor: .top) } }
                    }
                }
            }
        }
    }
}

struct PaneHeader: View {
    @EnvironmentObject var store: Store

    static let titles: [String: (String, String)] = [
        "*all": ("☑︎ TODOs", "every open todo, newest first · ⌘N files into General"),
        "*logbook": ("✅ Logbook", "closed todos by day · ⌘K reopens one · lines ticked in Sublime have no date and go last"),
        "*focus": ("🎯 Focus", "pick a todo and start, or ⌘↩ on any todo anywhere"),
    ]

    var body: some View {
        let q = store.appQuery.trimmed
        let sel = store.appSelection
        let group = store.allGroups().first { $0.key == sel && $0.isFolder }
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if !q.isEmpty {
                    Text("Search: “\(q)”").font(.headline)
                    Text("open and closed todos everywhere · ↓ steps into the results · ↩ creates it in \(store.createTarget) when nothing matches")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let g = group {
                    Text("📁 " + g.key).font(.headline)
                    let branch = g.sessions.compactMap(\.branch).first
                    Text((branch.map { "branch " + shortBranch($0) + " · " } ?? "") + "last activity " + (g.last.map { ago($0) + " ago" } ?? "unknown"))
                        .font(.caption).foregroundStyle(.secondary)
                    FlowChips(group: g)
                } else {
                    let t = Self.titles[sel] ?? ((sel == "General" ? "📥 " : "🗂 ") + sel,
                                                 sel == "General" ? "quick notes and new todos land here by default" : "a list you created")
                    Text(t.0).font(.headline)
                    Text(t.1).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if q.isEmpty {
                if sel == "*logbook" {
                    Button("Freeze today's report  ⌘S") { store.freezeReport() }.buttonStyle(.borderedProminent)
                } else if !["*logbook", "*focus", "*forgotten"].contains(sel) {
                    Button("＋ New todo  ⌘N") { store.startAdd() }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// One chip per live session (click = bring that iTerm tab forward) plus "open terminal here".
struct FlowChips: View {
    @EnvironmentObject var store: Store
    let group: GroupInfo

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(group.sessions) { s in
                    Button { store.bringTab(session: s) } label: {
                        toolText("\(s.tool) | \(s.title ?? s.branch.map(shortBranch) ?? "session")") + Text("  ↗")
                    }
                    .controlSize(.small)
                    .help("Bring this iTerm tab forward · \(s.tty)")
                }
                Button { store.bringTab(folder: group.key) } label: { Text("⌨ open terminal here") }
                    .controlSize(.small)
                    .help("The tab you last typed in for this folder, or a new one cd'ed here")
            }
        }
    }
}

/// One row of the window's list.
struct WindowRow: View {
    @EnvironmentObject var store: Store
    let row: Row

    var body: some View {
        let on = store.cursor == row.id || store.selection.contains(row.id)
        let active = store.pane == .list
        Group {
            switch row {
            case .header(let t):
                Text(t.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 0)
            case .task(let n), .about(let n):
                TodoRow(note: n)
            case .group, .session:
                EmptyView()   // the tray's tree; the window's lists are flat
            case .message(_, let m):
                Text(m).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(.leading, 34).padding(.trailing, 12).padding(.vertical, 2)
            case .closed(let c):
                ClosedRow(note: c)
            case .create(let t):
                Text("＋  Create “\(t)” in \(store.createTarget)").foregroundStyle(.green)
                    .padding(.horizontal, 12).padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !row.isCard && on { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(active ? 0.35 : 0.15)) }
        }
        .modifier(TodoCard(on: on, active: active, enabled: row.isCard))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            guard row.navigable else { return }
            store.click(row.id, NSEvent.modifierFlags)
            store.pane = .list
            if case .create = row { store.createFromQuery() }
        })
    }
}

/// The inline row ⌘N opens: at the top of the app's list, at the bottom of the Things list.
struct AddRow: View {
    @EnvironmentObject var store: Store
    let target: String
    var things = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: things ? 10 : 6) {
            Image(systemName: things ? "circle" : "square").foregroundStyle(.secondary)
            TextField("New \(things ? "to-do" : "todo") in \(target)   ↩ saves and starts another · esc stops",
                      text: $store.addText)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit {
                    store.saveAdd()
                    DispatchQueue.main.async { focused = store.adding != nil }
                }
        }
        .padding(.horizontal, things ? 8 : 12).padding(.vertical, things ? 5 : 8)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: target) { DispatchQueue.main.async { focused = true } }
    }
}

/// Edits a todo's text in place: ↩ saves, esc cancels.
struct EditField: View {
    @EnvironmentObject var store: Store
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $store.editText)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { store.commitEdit() }
            .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

struct TodoRow: View {
    @EnvironmentObject var store: Store
    let note: Note

    var body: some View {
        let selected = store.cursor.map { $0.dropFirst(2) == note.id } ?? false
        let hover = store.hoverID == "row:" + note.id
        let q = store.appQuery.trimmed.lowercased()
        HStack(spacing: 6) {
            Button { store.complete(note) } label: { Image(systemName: "square") }
                .buttonStyle(.plain).help("Done (⌘K)")
            if store.editingID == note.id {
                EditField()
            } else {
                (Text(note.isAbout ? "⏯ " : "").foregroundColor(.orange) + hlText(note.text, q))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupLabel(note: note, q: q)
            Text(ago(note.created)).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
            HStack(spacing: 8) {
                if note.group.hasPrefix("~") {
                    Button { store.bringTab(note: note) } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.plain).help("Back to the iTerm tab this was written in")
                }
                Button { store.startFocus(note: note) } label: { Image(systemName: "play.fill").foregroundStyle(.red) }
                    .buttonStyle(.plain).help("Focus on this (⌘↩)")
            }
            .frame(width: 44, alignment: .trailing)
            .opacity(selected || hover ? 1 : 0.15)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .onTapGesture(count: 2) { store.beginEdit(note) }
        .onHover { store.setHover("row:" + note.id, $0) }
    }
}

/// A done (☑) or removed (☒, struck through) line. The box reopens it.
struct ClosedRow: View {
    @EnvironmentObject var store: Store
    let note: Note

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    var body: some View {
        let done = note.state == .done
        let q = store.appQuery.trimmed.lowercased()
        let when = note.closedAt.map { workday($0) == workday() ? Report.hm.string(from: $0) : Self.date.string(from: $0) } ?? "—"
        HStack(spacing: 6) {
            Button { store.reopen(note) } label: { Image(systemName: done ? "checkmark.square" : "xmark.square") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Reopen (⌘K)")
            (Text(note.isAbout ? "⏯ " : "") + hlText(note.text, q))
                .strikethrough(!done)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            GroupLabel(note: note, q: q)
            Text(when).font(.caption).foregroundStyle(.secondary).frame(width: 50, alignment: .trailing)
            Spacer().frame(width: 44)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// "code/acme-api · faster-checkout" in the list's middle column.
struct GroupLabel: View {
    let note: Note
    let q: String

    var body: some View {
        (hlText(note.group.hasPrefix("~/") ? String(note.group.dropFirst(2)) : note.group, q)
            + Text(note.branch.map { " · " + shortBranch($0) } ?? ""))
            .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            .frame(width: 220, alignment: .leading)
    }
}

struct ReportView: View {
    @EnvironmentObject var store: Store
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Today's report").font(.headline)
                    Text(store.reportURL.map { "saved to \(store.notesFolder.lastPathComponent)/reports/\($0.lastPathComponent) and copied" } ?? "copied")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { store.copyReport() }
                Button("Open file") { store.openReportFile() }.disabled(store.reportURL == nil)
                Button(store.narrating ? "Narrating…" : "✨ Narrate with claude -p") { store.narrate() }
                    .disabled(store.narrating)
                    .help("Optional: asks claude -p for a short summary and adds it under the facts")
                Button("Close  esc") { store.report = nil }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                Text(markdown)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
    }
}

struct ConfirmRemoveBox: View {
    @EnvironmentObject var store: Store
    let notes: [Note]

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .onTapGesture { store.confirmRemove = [] }
            VStack(alignment: .leading, spacing: 8) {
                Text(notes.count == 1 ? "Remove this todo?" : "Remove these \(notes.count) todos?").font(.headline)
                ForEach(notes.prefix(6)) { n in Text("“\(n.text)”").lineLimit(2) }
                if notes.count > 6 { Text("…and \(notes.count - 6) more").foregroundStyle(.secondary) }
                Text("Each line becomes “- [-] …”, and a file with nothing open left moves to removed/. Nothing is erased; ⌘Z brings them back.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel  esc") { store.confirmRemove = [] }
                    Button("Remove  ↩") {
                        store.confirmRemove = []
                        store.removeTodos(notes)
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                }
            }
            .padding(16)
            .frame(width: 440)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
            .shadow(radius: 20)
            .padding(.top, 90)
        }
    }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().stroke(Color.primary.opacity(0.15)))
            .padding(.bottom, 16)
    }
}
