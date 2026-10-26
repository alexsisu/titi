import SwiftUI

final class CaptureModel: ObservableObject {
    enum Field: Hashable { case target, about, notes }

    @Published var about = ""
    @Published var notes = ""
    @Published var query = "" {
        didSet {
            guard !suppress, field == .target else { return }
            showTargets = true
            hl = 0
        }
    }
    @Published var target: Target
    @Published var showTargets = false
    @Published var hl = 0
    @Published var field: Field?
    @Published var context: CaptureContext?

    let focusLine: String?
    let showAbout: Bool
    let fromEnd: Bool
    /// Where the keyboard starts: the todo box (or "You were about to…" when a focus block is running).
    let startField: Field
    /// False until the panel puts the keyboard in `startField`. Until then macOS may hand it to the first text
    /// field it finds; that must not open the "Project" list.
    var ready = false
    var onDone: (() -> Void)?
    private let store: Store
    private var suppress = false

    init(store: Store, fromEnd: Bool, context: CaptureContext?) {
        self.store = store
        self.fromEnd = fromEnd
        self.context = context
        let f = store.focus
        showAbout = f.mode != .idle
        if fromEnd {
            focusLine = "Time is up. Where did you get to on “\(f.goal)”?"
        } else if f.mode == .paused {
            focusLine = "⏸ Focus paused with \(fmtTime(f.remaining)) left on “\(f.goal)”"
        } else {
            focusLine = nil
        }
        startField = showAbout ? .about : .notes
        target = Self.general
        query = target.label
        field = startField
    }

    /// Todos always default to General; the active session is one keystroke away in the list.
    static let general = Target(group: "General", label: "General", sub: "default", section: "")

    func setDetected(_ c: CaptureContext?) {
        context = c
    }

    var filtered: [Target] {
        let all = store.captureTargets(context: context)
        let q = query.trimmed.lowercased()
        guard !q.isEmpty else { return all }
        var hits = all.filter { ($0.label + " " + ($0.sub ?? "")).lowercased().contains(q) }
        if !all.contains(where: { $0.label.lowercased() == q }) {
            let name = query.trimmed
            hits.append(Target(group: name, label: name, sub: nil, section: hits.isEmpty ? "" : "New", isNew: true))
        }
        return hits
    }

    /// Something to save: todo lines, or the "about to…" line.
    var hasContent: Bool { !notes.trimmed.isEmpty || (showAbout && !about.trimmed.isEmpty) }

    /// Takes a project and stays on "Project" with its list closed: ↩ now saves, Tab goes back to the todos.
    func pick(_ t: Target) {
        target = t
        showTargets = false
        setQuery(t.label)
    }

    func focusChanged(_ f: Field?) {
        guard ready else { return }
        field = f
        if f == .target {
            setQuery("")
            showTargets = true
            hl = 0
        } else if showTargets {
            showTargets = false
            setQuery(target.label)
        }
    }

    private func setQuery(_ s: String) {
        suppress = true
        query = s
        suppress = false
    }

    func save() {
        let lines = notes.split(separator: "\n")
            .map { String($0).trimmed.replacingOccurrences(of: #"^([-*•]|\d+[.)])\s*"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
        let ab = showAbout ? about.trimmed : ""
        if !ab.isEmpty || !lines.isEmpty {
            store.saveCapture(about: ab, lines: lines, target: target, context: context, fromEnd: fromEnd)
        }
        onDone?()
    }

    /// ⌘↩ save · esc cancel / close list · ↑↓ in the "Project" list, ↩ there picks and saves · ⌘P or Tab jumps to it.
    func handleKey(_ ev: NSEvent) -> Bool {
        let cmd = ev.modifierFlags.contains(.command)
        let shift = ev.modifierFlags.contains(.shift)
        switch ev.keyCode {
        case 48:   // Tab never types a tab: todos → Project → todos (⇧Tab goes the other way)
            switch field {
            case .target:
                // typed a filter? Tab takes the highlighted match, like autocomplete, and ↩ then saves
                if showTargets, !query.trimmed.isEmpty, filtered.indices.contains(hl) {
                    pick(filtered[hl])
                } else {
                    field = shift && showAbout ? .about : .notes
                }
            case .about:
                field = shift ? .target : .notes
            default:
                field = shift && showAbout ? .about : .target
            }
            return true
        case 36, 76:
            if cmd { save(); return true }
            guard field == .target else { return false }   // ↩ in the todo box is a new line
            if showTargets {
                let items = filtered
                if items.indices.contains(hl) { pick(items[hl]) }
            }
            if hasContent { save() } else { field = .notes }   // nothing written yet: back to the todo box
            return true
        case 53:
            if showTargets {
                showTargets = false
                setQuery(target.label)
                field = .notes
            } else {
                onDone?()
            }
            return true
        case 125:
            if !showTargets, field == .target {   // a project is picked: ↓ opens the whole list again
                setQuery("")
                showTargets = true
                hl = 0
                return true
            }
            guard showTargets else { return false }
            hl = min(hl + 1, max(filtered.count - 1, 0))
            return true
        case 126:
            guard showTargets else { return false }
            hl = max(hl - 1, 0)
            return true
        case 35 where cmd:
            field = .target
            return true
        default:
            return false
        }
    }
}

/// The quick note: you type straight away (each line is a todo, in General unless you pick another project), and
/// "Project" sits below the todos. Tab moves between them.
struct CaptureView: View {
    @ObservedObject var model: CaptureModel
    @FocusState private var focused: CaptureModel.Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let line = model.focusLine {
                Text(line).foregroundStyle(.orange).font(.callout)
            }
            if model.showAbout {
                Text("You were about to…  (stays with \(model.context?.label ?? "General"))")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("e.g. rerun the flaky checkout test before opening the PR", text: $model.about)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .about)
                    .onSubmit { model.field = .notes }
            }
            Text("Todos (each line becomes one)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.notes)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.07)))
                .focused($focused, equals: .notes)
                .frame(maxHeight: model.showTargets ? 64 : .infinity)

            HStack(spacing: 6) {
                Text("Project").foregroundStyle(.secondary)
                TextField("type to filter projects, or a new name to create a list", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .target)
                Text("Tab · ⌘P").font(.caption2).foregroundStyle(.secondary)
            }
            if model.showTargets {
                TargetList(model: model).frame(maxHeight: .infinity)
            }
            Group {
                if let c = model.context {
                    Text("Where you were: ") + toolText(c.label) + Text(c.branch.map { " · " + shortBranch($0) } ?? "")
                } else {
                    Text("Where you were: no iTerm session detected")
                }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                Text("⌘↩ save · Tab project, then ↩ saves · esc cancel").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.onDone?() }
                Button("Save") { model.save() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 560, height: model.showAbout ? 380 : 330)
        .onChange(of: model.field) { _, f in focused = f }
        .onChange(of: focused) { _, f in model.focusChanged(f) }
        .onAppear {
            // straight into the todo box, whatever text field macOS picked first
            for delay in [0.05, 0.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard !model.ready || focused == nil else { return }
                    model.field = model.startField
                    focused = model.startField
                    model.ready = true
                }
            }
        }
    }
}

struct TargetList: View {
    @ObservedObject var model: CaptureModel

    var body: some View {
        let items = model.filtered
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, t in
                        if !t.section.isEmpty && (i == 0 || items[i - 1].section != t.section) {
                            Text(t.section.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 2)
                        }
                        HStack(spacing: 6) {
                            if t.isNew {
                                Text("＋ Create list “\(t.label)”").foregroundStyle(.green)
                            } else {
                                toolText((t.section == "Active session" ? "● " : "") + t.label)
                                if let s = t.sub { Text(s).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(i == model.hl ? Color.accentColor.opacity(0.35) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { model.pick(t) }
                        .id(t.id)
                    }
                }
            }
            .onChange(of: model.hl) { _, h in if items.indices.contains(h) { proxy.scrollTo(items[h].id) } }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
