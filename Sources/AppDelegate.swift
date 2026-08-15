import Cocoa
import CoreAudio
import UserNotifications

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
    var settingsDuckCheckbox: NSButton?
    var settingsCadencePopup: NSPopUpButton?
    var settingsRepeatsPopup: NSPopUpButton?
    var lastReminded: [String: Date] = [:]
    var reminderCounts: [String: Int] = [:]
    var micLiveSince: Date?
    var micIdleSince: Date?
    var inMeeting = false
    var meetingOverridden = false
    var meetingNoticePosted = false
    var meetingID = 0
    var loggedMeetingUnavailable = false
    var audioListeners: [(AudioDeviceID, AudioObjectPropertyListenerBlock)] = []
    var meetingCheckTimer: Timer?
    var forcedMeetingWatcher: DispatchSourceFileSystemObject?
    var duckGeneration = 0
    var duckedDevice: AudioDeviceID?

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
}
