# titi: design brief

This brief is for a design review. It describes what titi is, every screen, how each one behaves, and every keyboard
shortcut as built today. The questions we most want answered are at the end.

## What it is

titi is a macOS menu-bar app for a developer who runs several AI coding sessions at once (Claude Code and Codex, each
in its own iTerm tab, often several per project) and keeps getting interrupted. It answers three questions:

- **Where was I?** Which projects have live sessions, what was I about to do in each, and which tab do I go back to.
- **What do I need to do?** Todos captured in two seconds from anywhere, filed under a project or a list.
- **What did I do today?** Ticked todos, focus blocks and git commits, frozen into a daily report.

Everything is keyboard-first. The mouse works everywhere, but every action has a key.

**Ground rules (deliberate constraints):**

- Plain Markdown files are the only store: one file per capture, one `- [ ]` line per todo. No database or sync, and
  no tags, due dates, priorities or nesting. Editing the files in a text editor is normal and expected.
- Time comes from git, the sessions and the focus log, never from scheduling.
- Every view should answer "where was I?" or "what did I do?" at a glance.
- Nothing is ever deleted. "Remove" marks a line `- [-]`, and finished files move to `done/` or `removed/`.

**Vocabulary:**

- **Folder:** a project directory, such as `~/code/acme-api`. It's known because a session runs there, a todo is filed
  there, or you listed it.
- **List:** a named bucket for todos that aren't about a project ("errands", "reading"). **General** is the default
  list.
- **Session:** a live Claude or Codex process in an iTerm tab, found by scanning processes and tabs. Claude is shown in
  orange and Codex in blue.
- **"I was about to…":** a special line captured when you're interrupted mid-task. It stays with the session you left
  and is pinned in the tray.
- **Workday:** 04:00 to 04:00, so late-night work counts as the same day.

## The surfaces

titi has six surfaces: the menu-bar icon, the tray popover, the quick-note panel, one main window with two layouts,
Settings, and a report overlay. **⌘O cycles tray → app view → to-do list view → tray**, keeping the search text, the
selected row and the timer.

### 1. Menu-bar icon

- At rest: a ring with a dot in the middle ("you are here", design 1c), with the number of open "I was about to…"
  notes. The app icon is the same mark in cream on a green tile.
- During a focus block: `● 17m` in red, pulsing. Paused: `⏸ 12m` in orange.
- A click opens the tray.

### 2. Tray popover (click the icon)

It has three tabs.

**Active items** (the default tab) is a filterable tree:

- **Where you were** pins the open "I was about to…" lines at the top.
- **Folders & lists**, newest activity first. Each folder expands to show its todos, its live sessions (one chip per
  session; click it to bring that iTerm tab forward) and a terminal button. The terminal button brings back the tab you
  last typed in for that folder, or opens a new tab already `cd`'ed into it.
- A filter box on top. ↻ rescans sessions, git and history.
- **Footer:** "⤢ Open app", the ⌥⌘N hint, "⚙︎ Settings", a status line ("scanned 2m ago · 3 done · 1 focus today") and a
  faint ◌ that opens Forgotten work.

**Focus:** pick a todo or type a goal, pick 15, 20, 25 or 45 minutes, and press Start.

- During a block: *I got interrupted* (pauses and opens the quick note), *Resume* (brings the iTerm tab back),
  *Nailed it* (ticks the todo) or *Stop*.
- When time is up: *Nailed it*, *+10 min*, or *Not yet* (which asks where you got to).

**Forgotten work** (the ◌): todos untouched for 21+ days, sessions idle for 2+ days, and folders gone quiet. Each has
*revive* and *remove*; remove never deletes anything on disk.

### 3. Quick note: ⌥⌘N, global

A floating panel, like Spotlight, that takes the keyboard without pulling you out of the app you were in.

- **Todos box** first, with the cursor already in it. Each line becomes one todo.
- **Project** field below it. It defaults to **General**, and your front iTerm session (for example
  `Claude | ~/code/acme-api`) is one step away. Its list is grouped into Active session, Your lists, Running now and
  Recent projects. Typing filters the list; a new name offers "＋ Create list …".
- If a focus block is running, the panel pauses it and first asks "You were about to…". That line stays with the
  session you left, while the todos go wherever you file them.
- A line at the bottom shows "Where you were": the detected iTerm session and branch.

### 4. Main window: app view (the first ⌘O)

The layout is inspired by Notational Velocity: a search bar across the top, a sidebar, and a list.

- **The search bar** searches open and closed todos everywhere. Results come in two groups, *Open* and *Closed*, with
  matches highlighted, and a green *＋ Create "…" in General* row at the end. ↩ creates a todo only when nothing
  matches; otherwise it steps into the results.
- **The sidebar**, top to bottom:
  - the views: **TODOs** (⌘1), **Logbook** (⌘2, with "2 done today"), **Focus** (⌘3);
  - **Lists**, General first, with orange count badges;
  - **Folders**, newest first, with dots for live sessions (orange for Claude, blue for Codex) and the age of the last
    activity;
  - a collapsible *Going quiet* group and a faint *forgotten* link.
- **The list:**
  - Each todo is a card: checkbox, text, its folder or list (with the branch), age, an iTerm link and a ▶ focus button.
    The link and the button are faint until you hover or select the card.
  - The cards sit inside a light grey frame.
  - A folder's header has one chip per live session, plus "open terminal here".
- **TODOs** is every open todo from every folder, newest first. **Logbook** shows closed todos grouped by workday ("Today · 2
  done · 1 removed"); lines ticked outside titi have no date and go in a last group, "Date unknown".
- **Freeze report** (⌘S, or the button on the Logbook header) builds today's report, saves it, copies it to the
  clipboard, and shows it over the list (see 7).
- A one-line hint bar under the search bar lists the main keys. While the window is open, titi has a Dock icon and
  shows up in ⌘Tab.

### 5. Main window: to-do list view (the second ⌘O)

The same data, laid out like Things: calmer, with no search bar.

- **Sidebar:** TODOs and Logbook, then Folders (with session dots), then Lists.
- **Right side:**
  - a big title with an icon and a one-line subtitle;
  - a light grey frame holding **＋ New To-Do**, then one card per todo: a round checkbox, the text, and its folder or
    list on the right;
  - Logbook cards show the closing time.
- **Footer:** the focus status and a hint line of keys.
- It opens on whatever folder or list was selected in the app view, otherwise on TODOs.

### 6. Settings (⌘, or ⚙︎ in the tray)

One section, **Notes folder**: the current path, **Choose…** and **Show in Finder**.

- Choosing a folder moves the notes there, after a confirmation that says how many notes move and how many are already
  there.
- Same-named folders merge, and nothing is overwritten (a clash arrives as "x (2).md").
- It's all or nothing, and the old folder is left in place, empty.

### 7. Report overlay, confirmation box and toasts

- **Report:** today's report as Markdown over the list, with Copy, Open file and an optional "✨ Narrate with claude -p"
  that adds a short summary. Esc closes it.
- **Confirmation box:** removing todos always asks first; one box covers any number of selected todos. ↩ confirms, esc
  cancels.
- **Toasts:** short messages at the bottom of the window ("Saved to reports/2026-10-26.md and copied", "Moved 37 notes
  to …").

## Keyboard reference

### Global

| Key | Does |
|---|---|
| ⌥⌘N | Quick note, from any app |
| ⌘O | Cycle tray → app view → to-do list view → tray |
| ⌘, | Settings |

### Tray (Active items)

| Key | Does |
|---|---|
| type | Filter the tree |
| ↑ ↓ | Move |
| → / ← | Open / close a folder (← on a todo closes its folder) |
| ↩ | Toggle a folder · pick a todo for Focus (opens the Focus tab) · bring a session's tab forward |
| ⌘↩ on a folder | Bring its iTerm tab forward |
| esc | Clear the filter |

### Quick note

| Key | Does |
|---|---|
| ↩ (in the todos) | New line, which becomes a new todo |
| Tab / ⇧Tab | Todos ↔ Project (Tab never types a tab) |
| ⌘P | Jump to Project |
| type (in Project) | Filter projects; a new name offers "Create list" |
| ↑ ↓ | Move in the project list; ↓ on a picked project reopens the full list |
| ↩ (in Project) | Take the highlighted project and save. With no todos written yet, it goes back to the todo box instead |
| Tab (in Project, after typing) | Take the match and stay on Project, so the next ↩ saves |
| ⌘↩ | Save from anywhere |
| esc | Close the project list, or cancel |

### Main window (both views unless noted)

| Key | Does |
|---|---|
| Tab / ⇧Tab | Cycle search → sidebar → list (the to-do list view has only sidebar ↔ list) |
| ⌘1 / ⌘2 / ⌘3 | TODOs / Logbook / Focus (⌘3 only in the app view) |
| ⌘L | Jump to search (app view) |
| type a letter anywhere | Starts a search (app view) |
| ↑ ↓ | Move in the focused part; ↑ at the top of the sidebar goes back to search |
| Page Up / Page Down | Jump a screenful (list and sidebar) |
| Home / End | First / last row |
| → or ↩ in the sidebar | Into the list |
| ← in the list | Back to the sidebar |
| ↩ on a todo | Edit it inline (esc cancels) |
| ⌘N | New todo at the top of the list, filed into the selected folder or list (or General). ↩ saves and starts another; esc stops |
| ⌘K or Space | Done; on a closed line, reopen |
| ⌫ or ⌘⌫ | Remove, after a confirmation |
| ⌘Z | Undo done, remove or reopen (a batch undoes as one step) |
| ⌘↩ | Start a focus block on the todo |
| ⇧↑↓, ⇧Page, ⇧Home/End, ⇧-click | Select a range |
| ⌘-click / ⌃-click | Add or drop one todo |
| ⌘A | Select every todo in the list (every line in the Logbook); in the search bar it selects the text |
| esc | Drop the selection, then leave the list |
| ⌘S | Freeze today's report |

Mouse: a click selects a row, a double-click edits it, the checkbox ticks it, and the ▶ button starts a focus block.

## Visual language today

- Native SwiftUI on macOS 14, system font, light and dark mode.
- **List cards:** white (dark grey in dark mode) with an 8 pt radius, a hairline border, a faint shadow and 6 pt gaps,
  inside a light grey frame with a 12 pt radius. The selected card gets an accent tint and an accent border, fainter
  when the keyboard is in the sidebar.
- **Color carries meaning:** orange for Claude, blue for Codex, red for focus and the ▶ button, orange count badges, and
  green for "create".
- **Type sizes:** 13 pt in the list, a 21 pt bold title in the to-do list view, and captions for metadata (folder,
  branch, age).
- **Hint lines:** both views show a single long line of keys (in the app view under the search bar, in the to-do list
  view in the footer).

## Where we'd like feedback

1. **Two layouts of one window.** The app view (search-first, dense, with sessions) and the to-do list view (calm, like
   Things) both exist, and ⌘O cycles through them and the tray. Is that one surface too many? Should they merge, or
   should each have a sharper reason to exist?
2. **The tray versus the window.** The tray is a tree of folders with sessions; the window is flat lists. Do these feel
   like the same product?
3. **Cards at density.** With 40+ todos, do cards help scanning or slow it down? Would a compact mode or grouping by
   folder be better?
4. **"Where was I?"** The "I was about to…" lines, session dots, chips and "bring the tab back" are the core idea.
   Are they visible and trustworthy enough? What would make "go back to where I was" a one-glance, one-key thing?
5. **Shortcut discoverability.** The long hint lines are a stopgap. What would a better pattern be: a ⌘/ cheat sheet,
   hints on hover, or hints that change with context?
6. **The quick note.** The todos come first and the project second, and ↩ in Project saves. Does that flow feel right
   for capturing in two seconds?
7. **Color.** Orange and blue for tools, red for focus, and orange badges for counts: is the palette doing too much?
8. **Logbook and report.** Is "what did I do today" satisfying to look at? What would make the end-of-day report
   something you'd want to read?
9. **Empty and first-run states.** With no notes, the app shows a few demo todos marked "demo". What should the first
   five minutes feel like?

The constraints for any suggestion: macOS only, SwiftUI, a menu-bar app first. The files on disk stay plain Markdown.
