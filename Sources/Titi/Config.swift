import Foundation

/// Everything hard-coded for the mock lives here.
enum Config {
    static let home = FileManager.default.homeDirectoryForCurrentUser.path

    static let defaultNotesDir = home + "/work/ai_code/general_todos"
    /// Set when TITI_NOTES_DIR names the folder (the self-test's scratch folder): Settings can't change it then.
    static var notesDirFromEnv: String? { ProcessInfo.processInfo.environment["TITI_NOTES_DIR"] }

    /// Where every capture is written as a Markdown file: TITI_NOTES_DIR, else the folder picked in Settings,
    /// else the default.
    static var notesDir: URL {
        URL(fileURLWithPath: notesDirFromEnv ?? UserDefaults.standard.string(forKey: "notesDir") ?? defaultNotesDir,
            isDirectory: true)
    }

    static let supportDir = URL(fileURLWithPath: home + "/Library/Application Support/Titi", isDirectory: true)

    /// Your folders live on this Mac, not in the code: Application Support/Titi/folders.json, e.g.
    /// {"hot": ["~/code/api", "~/code/web"], "watched": ["~/code/old-side-project"]}
    private static let folders: [String: [String]] = {
        let url = supportDir.appendingPathComponent("folders.json")
        guard let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] else { return [:] }
        return o
    }()

    /// Folders always shown in the tray (if not quiet). Live Claude/Codex sessions add their folders on top.
    static var hotFolders: [String] { folders["hot"] ?? [] }

    /// Side projects checked for "gone quiet" (they surface in the hidden forgotten view).
    static var watchedFolders: [String] { folders["watched"] ?? [] }

    static let durations = [15, 20, 25, 45]
    static let defaultMinutes = 20

    /// A folder with no todos, no live session and no activity for this long counts as quiet.
    static let quietAfter: TimeInterval = 14 * 86400
    /// A todo untouched this long shows up in the forgotten view.
    static let forgottenTodoAfter: TimeInterval = 21 * 86400
    /// A live session with no terminal activity this long is "left open".
    static let staleSessionAfter: TimeInterval = 2 * 86400

    /// TITI_FAST=1 makes the focus timer run 20x faster (20 min in 60 s) for trying things out.
    static let speed: Double = ProcessInfo.processInfo.environment["TITI_FAST"] != nil ? 20 : 1
}

/// A workday runs from 04:00 to 04:00 on the wall clock, so late-night work still counts for the day it started.
/// (Wall clock, not "+4 hours": on a daylight-saving day midnight + 4h is 03:00 or 05:00.)
func workday(_ d: Date = Date()) -> Date {
    let cal = Calendar.current
    var day = cal.startOfDay(for: d)
    if cal.component(.hour, from: d) < 4 { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
    return cal.date(bySettingHour: 4, minute: 0, second: 0, of: day) ?? day
}

/// Where the workday that starts at `day` ends (23, 24 or 25 hours later).
func workdayEnd(_ day: Date) -> Date {
    workday(Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86400))
}

func expandTilde(_ p: String) -> String {
    p.hasPrefix("~/") ? Config.home + p.dropFirst(1) : p
}

func tildify(_ p: String) -> String {
    p.hasPrefix(Config.home + "/") ? "~" + p.dropFirst(Config.home.count) : p
}

func ago(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = Date().timeIntervalSince(d)
    if s < 60 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h" }
    return "\(Int(s / 86400))d"
}

func fmtTime(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.up)))
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// "you/fix-login" -> "fix-login": your own branch prefix (your macOS user name) is noise in a narrow column.
func shortBranch(_ b: String) -> String {
    let mine = NSUserName() + "/"
    return b.hasPrefix(mine) ? String(b.dropFirst(mine.count)) : b
}

/// Runs a command and returns stdout (empty on failure).
@discardableResult
func sh(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// 'it'\''s' for a zsh -c command line.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func mtime(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// titi used to be called clomodoro: its settings (your lists, hidden and revived folders, the window's view, the
/// notes folder) live under the old name. Copied once, at launch; a key already set here wins, the old ones stay.
enum Migration {
    static func settings(into d: UserDefaults = .standard,
                         from old: [String: Any]? = UserDefaults.standard.persistentDomain(forName: "Clomodoro")) {
        guard !d.bool(forKey: "migratedFromClomodoro") else { return }
        for (k, v) in old ?? [:] where d.object(forKey: k) == nil {
            d.set(v, forKey: k)
        }
        d.set(true, forKey: "migratedFromClomodoro")
    }
}
