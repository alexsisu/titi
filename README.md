# titi

A macOS menu-bar app for coding work that keeps getting interrupted. It answers "where was I?", captures notes in a
couple of seconds, and runs a focus timer. Everything is tied to the folders where Claude and Codex sessions run.

**Status: early.** It exists to try the flows and refine them. Session discovery, notes, the timer, the shortcut and
iTerm tab switching are real. For a tour of the screens and every shortcut, see [docs/design-brief.md](docs/design-brief.md).

## Build and run

```sh
scripts/package.sh                # build and pack dist/Titi.app (drag it to /Applications to install)
scripts/run.sh                    # pack and (re)start it in the background; log in ~/Library/Logs/titi.log
TITI_FAST=1 scripts/run.sh        # focus timer 20x faster (20 min = 60 s)
dist/Titi.app/Contents/MacOS/Titi --selftest   # discovery report + notes round-trip + window keys, no UI
dist/Titi.app/Contents/MacOS/Titi --report     # today's report on stdout (or --report 2026-10-24)
dist/Titi.app/Contents/MacOS/Titi --report | claude -p "5-line summary of my day"
```

`--selftest` writes and moves notes, so it always uses a fresh scratch folder (or an empty `TITI_NOTES_DIR`) and
refuses a folder that already has notes. It never saves settings.

Needs only the Xcode Command Line Tools (Swift 6, macOS 14+). The app is ad-hoc signed: the first iTerm action makes
macOS ask for permission to control iTerm2, and a rebuilt app may ask again.

titi used to be called clomodoro. On its first launch it copies the old settings (your lists, hidden folders, the
window's view, the notes folder); the old ones stay.

## Your folders

The folders titi always shows, and the side projects it watches for "gone quiet", live on your Mac, not in the code:
`~/Library/Application Support/Titi/folders.json`.

```json
{
  "hot": ["~/code/acme-api", "~/code/acme-web"],
  "watched": ["~/code/old-side-project"]
}
```

Folders with a live Claude or Codex session, or with a todo, show up on their own. Restart titi after editing the file.

## What it does

- **Menu bar icon:** a dotted circle with the number of open "I was about to…" notes. While focusing it shows `● 17m` in
  red and pulses. When paused it shows `⏸ 12m` in orange.
- **Active items** (the popover's first tab):
  - Type in the filter box to narrow the list. Use ↑↓ to move, → to open a folder, ← to close it, and ↩ to toggle a
    folder, focus a todo, or bring a session's tab forward. ⌘↩ on a folder brings its iTerm tab forward.
  - **Where you were** pins the open "I was about to…" lines at the top.
  - **Folders & lists** are newest first. A folder shows its todos, its live Claude/Codex sessions (click one to bring
    that iTerm tab forward) and a terminal button: it brings back the tab you most recently typed in, or opens a new
    tab already `cd`'ed into that folder.
  - **↻** rescans sessions, git and Claude/Codex history.
- **Focus** (second tab): pick a todo or type a goal, pick 15/20/25/45 minutes, and press Start. During a block you can
  choose I got interrupted, Resume (which brings back the iTerm tab), Nailed it (which ticks the todo) or Stop. When
  time is up: Nailed it, +10 min, or Not yet (which asks where you got to).
- **⌥⌘N quick note** (global shortcut): opens a capture box with the cursor already in the todo box (one todo per
  line). If a focus block is running, it pauses it and asks "You were about to…" first.
  - **Project** sits below the todos and defaults to **General**; your front iTerm session
    (`Claude | ~/code/acme-api`) is listed right below it.
  - **Tab** (or ⌘P) jumps there and Tab jumps back; Tab never types a tab. Type to filter, or type a new name to create
    a list. **↩** takes the highlighted match and saves. **Tab** takes it and stays on Project, so the next ↩ saves;
    ↓ opens the whole list again.
  - ⌘↩ saves. The "You were about to…" line always stays with the session you left.
- **⌘O cycles** tray → app → to-do list → tray. The filter text, the cursor and the timer carry over; back in the tray, the picked todo's folder opens.
- **The to-do list** (the second ⌘O) is the same window laid out like Things:
  - **The sidebar** shows **TODOs** and Logbook, then your folders (with a dot for a live Claude or Codex session) and
    your lists, General first.
  - **TODOs** is every open todo from every folder, newest first, each with its folder or list on the right.
  - **The right side** shows one big-title list with round checkboxes and **+ New To-Do** on top. It opens on the
    folder or list selected in the app, otherwise on TODOs. New todos from TODOs go into General.
  - **Keys:** the same as in the app, without search. ⌘1 is TODOs and ⌘2 is the Logbook. Tab moves between the
    sidebar and the list.
- **The app** (the first ⌘O) is laid out like Notational Velocity:
  - **The search bar** searches open and closed todos everywhere. **↩** creates the text as a todo only when nothing
    matches; otherwise it steps into the results, and **＋ Create** is the last row. New todos go into the selected
    folder or list, or into General when one of the views on top is selected.
  - **The sidebar** has these views on top:
    - **TODOs** (⌘1) is every open todo from every folder, newest first.
    - **Logbook** (⌘2) lists closed todos by day, with today's done count beside it.
    - **Focus** (⌘3) picks a todo and starts a block.

    Below them come your Lists (General first), Folders newest first (with dots for live Claude/Codex sessions), Going
    quiet and ◌ forgotten.
  - **Opening the window from the tray** lands where the tray's cursor was: a picked todo stays picked in TODOs, and a
    picked folder or session opens that folder. With nothing picked it opens on TODOs, or on Focus from the Focus tab.
  - **The right side** shows the selected view, list or folder. A folder's header has one chip per live session (click
    one to bring its tab forward) and "open terminal here".
  - **Keys:**
    - **Tab** / **⇧Tab** cycle search → sidebar → list.
    - **→** or **↩** go from the sidebar into the list. **←** goes back.
    - **↑↓** move within the focused part; **Page Up / Page Down** jump a screenful, **Home / End** go to the first
      or last row (in the list and in the sidebar, in both views).
    - **⌘N** adds a todo to the selected folder or list (an inline row: ↩ saves and starts another, esc stops). In a
      long list it scrolls back to the top, where the row appears.
    - **⇧↑↓** (or ⇧Page, ⇧Home/End, ⇧-click) selects a range; **⌘-click / ⌃-click** adds or drops single todos. ⌘K,
      Space and ⌫ act on all of them, and one ⌘Z undoes it all. **⌘A** selects every todo in the list
      (every line in the Logbook). Esc or a plain ↑↓ drops the selection.
    - **⌘K** (or Space) marks a todo done, or reopens a closed one.
    - **⌫** removes a todo after a confirmation box.
    - **⌘Z** undoes done, remove and reopen.
    - **↩** edits a todo, and **⌘↩** starts a focus block on it.
    - **⌘L** jumps to search.
    - Typing a letter outside the search bar starts a search.
  - **⌘S** (or the button on the Logbook) freezes today's report into `reports/YYYY-MM-DD.md` in the notes folder and copies
    it. The report covers what you did since 04:00: todos done, focus blocks, your git commits and what's still open. Freezing again overwrites the file,
    unless you edited it, in which case the new one is saved next to it. **✨ Narrate with claude -p** is optional and
    adds a short summary under the facts.
  - While the window is open, titi also has a Dock icon and shows up in ⌘Tab.
- **Settings** (⌘, or ⚙︎ Settings in the tray's footer) sets the notes folder. **Choose…** moves your notes into the
  folder you pick, after a confirmation that says how many notes move and how many are already there:
  - Everything visible moves: open notes, project folders, `done/`, `removed/` and `reports/`. Hidden items such as
    `.git` stay, and the old folder is left in place, empty.
  - Folders with the same name merge, and a file never overwrites another: yours arrives as "x (2).md". Nothing is
    deleted.
  - It's all or nothing: if one file can't move, the ones already moved go back and the setting doesn't change.
  - It refuses the same folder, a folder inside or around the current one, your home folder and `/`.
  - `TITI_NOTES_DIR`, when set, wins, and Settings only shows it.
- **Forgotten work:** the faint ◌ at the bottom right of the popover. It lists todos untouched for 21+ days, sessions
  idle for 2+ days, and quiet folders, each with revive and remove. Remove never deletes anything on disk.

## Notes on disk

Notes live in `~/work/ai_code/general_todos/` unless you pick another folder in Settings (or set
`TITI_NOTES_DIR`). There's one Markdown file per capture:

```
general_todos/
  2026-10-25 09-40 ask Dana about the invoices.md     ← General
  code_acme-api/2026-10-25 09-41 rerun the flaky test.md
  errands/2026-10-25 09-41 book the dentist.md         ← a list you created
  done/      ← a file moves here once nothing in it is open
  removed/   ← …or here, when the last open line was removed
  reports/   ← end-of-day reports (never read as todos)
```

Each line is a `- [ ]` todo. A small front-matter block records `filed_under`, `group`, `branch` and `captured_in`.
Closed lines keep a stamp: `- [x] text ✅ 2026-10-25 14:32` when done, `- [-] text ❌ 2026-10-25 14:32` when removed.
A line you tick in Sublime has no stamp, so the Logbook lists it under "Date unknown" and it never counts in a day's
report. A workday runs from 04:00 to 04:00.
Editing the files in Sublime is fine; the popover rereads them every time it opens. Until the folder has any notes,
the app shows a few in-memory demo todos, marked `demo`.

The "I was about to…" line always stays with the session you were in. The rest of the notes go wherever you file them,
so a capture can produce two files.

Focus blocks are logged to `~/Library/Application Support/Titi/focus-log.jsonl`.

## Ground rules

- The Markdown files are the only store. There's no database or sync, and no tags, due dates, priorities or nesting.
- Time comes only from git, sessions and the focus log, never from scheduling.
- Every view should answer "where was I?" or "what did I do?" at a glance.
- The report is built deterministically from the files; a model summary is an explicit, optional extra.
