import SwiftUI

/// ⌘, or ⚙︎ in the tray: where the notes live. Choosing a new folder moves them there, after asking.
struct SettingsView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let fromEnv = Config.notesDirFromEnv != nil
        VStack(alignment: .leading, spacing: 10) {
            Text("Notes folder").font(.headline)
            Text("Every quick note, todo and report is a Markdown file in here.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(tildify(store.notesFolder.path)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            HStack {
                Button("Choose…") { chooseFolder() }.disabled(fromEnv)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.notesFolder]) }
                Spacer()
            }
            Text(fromEnv ? "Set by TITI_NOTES_DIR; unset it to choose a folder here."
                 : "Choosing a folder moves your notes there: open ones, project folders, done/, removed/ and reports/. "
                    + "Nothing is overwritten or deleted.")
                .font(.caption).foregroundStyle(fromEnv ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 480)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Notes Here"
        panel.message = "Pick the new notes folder. Your notes move there."
        panel.directoryURL = store.notesFolder.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)   // an accessory app's panel can open behind iTerm otherwise
        guard panel.runModal() == .OK, let new = panel.url else { return }

        let old = store.notesFolder
        if let p = NotesFS.problem(movingFrom: old, to: new) { return alert("Can't use that folder", p) }
        let count = NotesFS.countNotes(in: old)
        let there = NotesFS.countNotes(in: new)
        let confirm = NSAlert()
        confirm.messageText = "Move \(count) notes to \(tildify(new.path))?"
        confirm.informativeText = "Everything in \(old.lastPathComponent) moves there: open notes, project folders, "
            + "done/, removed/ and reports/. Hidden files like .git stay where they are."
            + (there > 0 ? "\n\n\(there) Markdown files are already there. They stay, and their open “- [ ]” lines "
                + "will show up as todos too. A file with the same name is never overwritten; yours arrives as “(2)”."
               : "")
            + "\n\nNothing is deleted."
        confirm.addButton(withTitle: "Move")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.moveNotes(to: new)
        } catch {
            alert("Couldn't move the notes", error.localizedDescription + "\n\nAny notes already moved were put back.")
        }
    }

    private func alert(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.runModal()
    }
}
