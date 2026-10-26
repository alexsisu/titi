import SwiftUI

/// The window's root: the app, or the Things-style to-do list (⌘O switches), with the overlays both share.
struct WindowRoot: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if store.windowMode == .things { ThingsView() } else { AppWindowView() }
        }
        .frame(minWidth: 900, minHeight: 540)
        .overlay { if !store.confirmRemove.isEmpty { ConfirmRemoveBox(notes: store.confirmRemove) } }
        .overlay(alignment: .bottom) { if let t = store.toast { ToastView(text: t) } }
    }
}

/// Like Things: TODOs, Logbook, your folders and lists on the left; one clean list with a big title on the right.
/// No search bar and no tray tree: the same todos, the same keys (⌘N, ⌘K, ⌫, ⌘Z, ⌘↩), just a to-do list.
struct ThingsView: View {
    var body: some View {
        HStack(spacing: 0) {
            ThingsSidebar().frame(width: 240)
            Divider()
            ThingsList().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ThingsSidebar: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let groups = store.allGroups()
        let folders = groups.filter { $0.isFolder && !store.isQuiet($0) }
        let lists = store.orderedLists
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ThingsSideItem(key: "*all", icon: "checklist", tint: .blue, name: "TODOs", count: store.notes.count)
                    ThingsSideItem(key: "*logbook", icon: "checkmark.square.fill", tint: .green, name: "Logbook")

                    ThingsSideHeader(text: "Folders")
                    ForEach(folders) { g in
                        ThingsSideItem(key: g.key, dot: g.tools.first.map { $0 == "Claude" ? .orange : .blue },
                                       name: String(g.key.dropFirst(2)), count: g.tasks.count)
                    }
                    if !lists.isEmpty {
                        ThingsSideHeader(text: "Lists")
                        ForEach(lists, id: \.self) { l in
                            ThingsSideItem(key: l, icon: "list.bullet", tint: .secondary, name: l,
                                           count: store.notes.filter { $0.group == l }.count)
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 14)
            }
            .onChange(of: store.appSelection) { _, k in proxy.scrollTo(k) }
        }
        .background(Color.primary.opacity(0.04))
    }
}

struct ThingsSideHeader: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
    }
}

struct ThingsSideItem: View {
    @EnvironmentObject var store: Store
    let key: String
    var icon: String? = nil
    var tint: Color = .secondary
    var dot: Color? = nil          // a live Claude (orange) or Codex (blue) session in this folder
    let name: String
    var count = 0

    var body: some View {
        let on = store.appSelection == key
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 18)
            } else {
                Circle().fill(dot ?? .clear).frame(width: 7, height: 7).frame(width: 18)
            }
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if count > 0 { Text("\(count)").font(.callout).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(on ? Color.accentColor.opacity(store.pane == .sidebar ? 0.45 : 0.2) : Color.clear))
        .contentShape(Rectangle())
        .id(key)
        .onTapGesture {
            store.select(key)
            store.pane = .sidebar
        }
    }
}

struct ThingsList: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let sel = store.appSelection
        let rows = store.listRows()
        VStack(alignment: .leading, spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ThingsTitle(sel: sel).id("top")
                        // the list sits in a frame; the new-to-do box is on top, where the newest to-do will appear
                        VStack(alignment: .leading, spacing: 0) {
                            if let target = store.adding {
                                AddRow(target: target, things: true).padding(.bottom, 4)
                            } else if sel != "*logbook" {
                                Button { store.startAdd() } label: { Label("New To-Do", systemImage: "plus") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                            }
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(rows) { row in
                                    ThingsRow(row: row).id(row.id)
                                }
                            }
                        }
                        .font(.system(size: 13))
                        .modifier(ListFrame())
                    }
                    .padding(.horizontal, 30).padding(.top, 24).padding(.bottom, 24)
                    .frame(maxWidth: 780, alignment: .leading)
                }
                .onChange(of: store.cursor) { _, c in
                    if let c { proxy.scrollTo(c) }
                }
                .onChange(of: store.adding) { _, a in   // ⌘N in a long list: back to the top, where the box is
                    if a != nil { withAnimation { proxy.scrollTo("top", anchor: .top) } }
                }
            }
            Divider()
            HStack {
                FocusPill()
                Spacer()
                Text("⌘N new · ⌘K done · ⌫ remove · ⇧↑↓ / ⌘-click / ⌘A select · ⌘Z undo · ↩ edit · ⌘↩ focus · ⌘O tray")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
    }
}

struct ThingsTitle: View {
    @EnvironmentObject var store: Store
    let sel: String

    var body: some View {
        let group = store.allGroups().first { $0.key == sel && $0.isFolder }
        let (icon, tint, title, sub): (String?, Color, String, String?) = {
            switch sel {
            case "*all": return ("checklist", .blue, "TODOs", "every open to-do, newest first · new ones go to General")
            case "*logbook": return ("checkmark.square.fill", .green, "Logbook", "⌘K reopens one")
            default:
                if let g = group {
                    let branch = g.sessions.compactMap(\.branch).first ?? g.tasks.compactMap(\.branch).first
                    return (nil, .primary, String(g.key.dropFirst(2)), branch.map(shortBranch))
                }
                return ("list.bullet", .secondary, sel, nil)
            }
        }()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).foregroundStyle(tint) }
                Text(title).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 21, weight: .bold))
            if let sub { Text(sub).font(.callout).foregroundStyle(.secondary) }
            if let g = group, !g.sessions.isEmpty { FlowChips(group: g).padding(.top, 4) }
        }
        .padding(.leading, 8).padding(.bottom, 14)
    }
}

struct ThingsRow: View {
    @EnvironmentObject var store: Store
    let row: Row

    var body: some View {
        let on = store.cursor == row.id || store.selection.contains(row.id)
        let active = store.pane == .list
        Group {
            switch row {
            case .task(let n), .about(let n):
                ThingsTodo(note: n)
            case .closed(let c):
                ThingsTodo(note: c)
            case .header(let t):
                VStack(alignment: .leading, spacing: 4) {
                    Text(t).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Divider()
                }
                .padding(.horizontal, 8).padding(.top, 14).padding(.bottom, 4)
            case .message(_, let m):
                Text(m).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 6)
            default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if !row.isCard && on { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(active ? 0.3 : 0.12)) }
        }
        .modifier(TodoCard(on: on, active: active, enabled: row.isCard))
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded {
            guard row.navigable else { return }
            store.click(row.id, NSEvent.modifierFlags)
            store.pane = .list
        })
    }
}

/// One to-do: a round checkbox, the text, and on the right the folder or list it's filed in.
struct ThingsTodo: View {
    @EnvironmentObject var store: Store
    let note: Note

    var body: some View {
        let closed = note.state != .open
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { closed ? store.reopen(note) : store.complete(note) } label: {
                Image(systemName: closed ? (note.state == .done ? "checkmark.circle.fill" : "xmark.circle") : "circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help(closed ? "Reopen (⌘K)" : "Done (⌘K)")
            if store.editingID == note.id {
                EditField()
            } else {
                (Text(note.isAbout ? "⏯ " : "").foregroundColor(.orange) + Text(note.text))
                    .strikethrough(note.state == .removed)
                    .foregroundStyle(closed ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(note.group.hasPrefix("~/") ? String(note.group.dropFirst(2)) : note.group)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .trailing)
            if closed, let at = note.closedAt {
                Text(Report.hm.string(from: at)).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .onTapGesture(count: 2) { if !closed { store.beginEdit(note) } }
    }
}
