import AppKit
import Carbon
import Combine
import SwiftUI

final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let store = Store()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hotKey: HotKey?
    private var ticker: Timer?
    private var pulseTimer: Timer?
    private var keyMonitor: Any?
    private var appWindow: NSWindow?
    private var capturePanel: CapturePanel?
    private var settingsWindow: NSWindow?
    private var captureModel: CaptureModel?
    private var previousApp: NSRunningApplication?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(togglePopover)
            b.imagePosition = .imageLeading
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 400, height: 600)
        popover.contentViewController = NSHostingController(rootView: PopoverView().environmentObject(store))

        store.onOpenCapture = { [weak self] fromEnd in self?.openCapture(fromEnd: fromEnd) }
        store.onTimeUp = { [weak self] in self?.timeUp() }
        store.onClosePopover = { [weak self] in self?.popover.performClose(nil) }
        store.onOpenApp = { [weak self] in self?.openFromTray() }
        store.onOpenSettings = { [weak self] in self?.openSettings() }
        installMainMenu()
        store.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateStatus() }
            .store(in: &cancellables)
        store.$pane
            .receive(on: DispatchQueue.main)
            .sink { [weak self] p in self?.paneChanged(p) }
            .store(in: &cancellables)

        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.openCapture(fromEnd: false)
        }
        NSLog("titi: global shortcut ⌥⌘N %@", hotKey == nil ? "FAILED to register" : "registered")

        // Every key goes through here before any view sees it: the app window's panes, the popover list and the
        // "Project" picker.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self else { return ev }
            if ev.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, ev.charactersIgnoringModifiers == ",",
               ev.window !== self.capturePanel {
                self.openSettings()
                return nil
            }
            if let w = self.appWindow, ev.window === w {
                if self.store.caretToEnd, let editor = w.firstResponder as? NSTextView {
                    editor.moveToEndOfDocument(nil)
                    self.store.caretToEnd = false
                }
                self.store.pageHeight = w.contentView?.bounds.height ?? 600
                // the store first, so ⌘Z means "undo the last todo change" outside text fields
                if self.store.handleAppKey(ev, textEditing: w.firstResponder is NSText) { return nil }
                return self.handleEditingShortcut(ev) ? nil : ev
            }
            let cmdO = ev.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                && ev.charactersIgnoringModifiers == "o"
            if let panel = self.capturePanel, ev.window === panel, let model = self.captureModel {
                if cmdO { return nil }   // ⌘O does nothing while you write a quick note
                if self.handleEditingShortcut(ev) { return nil }
                return model.handleKey(ev) ? nil : ev
            }
            if self.handleEditingShortcut(ev) { return nil }
            if self.popover.isShown, ev.window === self.popover.contentViewController?.view.window {
                if cmdO {
                    self.openFromTray()
                    return nil
                }
                return self.store.handleKey(ev) ? nil : ev
            }
            return ev
        }

        store.reloadNotes()
        store.refresh()
        store.detectContext()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.store.tick()
        }
        updateStatus()
    }

    // MARK: menu bar icon

    private func updateStatus() {
        guard let b = statusItem?.button else { return }
        let f = store.focus
        let mins = Int((f.remaining / 60).rounded(.up))
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        switch f.mode {
        case .idle:
            let img = NSImage(systemSymbolName: "circle.dotted", accessibilityDescription: "titi")
            img?.isTemplate = true
            b.image = img
            let n = store.aboutNotes.count
            b.attributedTitle = NSAttributedString(string: n > 0 ? " \(n)" : "", attributes: [.font: font])
            setPulse(false)
        case .running, .timeUp:
            b.image = nil
            b.attributedTitle = NSAttributedString(string: "● \(mins)m",
                                                   attributes: [.foregroundColor: NSColor.systemRed, .font: font])
            setPulse(true)
        case .paused:
            b.image = nil
            b.attributedTitle = NSAttributedString(string: "⏸ \(mins)m",
                                                   attributes: [.foregroundColor: NSColor.systemOrange, .font: font])
            setPulse(false)
        }
    }

    /// Red fade in/out while focusing.
    private func setPulse(_ on: Bool) {
        if on, pulseTimer == nil {
            let start = Date()
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                let fast = self?.store.focus.mode == .timeUp
                let period = fast ? 0.7 : 2.4
                let t = Date().timeIntervalSince(start)
                self?.statusItem.button?.alphaValue = CGFloat(0.64 + 0.36 * cos(2 * .pi * t / period))
            }
        } else if !on, let t = pulseTimer {
            t.invalidate()
            pulseTimer = nil
            statusItem.button?.alphaValue = 1
        }
    }

    // MARK: popover

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    /// `keepCursor`: coming back from the window with ⌘O, so you land where you were.
    private func showPopover(tab: Tab? = nil, keepCursor: Bool = false) {
        guard let b = statusItem.button else { return }
        if let tab { store.tab = tab }
        store.reloadNotes()
        store.detectContext()
        if Date().timeIntervalSince(store.scannedAt) > 120 { store.refresh() }
        if !keepCursor { store.cursor = nil }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        store.popoverOpenCount += 1
    }

    private func timeUp() {
        NSSound(named: NSSound.Name("Glass"))?.play()
        if capturePanel == nil { showPopover(tab: .focus) }
    }

    // MARK: app window

    /// ⌘O cycles tray → app → Things-style to-do list → tray, keeping the filter text, cursor and the timer.
    @objc func toggleWindow() {
        guard let w = appWindow, w.isVisible else { return openFromTray() }
        if store.windowMode == .app { store.enterThings() } else { backToTray() }
    }

    private func backToTray() {
        guard let w = appWindow else { return }
        store.query = store.appQuery
        store.cursorForTray()
        store.tab = store.appSelection == "*focus" ? .focus : .active
        store.editingID = nil
        store.adding = nil
        w.performClose(nil)
        // closing the window makes us an accessory app again; show the popover once that has settled
        DispatchQueue.main.async { self.showPopover(keepCursor: true) }
    }

    @objc func newTodo() {
        if appWindow?.isVisible != true { openAppWindow() }
        store.startAdd()
    }

    @objc func freezeReport() {
        if appWindow?.isVisible != true { openAppWindow() }
        store.freezeReport()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleWindow) {
            item.title = appWindow?.isVisible != true ? "Open the titi Window"
                : store.windowMode == .app ? "Switch to the To-Do List" : "Back to the Tray"
        }
        return true
    }

    /// The first ⌘O (or "Open app" in the popover): the cycle starts at the app view.
    private func openFromTray() {
        store.windowMode = .app
        openAppWindow()
    }

    /// Shows the window in whichever view it was last in (app or to-do list).
    @objc func openAppWindow() {
        if popover.isShown {
            // carry the popover's place over: its filter becomes the search, its cursor stays on the same row
            if !store.query.isEmpty {
                store.appQuery = store.query
                store.query = ""
                store.pane = .search
            } else {
                store.enterFromTray(cursor: store.cursor)
            }
        }
        popover.performClose(nil)
        if appWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 660),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "titi"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentViewController = NSHostingController(rootView: WindowRoot().environmentObject(store))
            w.setContentSize(NSSize(width: 1080, height: 660))
            w.center()
            w.setFrameAutosaveName("TitiMain")
            appWindow = w
        }
        store.reloadNotes()
        store.detectContext()
        if Date().timeIntervalSince(store.scannedAt) > 120 { store.refresh() }
        // a real app while the window is open: Dock icon and ⌘Tab
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        appWindow?.makeKeyAndOrderFront(nil)
    }

    /// ⌘, or ⚙︎ in the tray: the notes folder.
    @objc func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "titi Settings"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(store))
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === appWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Back in the window after editing a file in Sublime: read the notes again.
    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === appWindow { store.reloadNotes() }
    }

    /// Keeps the keyboard where the pane says: out of the search field when you Tab away, and with the caret at
    /// the end of the query when you come back (a field that gets focus selects all its text).
    private func paneChanged(_ p: Pane) {
        guard let w = appWindow, w.isVisible else { return }
        if p == .search {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if let editor = w.firstResponder as? NSTextView { editor.moveToEndOfDocument(nil) }
            }
        } else if store.editingID == nil, store.adding == nil, w.firstResponder is NSText {
            w.makeFirstResponder(nil)
        }
    }

    /// Clicking the Dock icon brings the window back as it was; it never changes the view.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let w = appWindow, w.isVisible {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else {
            openAppWindow()
        }
        return false
    }

    /// ⌘X/C/V/A/Z for every text field, even in the non-activating quick-note panel.
    private func handleEditingShortcut(_ ev: NSEvent) -> Bool {
        let mods = ev.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift],
              let ch = ev.charactersIgnoringModifiers?.lowercased() else { return false }
        let action: Selector?
        switch ch {
        case "x": action = #selector(NSText.cut(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "v": action = #selector(NSText.paste(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        case "z": action = mods.contains(.shift) ? Selector(("redo:")) : Selector(("undo:"))
        default: action = nil
        }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let open = appMenu.addItem(withTitle: "Open the titi Window", action: #selector(toggleWindow), keyEquivalent: "o")
        open.target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit titi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Todo Here", action: #selector(newTodo), keyEquivalent: "n").target = self
        file.addItem(withTitle: "Freeze Today's Report", action: #selector(freezeReport), keyEquivalent: "s").target = self
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    // MARK: quick note

    private func openCapture(fromEnd: Bool) {
        popover.performClose(nil)
        if let p = capturePanel {
            p.makeKeyAndOrderFront(nil)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        store.pauseForCapture()

        let model = CaptureModel(store: store, fromEnd: fromEnd, context: store.lastContext)
        model.onDone = { [weak self] in self?.closeCapture() }
        captureModel = model

        let size = NSSize(width: 560, height: model.showAbout ? 380 : 330)
        let panel = CapturePanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CaptureView(model: model))
        panel.center()
        capturePanel = panel

        // Non-activating, like Spotlight: takes the keyboard without pulling the app (or you) out of iTerm/Teams.
        panel.makeKeyAndOrderFront(nil)

        // Which iTerm tab were you in? (shown under the Project field as "Where you were")
        DispatchQueue.global(qos: .userInitiated).async {
            let ctx = Discovery.frontContext()
            DispatchQueue.main.async {
                self.store.lastContext = ctx
                if self.store.focus.mode == .paused, let tty = ctx?.tty { self.store.focus.resumeTTY = tty }
                model.setDetected(ctx)
            }
        }
    }

    private func closeCapture() {
        capturePanel?.orderOut(nil)
        capturePanel = nil
        captureModel = nil
        previousApp?.activate(options: [])
        previousApp = nil
    }
}
