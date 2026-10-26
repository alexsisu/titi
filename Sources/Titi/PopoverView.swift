import SwiftUI

/// "Claude | ~/code/x" with the tool name coloured.
func toolText(_ label: String) -> Text {
    let parts = label.components(separatedBy: " | ")
    if parts.count == 2, parts[0] == "Claude" || parts[0] == "Codex" {
        return Text(parts[0]).bold().foregroundColor(parts[0] == "Claude" ? .orange : .blue) + Text(" | " + parts[1])
    }
    return Text(label)
}

func hlText(_ s: String, _ q: String) -> Text {
    var a = AttributedString(s)
    if !q.isEmpty, let r = a.range(of: q, options: .caseInsensitive) {
        a[r].backgroundColor = Color.yellow.opacity(0.4)
    }
    return Text(a)
}

struct PopoverView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                TabButton(title: "Active items", badge: "\(store.notes.count)", tint: .gray, on: store.tab == .active) {
                    store.tab = .active
                }
                TabButton(title: "Focus", badge: focusBadge, tint: store.focus.mode == .paused ? .orange : .red,
                          on: store.tab == .focus) {
                    store.tab = .focus
                }
            }
            .padding(8)
            Divider()
            Group {
                switch store.tab {
                case .active: ActiveItemsView()
                case .focus: FocusTabView()
                case .forgotten: ForgottenView()
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            FooterView()
        }
        .frame(width: 400, height: 600)
    }

    private var focusBadge: String? {
        switch store.focus.mode {
        case .idle: return nil
        case .paused: return "⏸ \(Int((store.focus.remaining / 60).rounded(.up)))m"
        default: return "● \(Int((store.focus.remaining / 60).rounded(.up)))m"
        }
    }
}

struct TabButton: View {
    let title: String
    let badge: String?
    let tint: Color
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                if let badge {
                    Text(badge).font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.3)))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.primary.opacity(0.13) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Active items

struct ActiveItemsView: View {
    @EnvironmentObject var store: Store
    @FocusState private var filterFocused: Bool

    var body: some View {
        let rows = store.rows()
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Filter todos and folders…   ↑↓ move · → open · ← close", text: $store.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($filterFocused)
                    .onChange(of: store.query) { store.cursor = nil }
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(store.scanning ? 180 : 0))
                        .animation(.easeInOut(duration: 0.5), value: store.scanning)
                }
                .help("Rescan sessions and folders")
                .disabled(store.scanning)
            }
            .padding(8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            RowView(row: row).id(row.id)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .onChange(of: store.cursor) { _, c in
                    if let c { proxy.scrollTo(c) }
                }
            }
        }
        .onAppear { filterFocused = true }
        .onChange(of: store.popoverOpenCount) { filterFocused = true }
    }
}

struct RowView: View {
    @EnvironmentObject var store: Store
    let row: Row

    var body: some View {
        let isCursor = store.cursor == row.id
        Group {
            switch row {
            case .header(let t):
                Text(t.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 3)
            case .about(let n):
                AboutRow(note: n)
            case .group(let g, let open):
                GroupRow(group: g, open: open)
            case .task(let n):
                TaskRow(note: n)
            case .session(let s):
                SessionRow(session: s)
            case .message(_, let m):
                Text(m).font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 34).padding(.vertical, 3)
            case .closed, .create:   // only in the app window
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCursor ? Color.accentColor.opacity(0.25) : Color.clear)
    }
}

struct AboutRow: View {
    @EnvironmentObject var store: Store
    let note: Note

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Button { store.complete(note) } label: { Image(systemName: "square") }
                .buttonStyle(.plain).padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                (toolText(note.filedUnder) + Text(note.branch.map { " · " + shortBranch($0) } ?? "")
                    + Text(" · " + ago(note.created)))
                    .font(.caption2).foregroundColor(.orange).lineLimit(1)
                if store.editingID == note.id { EditField() } else { Text(note.text) }
            }
            Spacer(minLength: 4)
            if note.isDemo { DemoTag() }
            if note.group.hasPrefix("~") {
                Button { store.bringTab(note: note) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(.plain).help("Back to the iTerm tab you wrote this in")
            }
            Button { store.focusOn(note) } label: { Image(systemName: "play.fill").foregroundStyle(.red) }
                .buttonStyle(.plain).help("Focus on this")
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange.opacity(0.10)))
        .overlay(alignment: .leading) { Rectangle().fill(Color.orange).frame(width: 3) }
        .padding(.horizontal, 10).padding(.vertical, 2)
    }
}

struct GroupRow: View {
    @EnvironmentObject var store: Store
    let group: GroupInfo
    let open: Bool
    private var hover: Bool { store.hoverID == "g:" + group.key }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.isFolder ? "folder" : (group.key == "General" ? "tray" : "list.bullet"))
                .foregroundStyle(.secondary).frame(width: 16)
            hlText(group.key, store.queryLower).lineLimit(1).truncationMode(.middle)
            if !group.tasks.isEmpty {
                Text("\(group.tasks.count)").font(.caption2.weight(.bold)).foregroundStyle(.black)
                    .padding(.horizontal, 5).background(Capsule().fill(Color.orange))
            }
            ForEach(group.tools, id: \.self) { t in
                Text(t).font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(t == "Claude" ? Color.orange : Color.blue)
                    .padding(.horizontal, 3)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(t == "Claude" ? Color.orange : Color.blue, lineWidth: 0.8))
            }
            Spacer(minLength: 4)
            if group.isFolder {
                Button { store.bringTab(folder: group.key) } label: { Image(systemName: "terminal") }
                    .buttonStyle(.plain).opacity(hover ? 1 : 0.25)
                    .help("Bring its iTerm tab forward (or open one there)")
            }
            Text(ago(group.last)).font(.caption).foregroundStyle(.secondary)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0))
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { store.toggle(group.key) }
        .onHover { store.setHover("g:" + group.key, $0) }
    }
}

struct TaskRow: View {
    @EnvironmentObject var store: Store
    let note: Note
    private var hover: Bool { store.hoverID == "t:" + note.id }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button { store.complete(note) } label: { Image(systemName: "square") }.buttonStyle(.plain)
            if store.editingID == note.id {
                EditField()
            } else {
                (Text(note.isAbout ? "⏯ " : "") + hlText(note.text, store.queryLower)
                    + Text(note.branch.map { "  " + shortBranch($0) } ?? "").font(.caption).foregroundColor(.secondary))
            }
            Spacer(minLength: 4)
            if note.isDemo { DemoTag() }
            Button { store.focusOn(note) } label: { Image(systemName: "play.fill").foregroundStyle(.red) }
                .buttonStyle(.plain).opacity(hover ? 1 : 0.2).help("Focus on this")
        }
        .padding(.leading, 34).padding(.trailing, 12).padding(.vertical, 3)
        .onHover { store.setHover("t:" + note.id, $0) }
    }
}

struct SessionRow: View {
    @EnvironmentObject var store: Store
    let session: LiveSession

    var body: some View {
        let what = session.branch.map(shortBranch) ?? session.title ?? "session"
        HStack(spacing: 4) {
            toolText("\(session.tool) | \(what)").lineLimit(1)
            Text("· open \(ago(session.started))").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
        }
        .padding(.leading, 34).padding(.trailing, 12).padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { store.bringTab(session: session) }
        .help(session.title ?? session.tty)
    }
}

struct DemoTag: View {
    var body: some View {
        Text("demo").font(.system(size: 9)).foregroundStyle(.secondary)
            .padding(.horizontal, 3).overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.5)))
    }
}

// MARK: Focus

struct FocusTabView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        if store.focus.mode == .idle { FocusPicker() } else { FocusRunning() }
    }
}

struct FocusPicker: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PICK A TODO TO FOCUS ON").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(store.notes.sorted { $0.created > $1.created }) { n in
                        PickRow(note: n, picked: store.pickedNoteID == n.id)
                    }
                }
                .padding(.horizontal, 10)
            }
            VStack(alignment: .leading, spacing: 7) {
                TextField("…or type something new to nail down", text: $store.newGoal)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: store.newGoal) { if !store.newGoal.isEmpty { store.pickedNoteID = nil } }
                    .onSubmit { store.startFocus() }
                Group {
                    if store.pickedNoteID != nil {
                        Text("focusing on the picked todo")
                    } else {
                        Text("a new goal is filed under ") + toolText(store.lastContext?.label ?? "General")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("", selection: $store.minutes) {
                        ForEach(Config.durations, id: \.self) { Text("\($0)m").tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                    Spacer()
                    Button("Start") { store.startFocus() }
                        .buttonStyle(.borderedProminent).tint(.red).disabled(!store.canStart)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            .padding(10)
        }
    }
}

struct PickRow: View {
    @EnvironmentObject var store: Store
    let note: Note
    let picked: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(picked ? Color.red : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                (toolText(note.filedUnder) + Text(" · " + ago(note.created))).font(.caption2).foregroundColor(.secondary)
                Text((note.isAbout ? "⏯ " : "") + note.text)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5).fill(picked ? Color.red.opacity(0.15) : Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture {
            store.pickedNoteID = picked ? nil : note.id
            store.newGoal = ""
        }
    }
}

struct FocusRunning: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let f = store.focus
        let paused = f.mode == .paused
        let tint: Color = paused ? .orange : .red
        VStack(alignment: .leading, spacing: 8) {
            if f.mode == .timeUp {
                Text("⏰ \(Int(f.total / 60)) minutes are up").font(.headline)
                Text("Did you nail “\(f.goal)”?")
                HStack {
                    Button("✓ Nailed it") { store.nailed() }.buttonStyle(.borderedProminent).tint(.green)
                    Button("+10 min") { store.extend() }
                    Button("Not yet: note where I am") { store.notYet() }
                }
            } else {
                Text(paused ? "PAUSED" : "FOCUSING").font(.caption2.weight(.bold)).foregroundStyle(tint)
                toolText(f.label).font(.caption)
                Text(f.goal)
                Text(fmtTime(f.remaining)).font(.system(size: 32, weight: .semibold).monospacedDigit())
                ProgressView(value: f.total > 0 ? 1 - f.remaining / f.total : 0).tint(tint)
                HStack {
                    if paused {
                        Button((f.group?.hasPrefix("~") ?? false) ? "▶ Resume + bring back iTerm tab" : "▶ Resume") {
                            store.resume()
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("I got interrupted") { store.interrupt() }
                    }
                    Button("✓ Nailed it") { store.nailed() }
                    Button("Stop") { store.stopFocus() }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
        .padding(10)
    }
}

// MARK: Forgotten

struct ForgottenView: View {
    @EnvironmentObject var store: Store
    var onBack: (() -> Void)? = nil

    var body: some View {
        let items = store.forgottenItems()
        VStack(alignment: .leading, spacing: 0) {
            Button(onBack == nil ? "← back to Active items" : "← back to TODOs") {
                if let onBack { onBack() } else { store.tab = .active }
            }
                .buttonStyle(.link).padding(.horizontal, 12).padding(.top, 8)
            Text("◌ Forgotten work").font(.callout.weight(.semibold)).padding(.horizontal, 12).padding(.top, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(ForgottenItem.Kind.allCases, id: \.self) { kind in
                        let list = items.filter { $0.kind == kind }
                        if !list.isEmpty {
                            Text(kind.rawValue.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
                            ForEach(list) { it in
                                HStack(alignment: .top, spacing: 6) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        toolText(it.title).lineLimit(2)
                                        Text(it.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer(minLength: 4)
                                    Button("revive") { store.revive(it) }.controlSize(.small)
                                    Button("remove") { store.remove(it) }.controlSize(.small)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 4)
                            }
                        }
                    }
                    if items.isEmpty {
                        Text("nothing forgotten 🎉").foregroundStyle(.secondary).padding(12)
                    }
                }
            }
        }
    }
}

struct FooterView: View {
    @EnvironmentObject var store: Store
    private var ghostHover: Bool { store.hoverID == "ghost" }

    var body: some View {
        HStack(spacing: 8) {
            Button { store.onOpenApp?() } label: { Text("⤢ Open app").font(.caption) }
                .buttonStyle(.plain).help("Open the full window (⌘O)")
            Text("· ⌥⌘N quick note").font(.caption).foregroundStyle(.secondary)
            Button { store.onOpenSettings?() } label: { Text("· ⚙︎ Settings").font(.caption) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("The notes folder (⌘,)")
            Spacer()
            Text("scanned \(store.scannedAt == .distantPast ? "…" : ago(store.scannedAt)) · \(store.doneToday) done · \(store.blocksToday) focus today")
                .font(.caption).foregroundStyle(.secondary)
            Button { store.tab = .forgotten } label: {
                HStack(spacing: 3) {
                    Text("◌")
                    if ghostHover { Text("forgotten (\(store.forgottenItems().count))").font(.caption2) }
                }
            }
            .buttonStyle(.plain)
            .opacity(ghostHover ? 1 : 0.25)
            .onHover { store.setHover("ghost", $0) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }
}
