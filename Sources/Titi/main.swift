import AppKit

// `Titi --selftest` checks discovery, the notes files and the window's keys without any UI.
if CommandLine.arguments.contains("--selftest") {
    // never against your real notes: a fresh scratch folder unless TITI_NOTES_DIR names one
    if ProcessInfo.processInfo.environment["TITI_NOTES_DIR"] == nil {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("titi-selftest-" + UUID().uuidString)
        setenv("TITI_NOTES_DIR", tmp.path, 1)
    }
    SelfTest.run()
    exit(0)
}

// `Titi --report [YYYY-MM-DD]` prints that workday's report (try `| claude -p "5-line summary"`).
if let i = CommandLine.arguments.firstIndex(of: "--report") {
    Report.printCLI(CommandLine.arguments.dropFirst(i + 1).first)
    exit(0)
}

Migration.settings()
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
