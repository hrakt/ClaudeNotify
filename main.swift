import Cocoa
import UniformTypeIdentifiers
import UserNotifications

// The flag file the Claude Code Stop hook checks. If this file exists, the
// completion sound is suppressed. Toggling the menu-bar item creates/removes it.
let flagURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/notifications-muted")

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/claudenotify")
let soundsDir = supportDir.appendingPathComponent("sounds")
let sessionSoundsDir = supportDir.appendingPathComponent("sessions")
let sessionVolumesDir = supportDir.appendingPathComponent("session-volumes")
let speakDir = supportDir.appendingPathComponent("speak")
let liveDir = supportDir.appendingPathComponent("live")
let ttyDir = supportDir.appendingPathComponent("ttys")
let terminalsDir = supportDir.appendingPathComponent("terminals")

// The hook cannot post a clickable notification itself: banners raised by
// osascript belong to Script Editor and ignore clicks. So it drops a file here
// and the app, which can handle a click, posts the banner.
let pendingDir = supportDir.appendingPathComponent("pending")
let notificationsBlockedURL = supportDir.appendingPathComponent("notifications-blocked")

// Which terminal a session runs in is a fact about that session, not a global
// preference: with work spread across Warp and Orca at once, one setting would
// be wrong for half the banners. The hook records `TERM_PROGRAM` per session and
// the click follows it, so nothing needs configuring and nothing can go stale.
struct TerminalApp {
    let name: String
    let bundleID: String
}

let terminalCatalog: [String: TerminalApp] = [
    "Orca": TerminalApp(name: "Orca", bundleID: "com.stablyai.orca"),
    "WarpTerminal": TerminalApp(name: "Warp", bundleID: "dev.warp.Warp-Stable"),
    "ghostty": TerminalApp(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
    "iTerm.app": TerminalApp(name: "iTerm", bundleID: "com.googlecode.iterm2"),
    "Apple_Terminal": TerminalApp(name: "Terminal", bundleID: "com.apple.Terminal"),
    "vscode": TerminalApp(name: "VS Code", bundleID: "com.microsoft.VSCode"),
    "Hyper": TerminalApp(name: "Hyper", bundleID: "co.zeit.hyper"),
    "kitty": TerminalApp(name: "kitty", bundleID: "net.kovidgoyal.kitty"),
    "alacritty": TerminalApp(name: "Alacritty", bundleID: "org.alacritty"),
]

// Sessions that predate terminal recording have no file to read, so the click
// keeps doing what it did before rather than doing nothing at all.
let legacyTerminal = TerminalApp(name: "Warp", bundleID: "dev.warp.Warp-Stable")

// Launched from Finder the app inherits a minimal PATH, so the CLI is found by
// looking rather than by name.
let orcaCLICandidates = [
    "/usr/local/bin/orca",
    "/opt/homebrew/bin/orca",
    "/Applications/Orca.app/Contents/Resources/bin/orca",
]

// SessionEnd removes a session from the registry, but a session killed outright
// never sends it, so a heartbeat this old is treated as dead.
let liveStaleWindow: TimeInterval = 24 * 60 * 60
let transcriptsDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/projects")

// Claude Code never reports which sessions are running, so recent transcript
// writes stand in for liveness. Old transcripts pile up (108 here, 5 of them
// from the last day), hence the window and the cap.
let sessionWindow: TimeInterval = 8 * 60 * 60
let sessionLimit = 8
let soundPointerURL = supportDir.appendingPathComponent("sound")
let volumePointerURL = supportDir.appendingPathComponent("volume")
let mutedUntilURL = supportDir.appendingPathComponent("muted-until")
let reminderMinutesURL = supportDir.appendingPathComponent("reminder-minutes")
let reminderLimitURL = supportDir.appendingPathComponent("reminder-limit")
let reminderChoices: [(title: String, minutes: Int)] = [
    ("Off", 0),
    ("Every 2 Minutes", 2),
    ("Every 5 Minutes", 5),
    ("Every 10 Minutes", 10),
    ("Every 30 Minutes", 30),
    ("Every Hour", 60),
]

// Reminders stop eventually by default: a session you walked away from for the
// day should not nag until midnight. Zero means keep going.
let defaultReminderLimit = 6
let reminderLimitChoices: [(title: String, limit: Int)] = [
    ("Stop After 3", 3),
    ("Stop After 6", 6),
    ("Stop After 12", 12),
    ("Never Stop", 0),
]
let muteDurations: [(title: String, minutes: Int)] = [
    ("15 Minutes", 15),
    ("30 Minutes", 30),
    ("1 Hour", 60),
    ("Until I Turn It Back On", 0),
]
let scriptURL = supportDir.appendingPathComponent("notify.sh")

let systemSoundsDir = URL(fileURLWithPath: "/System/Library/Sounds")
let defaultSound = systemSoundsDir.appendingPathComponent("Glass.aiff")
let audioExtensions: Set<String> = ["aiff", "aif", "wav", "mp3", "m4a", "caf", "aac"]

// Sounds macOS ships but never surfaces in System Settings. Browsing them keeps
// the app free of API keys, downloads and licence bookkeeping.
// Alert tones sit four directories deep, so they are flattened into one list;
// the interface sounds are already grouped into useful categories, so they keep
// their folder structure.
let extraSoundSources: [(title: String, url: URL, flatten: Bool)] = [
    ("Alert Tones",
     URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ToneLibrary.framework"),
     true),
    ("Interface Sounds",
     URL(fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds"),
     false),
]

// The Stop hook runs this script, so every behavior change ships by rewriting it
// here instead of by asking the user to re-edit ~/.claude/settings.json.
let scriptBody = """
#!/bin/bash
# Generated by ClaudeNotify. Do not edit: the app overwrites this file on launch.

PAYLOAD=""
if [ ! -t 0 ]; then
    PAYLOAD="$(cat)"
fi

SESSION_ID="${PAYLOAD##*\\"session_id\\":\\"}"
SESSION_ID="${SESSION_ID%%\\"*}"
case "$SESSION_ID" in
    ''|*[!0-9a-fA-F-]*) SESSION_ID="" ;;
esac

EVENT="${PAYLOAD##*\\"hook_event_name\\":\\"}"
EVENT="${EVENT%%\\"*}"
case "$EVENT" in
    SessionStart|SessionEnd|Stop|SubagentStop|Notification) ;;
    *) EVENT="Stop" ;;
esac

CWD="${PAYLOAD##*\\"cwd\\":\\"}"
CWD="${CWD%%\\"*}"
case "$CWD" in
    /*) ;;
    *) CWD="" ;;
esac

# The live registry is what makes the menu react to sessions opening and
# closing. It is maintained before the mute check on purpose: muting silences
# the ding, it should not blind the app to which sessions exist.
LIVE_DIR="$HOME/.claude/claudenotify/live"
TTY_DIR="$HOME/.claude/claudenotify/ttys"
TERMINAL_DIR="$HOME/.claude/claudenotify/terminals"
if [ -n "$SESSION_ID" ]; then
    mkdir -p "$LIVE_DIR" 2>/dev/null
    if [ "$EVENT" = "SessionEnd" ]; then
        rm -f "$LIVE_DIR/$SESSION_ID" "$TTY_DIR/$SESSION_ID" \\
            "$TERMINAL_DIR/$SESSION_ID"
        exit 0
    fi
    printf '%s' "$CWD" > "$LIVE_DIR/$SESSION_ID" 2>/dev/null

    # Which tty this session lives on. The hook is a descendant of the claude
    # process, so walking up the tree finds it. Only Orca can be driven to a
    # specific tab, so for every other terminal this is what lets you find the
    # right one by hand: run `tty` in a tab and compare.
    SESSION_TTY=""
    WALK_PID=$$
    for _ in 1 2 3 4 5 6; do
        WALK_INFO="$(ps -o ppid=,comm=,tty= -p "$WALK_PID" 2>/dev/null)"
        [ -z "$WALK_INFO" ] && break
        WALK_PARENT="$(printf '%s' "$WALK_INFO" | awk '{print $1}')"
        WALK_NAME="$(printf '%s' "$WALK_INFO" | awk '{print $2}')"
        WALK_TTY="$(printf '%s' "$WALK_INFO" | awk '{print $3}')"
        case "$WALK_NAME" in
            *claude)
                case "$WALK_TTY" in
                    ttys*) SESSION_TTY="$WALK_TTY" ;;
                esac
                break
                ;;
        esac
        [ -z "$WALK_PARENT" ] && break
        [ "$WALK_PARENT" = "1" ] && break
        WALK_PID="$WALK_PARENT"
    done
    if [ -n "$SESSION_TTY" ]; then
        mkdir -p "$TTY_DIR" 2>/dev/null
        printf '%s' "$SESSION_TTY" > "$TTY_DIR/$SESSION_ID" 2>/dev/null
    fi

    # Which terminal app owns this session, so the banner can raise that one
    # instead of a hardcoded guess. The hook is a descendant of the shell in the
    # tab, so it inherits the terminal's own environment. Orca additionally
    # hands out a per-tab handle, which is what lets the click land on the exact
    # tab rather than merely on the app.
    if [ -n "$TERM_PROGRAM" ]; then
        mkdir -p "$TERMINAL_DIR" 2>/dev/null
        printf '%s\\n%s\\n' "$TERM_PROGRAM" "$ORCA_TERMINAL_HANDLE" \\
            > "$TERMINAL_DIR/$SESSION_ID" 2>/dev/null
    fi

    if [ "$EVENT" = "SessionStart" ]; then
        exit 0
    fi
fi

test -f "$HOME/.claude/notifications-muted" && exit 0

# A timed mute expires on its own: once the deadline passes the file is removed
# here, so sound returns even if the app is not running.
MUTED_UNTIL_FILE="$HOME/.claude/claudenotify/muted-until"
if [ -f "$MUTED_UNTIL_FILE" ]; then
    MUTED_UNTIL="$(cat "$MUTED_UNTIL_FILE")"
    case "$MUTED_UNTIL" in
        ''|*[!0-9]*) rm -f "$MUTED_UNTIL_FILE" ;;
        *)
            if [ "$(date +%s)" -lt "$MUTED_UNTIL" ]; then
                exit 0
            fi
            rm -f "$MUTED_UNTIL_FILE"
            ;;
    esac
fi

SOUND="/System/Library/Sounds/Glass.aiff"
POINTER="$HOME/.claude/claudenotify/sound"
if [ -f "$POINTER" ]; then
    CHOSEN="$(cat "$POINTER")"
    if [ -n "$CHOSEN" ] && [ -f "$CHOSEN" ]; then
        SOUND="$CHOSEN"
    fi
fi

if [ -n "$SESSION_ID" ]; then
    SESSION_SOUND="$HOME/.claude/claudenotify/sessions/$SESSION_ID"
    if [ -f "$SESSION_SOUND" ]; then
        CHOSEN_SESSION="$(cat "$SESSION_SOUND")"
        if [ -n "$CHOSEN_SESSION" ] && [ -f "$CHOSEN_SESSION" ]; then
            SOUND="$CHOSEN_SESSION"
        fi
    fi
fi

VOLUME="1"
VOLUME_POINTER="$HOME/.claude/claudenotify/volume"
if [ -f "$VOLUME_POINTER" ]; then
    CHOSEN_VOLUME="$(cat "$VOLUME_POINTER")"
    case "$CHOSEN_VOLUME" in
        ''|*[!0-9.]*) ;;
        *) VOLUME="$CHOSEN_VOLUME" ;;
    esac
fi

if [ -n "$SESSION_ID" ]; then
    SESSION_VOLUME="$HOME/.claude/claudenotify/session-volumes/$SESSION_ID"
    if [ -f "$SESSION_VOLUME" ]; then
        CHOSEN_SESSION_VOLUME="$(cat "$SESSION_VOLUME")"
        case "$CHOSEN_SESSION_VOLUME" in
            ''|*[!0-9.]*) ;;
            *) VOLUME="$CHOSEN_SESSION_VOLUME" ;;
        esac
    fi
fi

afplay -v "$VOLUME" "$SOUND" 2>/dev/null

# The session's own name says more than "Claude is done", so it is resolved
# once here and reused by both the announcement and the banner.
TRANSCRIPT="${PAYLOAD##*\\"transcript_path\\":\\"}"
TRANSCRIPT="${TRANSCRIPT%%\\"*}"
SESSION_TITLE=""
case "$TRANSCRIPT" in
    /*.jsonl)
        if [ -f "$TRANSCRIPT" ]; then
            SESSION_TITLE="$(tail -c 200000 "$TRANSCRIPT" | grep -o '"aiTitle":"[^"]*"' | tail -1 | cut -d'"' -f4)"
        fi
        ;;
esac

PROJECT="${CWD##*/}"
SESSION_LABEL="$SESSION_TITLE"
if [ -n "$PROJECT" ] && [ -n "$SESSION_TITLE" ]; then
    SESSION_LABEL="$PROJECT: $SESSION_TITLE"
elif [ -n "$PROJECT" ]; then
    SESSION_LABEL="$PROJECT"
fi

# Speaking the session name is opt-in per session: hearing every session
# announce itself all day is worse than a ding.
if [ -n "$SESSION_ID" ] && [ -f "$HOME/.claude/claudenotify/speak/$SESSION_ID" ]; then
    SPOKEN="$SESSION_TITLE"
    if [ -z "$SPOKEN" ]; then
        SPOKEN="Claude"
    fi
    SPOKEN="$(printf '%s' "$SPOKEN" | tr '-' ' ')"

    # Two sessions finishing together would talk over each other, so whoever
    # gets the lock speaks and the other just dings.
    SPEAK_LOCK="$HOME/.claude/claudenotify/speak.lock"
    if [ -d "$SPEAK_LOCK" ] && [ -z "$(find "$SPEAK_LOCK" -maxdepth 0 -mmin -2 2>/dev/null)" ]; then
        rmdir "$SPEAK_LOCK" 2>/dev/null
    fi
    if mkdir "$SPEAK_LOCK" 2>/dev/null; then
        say -r 220 "$SPOKEN finished" 2>/dev/null
        rmdir "$SPEAK_LOCK" 2>/dev/null
    fi
fi

# Preferred path: hand the banner to the app, which can name the session and
# handle a click. The blocked marker exists when macOS refused the app
# permission, in which case the plain banner is better than none.
if [ -n "$SESSION_ID" ] \\
    && [ ! -f "$HOME/.claude/claudenotify/notifications-blocked" ] \\
    && pgrep -f "ClaudeNotify.app/Contents/MacOS/ClaudeNotify" >/dev/null 2>&1; then
    mkdir -p "$HOME/.claude/claudenotify/pending" 2>/dev/null
    printf '%s' "$SESSION_LABEL" > "$HOME/.claude/claudenotify/pending/$SESSION_ID"
else
    SAFE_LABEL="$(printf '%s' "${SESSION_LABEL:-Claude Code}" | tr -cd 'A-Za-z0-9 .,:_/#-')"
    osascript -e "display notification \\"Finished\\" with title \\"Claude Code\\" subtitle \\"$SAFE_LABEL\\"" 2>/dev/null || true
fi

"""

final class SessionVolumeSlider: NSSlider {
    var sessionID: String = ""
}

struct SessionInfo {
    let id: String
    let title: String
    let project: String
    let modified: Date
}

struct SessionTerminal {
    let program: String
    let handle: String

    // An unrecognised TERM_PROGRAM is not a failure: the session still names its
    // terminal in the menu, it just cannot be raised by bundle id.
    var app: TerminalApp? { terminalCatalog[program] }
    var displayName: String { app?.name ?? program }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!
    var preview: NSSound?

    // Kept off the status item until a right-click asks for it, so a plain left
    // click can toggle mute instead of opening a menu.
    let mainMenu = NSMenu()
    var pendingWatcher: DispatchSourceFileSystemObject?
    var settingsWindow: NSWindow?
    var soundRows: [(name: String, group: String, url: URL)] = []
    var soundTable: NSTableView?
    var settingsVolumeSlider: NSSlider?
    var settingsVolumeLabel: NSTextField?
    var settingsMuteCheckbox: NSButton?
    var settingsCadencePopup: NSPopUpButton?
    var settingsRepeatsPopup: NSPopUpButton?
    var lastReminded: [String: Date] = [:]
    var reminderCounts: [String: Int] = [:]

    var isPermanentlyMuted: Bool { FileManager.default.fileExists(atPath: flagURL.path) }

    // Expired deadlines are cleared on read so a stale file cannot keep the bell
    // looking muted after the timer has run out.
    var mutedUntil: Date? {
        guard let raw = try? String(contentsOf: mutedUntilURL, encoding: .utf8),
              let epoch = TimeInterval(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let deadline = Date(timeIntervalSince1970: epoch)
        guard deadline > Date() else {
            try? FileManager.default.removeItem(at: mutedUntilURL)
            return nil
        }
        return deadline
    }

    var isMuted: Bool { isPermanentlyMuted || mutedUntil != nil }

    var volumeLabelItem: NSMenuItem?

    var currentVolume: Double {
        guard let raw = try? String(contentsOf: volumePointerURL, encoding: .utf8),
              let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 1.0
        }
        return min(max(value, 0.1), 1.0)
    }

    var selectedSound: URL {
        guard let raw = try? String(contentsOf: soundPointerURL, encoding: .utf8) else {
            return defaultSound
        }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return defaultSound }
        return URL(fileURLWithPath: path)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSupportFiles()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        mainMenu.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        rebuildMenu()
        updateUI()

        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateUI()
            self?.checkReminders()
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            NSLog("ClaudeNotify: notification authorization granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            DispatchQueue.main.async { self?.recordNotificationPermission(granted) }
        }
        startWatchingPending()
        drainPending()
    }

    func startWatchingPending() {
        let descriptor = open(pendingDir.path, O_EVTONLY)
        guard descriptor >= 0 else {
            NSLog("ClaudeNotify: could not watch \(pendingDir.path)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write],
            queue: .main)
        source.setEventHandler { [weak self] in self?.drainPending() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        pendingWatcher = source
    }

    // The script reads this marker and falls back to its own plain banner, so a
    // refusal by macOS costs the click and the styling, never the notification.
    func recordNotificationPermission(_ granted: Bool) {
        let fm = FileManager.default
        if granted {
            try? fm.removeItem(at: notificationsBlockedURL)
        } else {
            try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)
            fm.createFile(atPath: notificationsBlockedURL.path, contents: nil)
        }
    }

    func drainPending() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: pendingDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return }

        for file in files {
            let sessionID = file.lastPathComponent
            let label = (try? String(contentsOf: file, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            try? fm.removeItem(at: file)
            postFinishedNotification(for: sessionID, label: label)
        }
    }

    func describeSession(_ sessionID: String) -> String {
        let cwd = (try? String(contentsOf: liveDir.appendingPathComponent(sessionID), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var project = (cwd?.isEmpty == false) ? URL(fileURLWithPath: cwd!).lastPathComponent : ""
        var title = ""

        if let transcript = transcriptURL(for: sessionID) {
            let text = tailText(of: transcript) ?? ""
            title = lastJSONValue("aiTitle", in: text) ?? ""
            if project.isEmpty, let recorded = lastJSONValue("cwd", in: text) {
                project = URL(fileURLWithPath: recorded).lastPathComponent
            }
        }

        if !project.isEmpty && !title.isEmpty { return "\(project) · \(title)" }
        if !title.isEmpty { return title }
        if !project.isEmpty { return project }
        return "Claude Code"
    }

    // Every failure path ends in a visible banner. Permission can be refused at
    // launch, revoked later, or the post itself can fail, and none of those may
    // result in silence: the app raises its own plain banner instead.
    func postFinishedNotification(for sessionID: String, label: String? = nil, reminder: String? = nil) {
        let resolved = (label?.isEmpty == false) ? label! : describeSession(sessionID)

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }

            guard settings.authorizationStatus == .authorized else {
                DispatchQueue.main.async {
                    self.recordNotificationPermission(false)
                    self.postFallbackBanner(resolved, reminder: reminder)
                }
                return
            }

            // The body promises only what the click can deliver: an unknown
            // terminal cannot be raised, so it is named rather than offered.
            let destination: String
            switch self.sessionTerminal(sessionID) {
            case .none:
                destination = "Click to switch to your terminal."
            case .some(let record) where record.app == nil:
                destination = "This session is in \(record.displayName)."
            case .some(let record) where record.program == "Orca" && !record.handle.isEmpty:
                destination = "Click to open this tab in \(record.displayName)."
            case .some(let record):
                destination = "Click to switch to \(record.displayName)."
            }

            let content = UNMutableNotificationContent()
            content.title = reminder == nil ? "Claude finished" : "Claude still waiting"
            content.subtitle = resolved
            content.body = reminder.map { "\($0). \(destination)" } ?? destination
            content.userInfo = ["session": sessionID]

            let request = UNNotificationRequest(
                identifier: "\(sessionID)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil)

            UNUserNotificationCenter.current().add(request) { error in
                guard let error else { return }
                NSLog("ClaudeNotify: could not post notification: \(error.localizedDescription)")
                DispatchQueue.main.async { self.postFallbackBanner(resolved, reminder: reminder) }
            }
        }
    }

    func postFallbackBanner(_ label: String, reminder: String? = nil) {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,:_/#-")
        let safe = String(label.filter { allowed.contains($0) })
        let body = String((reminder ?? "Finished").filter { allowed.contains($0) })
        let script = "display notification \"\(body)\" with title \"Claude Code\" subtitle \"\(safe)\""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let sessionID = response.notification.request.content.userInfo["session"] as? String
        focusTerminal(for: sessionID ?? "")
        completionHandler()
    }

    // Two steps, in this order: switch the tab first, then raise the app, so the
    // window that comes forward is already showing the right session rather than
    // visibly flipping to it afterwards.
    func focusTerminal(for sessionID: String) {
        // Only a session with no record at all gets the legacy fallback. A
        // session recorded in a terminal this app does not know stays put:
        // raising some *other* terminal is worse than doing nothing, and the
        // banner already told the truth about where the session is.
        guard let record = sessionTerminal(sessionID) else {
            activate(legacyTerminal)
            return
        }
        guard let app = record.app else { return }

        // The tab switch is worth waiting on only when Orca is already up. With
        // Orca closed the CLI spends a couple of seconds discovering there is no
        // runtime, which reads as a dead click, so skip straight to launching.
        let running = !NSRunningApplication.runningApplications(
            withBundleIdentifier: app.bundleID).isEmpty

        guard running, record.program == "Orca", !record.handle.isEmpty else {
            activate(app)
            return
        }

        let handle = record.handle
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.switchOrcaTab(to: handle)
            DispatchQueue.main.async { self?.activate(app) }
        }
    }

    func activate(_ app: TerminalApp) {
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: app.bundleID).first {
            running.activate(options: [.activateAllWindows])
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // Orca ships no URL scheme and no AppleScript dictionary, but its CLI takes
    // the same per-tab handle the session was launched with, which is the one
    // supported way in from outside.
    func switchOrcaTab(to handle: String) {
        guard isValidOrcaHandle(handle),
              let cli = orcaCLICandidates.first(where: {
                  FileManager.default.isExecutableFile(atPath: $0)
              }) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["terminal", "switch", "--terminal", handle]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("ClaudeNotify: could not switch Orca tab: \(error.localizedDescription)")
        }
    }

    func isValidOrcaHandle(_ handle: String) -> Bool {
        guard handle.hasPrefix("term_"), handle.count < 80 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return handle.allSatisfy { allowed.contains($0) }
    }

    @objc func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            toggle()
            return
        }

        let wantsMenu = event.type == .rightMouseUp
            || event.modifierFlags.contains(.control)
            || event.modifierFlags.contains(.option)

        if wantsMenu {
            showMenu()
        } else {
            toggle()
        }
    }

    func showMenu() {
        rebuildMenu()
        updateUI()
        statusItem.menu = mainMenu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    func installSupportFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: soundsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: sessionSoundsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: sessionVolumesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: speakDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: terminalsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)

        let existing = try? String(contentsOf: scriptURL, encoding: .utf8)
        if existing != scriptBody {
            try? scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    func soundList(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
        updateUI()
    }

    func rebuildMenu() {
        let menu = mainMenu
        menu.removeAllItems()

        toggleItem = NSMenuItem(title: isMuted ? "Unmute completion sound" : "Mute completion sound",
                                action: #selector(toggle),
                                keyEquivalent: "m")
        toggleItem.target = self
        menu.addItem(toggleItem)

        if let deadline = mutedUntil {
            let remaining = NSMenuItem(title: "Silent for \(remainingLabel(until: deadline))",
                                       action: nil,
                                       keyEquivalent: "")
            remaining.isEnabled = false
            menu.addItem(remaining)
        } else if !isPermanentlyMuted {
            let muteFor = NSMenu()
            for duration in muteDurations where duration.minutes > 0 {
                let item = NSMenuItem(title: duration.title,
                                      action: #selector(muteForDuration(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = duration.minutes
                muteFor.addItem(item)
            }
            let parent = NSMenuItem(title: "Mute For", action: nil, keyEquivalent: "")
            parent.submenu = muteFor
            menu.addItem(parent)
        }

        menu.addItem(.separator())

        let current = selectedSound.resolvingSymlinksInPath().path
        let soundMenu = NSMenu()

        for url in soundList(in: systemSoundsDir) {
            soundMenu.addItem(soundItem(for: url, current: current))
        }

        soundMenu.addItem(.separator())

        for source in extraSoundSources {
            let submenu = source.flatten
                ? flatSoundMenu(for: source.url, current: current)
                : buildSoundMenu(for: source.url, current: current)
            guard !submenu.items.isEmpty else { continue }
            let parent = NSMenuItem(title: source.title, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            soundMenu.addItem(parent)
        }

        let userSounds = soundList(in: soundsDir)
        if !userSounds.isEmpty {
            soundMenu.addItem(.separator())
            for url in userSounds {
                soundMenu.addItem(soundItem(for: url, current: current))
            }
        }

        soundMenu.addItem(.separator())
        soundMenu.addItem(actionItem("Add Sound…", #selector(addSound)))
        soundMenu.addItem(actionItem("Reveal Sounds Folder", #selector(revealSoundsFolder)))

        let soundParent = NSMenuItem(title: "Sound", action: nil, keyEquivalent: "")
        soundParent.submenu = soundMenu
        menu.addItem(soundParent)

        let nameItem = NSMenuItem(
            title: "Current: \(prettyName(selectedSound.deletingPathExtension().lastPathComponent))",
            action: nil,
            keyEquivalent: "")
        nameItem.isEnabled = false
        menu.addItem(nameItem)

        let sessionsParent = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
        sessionsParent.submenu = sessionsMenu()
        menu.addItem(sessionsParent)

        let activeReminder = reminderMinutes
        let remindMenu = NSMenu()
        for choice in reminderChoices {
            let item = NSMenuItem(title: choice.title,
                                  action: #selector(setReminderMinutes(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = choice.minutes
            item.state = choice.minutes == activeReminder ? .on : .off
            remindMenu.addItem(item)
        }
        remindMenu.addItem(.separator())

        let activeLimit = reminderLimit
        let limitMenu = NSMenu()
        for choice in reminderLimitChoices {
            let item = NSMenuItem(title: choice.title,
                                  action: #selector(setReminderLimit(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = choice.limit
            item.state = choice.limit == activeLimit ? .on : .off
            limitMenu.addItem(item)
        }
        let limitParent = NSMenuItem(
            title: activeLimit == 0 ? "Repeats: unlimited" : "Repeats: up to \(activeLimit)",
            action: nil,
            keyEquivalent: "")
        limitParent.submenu = limitMenu
        remindMenu.addItem(limitParent)

        let remindParent = NSMenuItem(
            title: activeReminder == 0 ? "Remind Me Again: Off" : "Remind Me Again: every \(activeReminder)m",
            action: nil,
            keyEquivalent: "")
        remindParent.submenu = remindMenu
        menu.addItem(remindParent)

        menu.addItem(.separator())

        let label = NSMenuItem(title: volumeLabel(for: currentVolume), action: nil, keyEquivalent: "")
        label.isEnabled = false
        volumeLabelItem = label
        menu.addItem(label)
        menu.addItem(volumeSliderItem())

        menu.addItem(.separator())

        menu.addItem(actionItem("Play Test Sound", #selector(playTestSound)))

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quitItem = NSMenuItem(title: "Quit Claude Notify",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    func flatSoundMenu(for directory: URL, current: String) -> NSMenu {
        let menu = NSMenu()
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return menu }

        let files = walker
            .compactMap { $0 as? URL }
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { prettyName($0.lastPathComponent).localizedStandardCompare(prettyName($1.lastPathComponent)) == .orderedAscending }

        for url in files {
            menu.addItem(soundItem(for: url, current: current))
        }
        return menu
    }

    func buildSoundMenu(for directory: URL, current: String) -> NSMenu {
        let menu = NSMenu()
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []

        let sorted = entries.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        let files = sorted.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        let directories = sorted.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }

        for url in files {
            menu.addItem(soundItem(for: url, current: current))
        }

        var addedSeparator = files.isEmpty
        for url in directories {
            let submenu = buildSoundMenu(for: url, current: current)
            guard !submenu.items.isEmpty else { continue }
            if !addedSeparator {
                menu.addItem(.separator())
                addedSeparator = true
            }
            if submenu.items.count == 1, let only = submenu.items.first, only.representedObject != nil {
                submenu.removeItem(only)
                menu.addItem(only)
                continue
            }
            let parent = NSMenuItem(title: prettyName(url.lastPathComponent),
                                    action: nil,
                                    keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }

        return menu
    }

    func prettyName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "-EncoreInfinitum", with: "")
        name = name.replacingOccurrences(of: "_", with: " ")
        name = name.replacingOccurrences(of: "-", with: " ")

        var spaced = ""
        var previous: Character?
        for character in name {
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                spaced.append(" ")
            }
            spaced.append(character)
            previous = character
        }

        name = spaced.trimmingCharacters(in: .whitespaces)
        guard let first = name.first else { return raw }
        return first.uppercased() + name.dropFirst()
    }

    func soundItem(for url: URL, current: String) -> NSMenuItem {
        let item = NSMenuItem(title: prettyName(url.deletingPathExtension().lastPathComponent),
                              action: #selector(selectSound(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.state = url.resolvingSymlinksInPath().path == current ? .on : .off
        return item
    }

    // Transcripts reach tens of megabytes, so the title is read from the tail
    // rather than by parsing the file.
    func tailText(of url: URL, bytes: UInt64 = 200_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func lastJSONValue(_ key: String, in text: String) -> String? {
        let needle = "\"\(key)\":\""
        guard let found = text.range(of: needle, options: .backwards) else { return nil }
        let rest = text[found.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value.replacingOccurrences(of: "\\\"", with: "\"")
    }

    func transcriptURL(for sessionID: String) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: transcriptsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return nil }

        for directory in dirs {
            let candidate = directory.appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    func liveSessions() -> [SessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: liveDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        let cutoff = Date().addingTimeInterval(-liveStaleWindow)
        var sessions: [SessionInfo] = []

        for file in files {
            let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey, .creationDateKey])
            guard let heartbeat = values?.contentModificationDate else { continue }

            guard heartbeat > cutoff else {
                try? fm.removeItem(at: file)
                continue
            }

            let id = file.lastPathComponent
            let cwd = (try? String(contentsOf: file, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // A session with no transcript yet has not been typed into, so the
            // only facts available are where it started and when.
            var title = "New session, \(startedLabel(values?.creationDate ?? heartbeat))"
            var project = (cwd?.isEmpty == false) ? URL(fileURLWithPath: cwd!).lastPathComponent : ""

            if let transcript = transcriptURL(for: id) {
                let text = tailText(of: transcript) ?? ""
                title = lastJSONValue("aiTitle", in: text) ?? title
                if project.isEmpty, let recorded = lastJSONValue("cwd", in: text) {
                    project = URL(fileURLWithPath: recorded).lastPathComponent
                }
            }

            sessions.append(SessionInfo(
                id: id,
                title: title,
                project: project.isEmpty ? "session" : project,
                modified: heartbeat))
        }

        pruneOrphanedRecords(keeping: Set(sessions.map { $0.id }))
        return sessions.sorted { $0.modified > $1.modified }
    }

    // live/ prunes itself by heartbeat above, but the records keyed to a session
    // are only deleted by SessionEnd, which a session killed outright never
    // sends. A record with no live entry and no write in the stale window
    // belongs to a session that is long gone.
    //
    // Only the machine-recorded directories are swept. The per-session sound,
    // volume and speak markers are choices the user made, and a session id that
    // comes back deserves to find them still there.
    func pruneOrphanedRecords(keeping ids: Set<String>) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-liveStaleWindow)

        for directory in [ttyDir, terminalsDir] {
            guard let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }

            for file in files where !ids.contains(file.lastPathComponent) {
                // The age check is what makes this safe against a session still
                // starting up, whose live entry may not be written yet.
                guard let modified = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified < cutoff else { continue }
                try? fm.removeItem(at: file)
            }
        }
    }

    // Sessions that predate the hooks being registered have no registry entry
    // until they next respond, so fall back to transcript times rather than
    // showing an empty menu.
    func recentSessions() -> [SessionInfo] {
        let live = liveSessions()
        if !live.isEmpty { return Array(live.prefix(sessionLimit)) }
        return transcriptSessions()
    }

    func transcriptSessions() -> [SessionInfo] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: transcriptsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }

        let cutoff = Date().addingTimeInterval(-sessionWindow)
        var candidates: [(url: URL, modified: Date)] = []

        for directory in projectDirs {
            let files = (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified > cutoff else { continue }
                candidates.append((file, modified))
            }
        }

        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(sessionLimit)
            .map { candidate in
                let text = tailText(of: candidate.url) ?? ""
                let id = candidate.url.deletingPathExtension().lastPathComponent
                let title = lastJSONValue("aiTitle", in: text) ?? "Untitled session"
                let cwd = lastJSONValue("cwd", in: text)
                let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? candidate.url.deletingLastPathComponent().lastPathComponent
                return SessionInfo(id: id, title: title, project: project, modified: candidate.modified)
            }
    }

    func assignedSound(for sessionID: String) -> URL? {
        let pointer = sessionSoundsDir.appendingPathComponent(sessionID)
        guard let raw = try? String(contentsOf: pointer, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func startedLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    func relativeAge(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    func sessionsMenu() -> NSMenu {
        let menu = NSMenu()
        let sessions = recentSessions()

        guard !sessions.isEmpty else {
            let empty = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return menu
        }

        for session in sessions {
            let assigned = assignedSound(for: session.id)
            var title = "\(session.project) · \(session.title)"
            if title.count > 58 { title = String(title.prefix(57)) + "…" }

            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.state = assigned == nil ? .off : .on

            let submenu = NSMenu()

            let status = NSMenuItem(
                title: assigned.map { "Sound: \(prettyName($0.deletingPathExtension().lastPathComponent))" }
                    ?? "Sound: default",
                action: nil,
                keyEquivalent: "")
            status.isEnabled = false
            submenu.addItem(status)

            let sessionLevel = sessionVolume(for: session.id)
            let volumeStatus = NSMenuItem(
                title: sessionLevel.map { "Volume: \(Int(($0 * 100).rounded()))%" }
                    ?? "Volume: default (\(Int((currentVolume * 100).rounded()))%)",
                action: nil,
                keyEquivalent: "")
            volumeStatus.isEnabled = false
            submenu.addItem(volumeStatus)

            let where_ = [sessionTerminal(session.id)?.displayName, sessionTTY(session.id)]
                .compactMap { $0 }
                .joined(separator: " · ")
            if !where_.isEmpty {
                let terminal = NSMenuItem(title: "Terminal: \(where_)", action: nil, keyEquivalent: "")
                terminal.isEnabled = false
                submenu.addItem(terminal)
            }

            let age = NSMenuItem(title: "Active \(relativeAge(session.modified))", action: nil, keyEquivalent: "")
            age.isEnabled = false
            submenu.addItem(age)

            submenu.addItem(.separator())

            submenu.addItem(sessionVolumeItem(for: session.id, level: sessionLevel ?? currentVolume))

            let assign = NSMenuItem(
                title: "Use Current Sound (\(prettyName(selectedSound.deletingPathExtension().lastPathComponent)))",
                action: #selector(assignSoundToSession(_:)),
                keyEquivalent: "")
            assign.target = self
            assign.representedObject = session.id
            submenu.addItem(assign)

            if assigned != nil || sessionLevel != nil {
                let clear = NSMenuItem(title: "Clear Session Settings",
                                       action: #selector(clearSessionSound(_:)),
                                       keyEquivalent: "")
                clear.target = self
                clear.representedObject = session.id
                submenu.addItem(clear)
            }

            let speak = NSMenuItem(title: "Speak Session Name",
                                   action: #selector(toggleSpeakName(_:)),
                                   keyEquivalent: "")
            speak.target = self
            speak.representedObject = session.id
            speak.state = speaksName(session.id) ? .on : .off
            submenu.addItem(speak)

            let preview = NSMenuItem(title: "Play This Session's Sound",
                                     action: #selector(playSessionSound(_:)),
                                     keyEquivalent: "")
            preview.target = self
            preview.representedObject = session.id
            submenu.addItem(preview)

            item.submenu = submenu
            menu.addItem(item)
        }

        return menu
    }

    @objc func assignSoundToSession(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String else { return }
        try? FileManager.default.createDirectory(at: sessionSoundsDir, withIntermediateDirectories: true)
        try? selectedSound.path.write(
            to: sessionSoundsDir.appendingPathComponent(sessionID),
            atomically: true,
            encoding: .utf8)
        play(selectedSound)
    }

    @objc func clearSessionSound(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: sessionSoundsDir.appendingPathComponent(sessionID))
        try? fm.removeItem(at: sessionVolumesDir.appendingPathComponent(sessionID))
    }

    @objc func playSessionSound(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String else { return }
        play(assignedSound(for: sessionID) ?? selectedSound,
             volume: sessionVolume(for: sessionID))
    }

    func sessionTTY(_ sessionID: String) -> String? {
        guard let raw = try? String(contentsOf: ttyDir.appendingPathComponent(sessionID), encoding: .utf8) else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // Line one is TERM_PROGRAM, line two the Orca tab handle when there is one.
    // Terminals other than Orca write an empty second line, which reads back as
    // "raise the app, no tab to target".
    func sessionTerminal(_ sessionID: String) -> SessionTerminal? {
        guard !sessionID.isEmpty,
              let raw = try? String(contentsOf: terminalsDir.appendingPathComponent(sessionID),
                                    encoding: .utf8) else { return nil }

        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let program = lines.first, !program.isEmpty else { return nil }

        return SessionTerminal(program: program,
                               handle: lines.count > 1 ? lines[1] : "")
    }

    var reminderMinutes: Int {
        guard let raw = try? String(contentsOf: reminderMinutesURL, encoding: .utf8),
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return 0
        }
        return value
    }

    @objc func setReminderMinutes(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        try? String(minutes).write(to: reminderMinutesURL, atomically: true, encoding: .utf8)
        lastReminded.removeAll()
        reminderCounts.removeAll()
    }

    var reminderLimit: Int {
        guard let raw = try? String(contentsOf: reminderLimitURL, encoding: .utf8),
              let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              value >= 0 else {
            return defaultReminderLimit
        }
        return value
    }

    @objc func setReminderLimit(_ sender: NSMenuItem) {
        guard let limit = sender.representedObject as? Int else { return }
        try? String(limit).write(to: reminderLimitURL, atomically: true, encoding: .utf8)
        reminderCounts.removeAll()
    }

    // A session counts as still waiting only if nothing has touched it since it
    // finished. The transcript moves while Claude works, so it is the honest
    // activity signal; the heartbeat alone would nag during a long turn.
    func lastActivity(of session: SessionInfo) -> Date {
        var latest = session.modified
        if let transcript = transcriptURL(for: session.id),
           let modified = try? transcript.resourceValues(
               forKeys: [.contentModificationDateKey]).contentModificationDate,
           modified > latest {
            latest = modified
        }
        return latest
    }

    func checkReminders() {
        let minutes = reminderMinutes
        guard minutes > 0, !isMuted else { return }

        let interval = TimeInterval(minutes * 60)
        let now = Date()

        for session in liveSessions() {
            let idle = now.timeIntervalSince(lastActivity(of: session))

            guard idle >= interval else {
                lastReminded[session.id] = nil
                reminderCounts[session.id] = nil
                continue
            }

            if let last = lastReminded[session.id], now.timeIntervalSince(last) < interval { continue }

            let limit = reminderLimit
            if limit > 0, reminderCounts[session.id, default: 0] >= limit { continue }

            lastReminded[session.id] = now
            reminderCounts[session.id, default: 0] += 1

            let waiting = Int(idle / 60)
            postFinishedNotification(
                for: session.id,
                label: "\(session.project) · \(session.title)",
                reminder: "Waiting \(waiting) minutes")
            play(assignedSound(for: session.id) ?? selectedSound,
                 volume: sessionVolume(for: session.id))
        }
    }

    func speaksName(_ sessionID: String) -> Bool {
        FileManager.default.fileExists(atPath: speakDir.appendingPathComponent(sessionID).path)
    }

    @objc func toggleSpeakName(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String else { return }
        let fm = FileManager.default
        let marker = speakDir.appendingPathComponent(sessionID)

        if speaksName(sessionID) {
            try? fm.removeItem(at: marker)
            return
        }

        try? fm.createDirectory(at: speakDir, withIntermediateDirectories: true)
        fm.createFile(atPath: marker.path, contents: nil)
        speakPreview(for: sessionID)
    }

    func speakPreview(for sessionID: String) {
        var spoken = "Claude"
        if let transcript = transcriptURL(for: sessionID),
           let title = lastJSONValue("aiTitle", in: tailText(of: transcript) ?? "") {
            spoken = title
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", "220", spoken.replacingOccurrences(of: "-", with: " ") + " finished"]
        try? process.run()
    }

    // A session with no override follows the global slider, so the absence of a
    // file is meaningful and is not the same as storing the current level.
    func sessionVolume(for sessionID: String) -> Double? {
        let pointer = sessionVolumesDir.appendingPathComponent(sessionID)
        guard let raw = try? String(contentsOf: pointer, encoding: .utf8),
              let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return min(max(value, 0.1), 1.0)
    }

    func sessionVolumeItem(for sessionID: String, level: Double) -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        let slider = SessionVolumeSlider(frame: NSRect(x: 20, y: 3, width: 182, height: 20))
        slider.sessionID = sessionID
        slider.minValue = 0.1
        slider.maxValue = 1.0
        slider.doubleValue = level
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sessionVolumeChanged(_:))
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    @objc func sessionVolumeChanged(_ sender: SessionVolumeSlider) {
        let sessionID = sender.sessionID
        guard !sessionID.isEmpty else { return }
        let value = (sender.doubleValue * 100).rounded() / 100

        try? FileManager.default.createDirectory(at: sessionVolumesDir, withIntermediateDirectories: true)
        try? String(format: "%.2f", value).write(
            to: sessionVolumesDir.appendingPathComponent(sessionID),
            atomically: true,
            encoding: .utf8)

        if NSApp.currentEvent?.type == .leftMouseUp {
            play(assignedSound(for: sessionID) ?? selectedSound, volume: value)
        }
    }

    func volumeLabel(for volume: Double) -> String {
        "Volume: \(Int((volume * 100).rounded()))%"
    }

    func volumeSliderItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        let slider = NSSlider(frame: NSRect(x: 20, y: 3, width: 182, height: 20))
        slider.minValue = 0.1
        slider.maxValue = 1.0
        slider.doubleValue = currentVolume
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(volumeChanged(_:))
        container.addSubview(slider)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    @objc func volumeChanged(_ sender: NSSlider) {
        let value = (sender.doubleValue * 100).rounded() / 100
        try? String(format: "%.2f", value).write(to: volumePointerURL, atomically: true, encoding: .utf8)
        volumeLabelItem?.title = volumeLabel(for: value)

        if NSApp.currentEvent?.type == .leftMouseUp {
            play(selectedSound)
        }
    }

    func actionItem(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func selectSound(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        try? url.path.write(to: soundPointerURL, atomically: true, encoding: .utf8)
        play(url)
        rebuildMenu()
        updateUI()
    }

    @objc func addSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose audio files to add to your ClaudeNotify sounds."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }

        var lastAdded: URL?
        for source in panel.urls {
            if let copied = copyIntoLibrary(source) { lastAdded = copied }
        }

        if let added = lastAdded {
            try? added.path.write(to: soundPointerURL, atomically: true, encoding: .utf8)
            play(added)
        }
        rebuildMenu()
        updateUI()
    }

    func copyIntoLibrary(_ source: URL) -> URL? {
        let fm = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var destination = soundsDir.appendingPathComponent(source.lastPathComponent)

        var counter = 2
        while fm.fileExists(atPath: destination.path) {
            destination = soundsDir.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }

        do {
            try fm.copyItem(at: source, to: destination)
            return destination
        } catch {
            presentError("Couldn't add \(source.lastPathComponent)", error.localizedDescription)
            return nil
        }
    }

    @objc func revealSoundsFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: soundsDir.path)
    }

    @objc func playTestSound() {
        play(selectedSound)
    }

    func play(_ url: URL, volume: Double? = nil) {
        preview?.stop()
        preview = NSSound(contentsOf: url, byReference: true)
        preview?.volume = Float(volume ?? currentVolume)
        preview?.play()
    }

    func presentError(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func remainingLabel(until deadline: Date) -> String {
        let minutes = Int((deadline.timeIntervalSinceNow / 60).rounded(.up))
        if minutes <= 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) more minutes" }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return hours == 1 ? "1 more hour" : "\(hours) more hours" }
        return "\(hours)h \(rest)m"
    }

    @objc func muteForDuration(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        try? String(format: "%.0f", deadline.timeIntervalSince1970)
            .write(to: mutedUntilURL, atomically: true, encoding: .utf8)
        updateUI()
    }

    // Either kind of mute is cleared by one toggle, so there is never a state
    // where the bell looks unmuted but a forgotten timer is still running.
    @objc func toggle() {
        if isMuted {
            try? FileManager.default.removeItem(at: flagURL)
            try? FileManager.default.removeItem(at: mutedUntilURL)
        } else {
            try? FileManager.default.createDirectory(
                at: flagURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: flagURL.path, contents: nil)
        }
        updateUI()
    }

    func updateUI() {
        let deadline = mutedUntil
        let muted = isMuted
        let symbol = muted ? "bell.slash.fill" : "bell.fill"
        var desc = muted ? "Claude completion sound muted" : "Claude completion sound on"
        if let deadline {
            desc = "Claude completion sound muted, \(remainingLabel(until: deadline))"
        }
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: desc) {
            img.isTemplate = true   // adapts to light/dark menu bar
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = muted ? "🔕" : "🔔"
        }
        toggleItem?.state = muted ? .on : .off
        statusItem.button?.toolTip = "\(desc)\nClick to toggle, right-click for sounds and settings"
    }

    @objc func quit() { NSApp.terminate(nil) }
}

// The menu bar is a poor place to browse 100+ sounds or compare settings, so
// the global ones live in a window. Per-session settings stay in the menu,
// where the session list already is.
extension AppDelegate: NSTableViewDataSource, NSTableViewDelegate {
    func allSounds() -> [(name: String, group: String, url: URL)] {
        var rows: [(name: String, group: String, url: URL)] = []

        for url in soundList(in: systemSoundsDir) {
            rows.append((prettyName(url.deletingPathExtension().lastPathComponent), "System", url))
        }

        for source in extraSoundSources {
            guard let walker = FileManager.default.enumerator(
                at: source.url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }

            for case let url as URL in walker
            where audioExtensions.contains(url.pathExtension.lowercased()) {
                let folder = url.deletingLastPathComponent().lastPathComponent
                let group = source.flatten ? source.title : "\(source.title) · \(prettyName(folder))"
                rows.append((prettyName(url.deletingPathExtension().lastPathComponent), group, url))
            }
        }

        for url in soundList(in: soundsDir) {
            rows.append((prettyName(url.deletingPathExtension().lastPathComponent), "Yours", url))
        }

        return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    @objc func openSettings() {
        if let window = settingsWindow {
            refreshSettings()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let width: CGFloat = 540
        let height: CGFloat = 560
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.title = "ClaudeNotify Settings"
        window.isReleasedWhenClosed = false
        window.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        func label(_ text: String, _ frame: NSRect, bold: Bool = false) -> NSTextField {
            let field = NSTextField(labelWithString: text)
            field.frame = frame
            if bold { field.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) }
            return field
        }

        content.addSubview(label("General", NSRect(x: 20, y: height - 40, width: 200, height: 18), bold: true))

        let mute = NSButton(checkboxWithTitle: "Mute completion sound",
                            target: self,
                            action: #selector(settingsMuteChanged(_:)))
        mute.frame = NSRect(x: 20, y: height - 72, width: 300, height: 20)
        content.addSubview(mute)
        settingsMuteCheckbox = mute

        content.addSubview(label("Volume", NSRect(x: 20, y: height - 106, width: 120, height: 20)))
        let volume = NSSlider(frame: NSRect(x: 150, y: height - 108, width: 300, height: 24))
        volume.minValue = 0.1
        volume.maxValue = 1.0
        volume.isContinuous = true
        volume.target = self
        volume.action = #selector(settingsVolumeChanged(_:))
        content.addSubview(volume)
        settingsVolumeSlider = volume

        let volumeValue = label("", NSRect(x: 460, y: height - 106, width: 60, height: 20))
        content.addSubview(volumeValue)
        settingsVolumeLabel = volumeValue

        content.addSubview(label("Remind me again", NSRect(x: 20, y: height - 144, width: 130, height: 20)))
        let cadence = NSPopUpButton(frame: NSRect(x: 150, y: height - 148, width: 200, height: 26))
        for choice in reminderChoices { cadence.addItem(withTitle: choice.title) }
        cadence.target = self
        cadence.action = #selector(settingsCadenceChanged(_:))
        content.addSubview(cadence)
        settingsCadencePopup = cadence

        content.addSubview(label("Repeats", NSRect(x: 20, y: height - 182, width: 130, height: 20)))
        let repeats = NSPopUpButton(frame: NSRect(x: 150, y: height - 186, width: 200, height: 26))
        for choice in reminderLimitChoices { repeats.addItem(withTitle: choice.title) }
        repeats.target = self
        repeats.action = #selector(settingsRepeatsChanged(_:))
        content.addSubview(repeats)
        settingsRepeatsPopup = repeats

        let divider = NSBox(frame: NSRect(x: 20, y: height - 208, width: width - 40, height: 1))
        divider.boxType = .separator
        content.addSubview(divider)

        content.addSubview(label("Notification sound", NSRect(x: 20, y: height - 240, width: 250, height: 18), bold: true))

        let search = NSSearchField(frame: NSRect(x: 20, y: height - 274, width: width - 40, height: 24))
        search.placeholderString = "Search sounds"
        search.target = self
        search.action = #selector(settingsSearchChanged(_:))
        content.addSubview(search)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 60, width: width - 40, height: height - 346))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let table = NSTableView(frame: scroll.bounds)
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Sound"
        nameColumn.width = 300
        table.addTableColumn(nameColumn)
        let groupColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("group"))
        groupColumn.title = "Where"
        groupColumn.width = 180
        table.addTableColumn(groupColumn)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(settingsSoundClicked(_:))
        scroll.documentView = table
        content.addSubview(scroll)
        soundTable = table

        let add = NSButton(title: "Add Sound…", target: self, action: #selector(addSound))
        add.frame = NSRect(x: 20, y: 20, width: 120, height: 28)
        content.addSubview(add)

        let reveal = NSButton(title: "Reveal Sounds Folder", target: self, action: #selector(revealSoundsFolder))
        reveal.frame = NSRect(x: 150, y: 20, width: 180, height: 28)
        content.addSubview(reveal)

        window.contentView = content
        settingsWindow = window

        refreshSettings()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func refreshSettings() {
        soundRows = allSounds()
        soundTable?.reloadData()

        settingsMuteCheckbox?.state = isMuted ? .on : .off
        settingsVolumeSlider?.doubleValue = currentVolume
        settingsVolumeLabel?.stringValue = "\(Int((currentVolume * 100).rounded()))%"

        if let index = reminderChoices.firstIndex(where: { $0.minutes == reminderMinutes }) {
            settingsCadencePopup?.selectItem(at: index)
        }
        if let index = reminderLimitChoices.firstIndex(where: { $0.limit == reminderLimit }) {
            settingsRepeatsPopup?.selectItem(at: index)
        }

        let current = selectedSound.resolvingSymlinksInPath().path
        if let row = soundRows.firstIndex(where: { $0.url.resolvingSymlinksInPath().path == current }) {
            soundTable?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            soundTable?.scrollRowToVisible(row)
        }
    }

    @objc func settingsMuteChanged(_ sender: NSButton) {
        let fm = FileManager.default
        if sender.state == .on {
            try? fm.createDirectory(at: flagURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: flagURL.path, contents: nil)
        } else {
            try? fm.removeItem(at: flagURL)
            try? fm.removeItem(at: mutedUntilURL)
        }
        updateUI()
    }

    @objc func settingsVolumeChanged(_ sender: NSSlider) {
        let value = (sender.doubleValue * 100).rounded() / 100
        try? String(format: "%.2f", value).write(to: volumePointerURL, atomically: true, encoding: .utf8)
        settingsVolumeLabel?.stringValue = "\(Int((value * 100).rounded()))%"
        if NSApp.currentEvent?.type == .leftMouseUp {
            play(selectedSound, volume: value)
        }
    }

    @objc func settingsCadenceChanged(_ sender: NSPopUpButton) {
        let minutes = reminderChoices[sender.indexOfSelectedItem].minutes
        try? String(minutes).write(to: reminderMinutesURL, atomically: true, encoding: .utf8)
        lastReminded.removeAll()
        reminderCounts.removeAll()
    }

    @objc func settingsRepeatsChanged(_ sender: NSPopUpButton) {
        let limit = reminderLimitChoices[sender.indexOfSelectedItem].limit
        try? String(limit).write(to: reminderLimitURL, atomically: true, encoding: .utf8)
        reminderCounts.removeAll()
    }

    @objc func settingsSearchChanged(_ sender: NSSearchField) {
        let term = sender.stringValue.trimmingCharacters(in: .whitespaces)
        soundRows = term.isEmpty
            ? allSounds()
            : allSounds().filter {
                $0.name.localizedCaseInsensitiveContains(term)
                    || $0.group.localizedCaseInsensitiveContains(term)
            }
        soundTable?.reloadData()
    }

    @objc func settingsSoundClicked(_ sender: NSTableView) {
        let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
        guard row >= 0, row < soundRows.count else { return }
        let url = soundRows[row].url
        try? url.path.write(to: soundPointerURL, atomically: true, encoding: .utf8)
        play(url)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { soundRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < soundRows.count else { return nil }
        let text = tableColumn?.identifier.rawValue == "group" ? soundRows[row].group : soundRows[row].name
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail
        if tableColumn?.identifier.rawValue == "group" {
            field.textColor = .secondaryLabelColor
        }
        return field
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
