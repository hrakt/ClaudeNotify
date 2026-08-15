import Cocoa


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

// A meeting is the microphone being live, which is one signal covering Meet,
// Slack huddles, Zoom, Teams and FaceTime at once. Integrating with each service
// would mean OAuth and upkeep per service; this needs no permission at all,
// because asking whether a device is running is not recording from it.
let inMeetingURL = supportDir.appendingPathComponent("in-meeting")
let quietInMeetingsURL = supportDir.appendingPathComponent("quiet-in-meetings")
let forceMeetingURL = supportDir.appendingPathComponent("force-meeting")

// Banners raised during a meeting are held here rather than dropped, so walking
// out of a call tells you what finished while you were in it.
let deferredDir = supportDir.appendingPathComponent("deferred")

// Matched as prefixes, since the process holding the microphone is usually a
// helper: Chrome records as com.google.Chrome.helper, Slack as
// com.tinyspeck.slackmacgap.helper.
//
// The list is what separates a meeting from any other use of the microphone.
// Dictation, MacWhisper, Voice Memos and QuickTime all light up the same device,
// and none of them mean you are unavailable.
// Named as well as matched, so the notice can say what it saw. "A meeting" is
// a claim the user has to take on trust; "Meeting in Slack" is one they can
// check at a glance, and correct if it is wrong.
let meetingApps: [(prefix: String, name: String)] = [
    ("com.google.Chrome", "Chrome"),
    ("com.apple.Safari", "Safari"),
    ("com.apple.WebKit", "Safari"),
    ("org.mozilla.firefox", "Firefox"),
    ("com.microsoft.edgemac", "Edge"),
    ("com.brave.Browser", "Brave"),
    ("company.thebrowser.Browser", "Arc"),
    ("com.tinyspeck.slackmacgap", "Slack"),
    ("us.zoom.xos", "Zoom"),
    ("com.microsoft.teams", "Teams"),
    ("com.apple.FaceTime", "FaceTime"),
    ("com.apple.avconferenced", "FaceTime"),
    ("com.hnc.Discord", "Discord"),
    ("com.granola.app", "Granola"),
]

// The notice carries a button, which means a registered category: an action on
// a notification posted without one is silently dropped by macOS.
let meetingCategoryID = "meeting-detected"
let meetingOverrideActionID = "meeting-notify-anyway"

// The microphone opening for a moment is dictation or a notification chime, not
// a meeting. Leaving needs a longer grace than joining, so a brief drop mid-call
// does not end the meeting and let a ding through.
let meetingStartDebounce: TimeInterval = 10
let meetingEndGrace: TimeInterval = 20
let meetingPollInterval: TimeInterval = 5

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
