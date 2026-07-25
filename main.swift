import Cocoa

// The flag file the Claude Code Stop hook checks. If this file exists, the
// completion sound is suppressed. Toggling the menu-bar item creates/removes it.
let flagURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude/notifications-muted")

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var toggleItem: NSMenuItem!

    var isMuted: Bool { FileManager.default.fileExists(atPath: flagURL.path) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()

        toggleItem = NSMenuItem(title: "Mute completion sound",
                                action: #selector(toggle),
                                keyEquivalent: "m")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Claude Notify",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu

        // React if the flag is changed by something else (e.g. the hook, or you
        // editing the file directly) so the icon stays in sync.
        statusItem.button?.toolTip = "Claude Code completion sound"
        updateUI()
    }

    @objc func toggle() {
        if isMuted {
            try? FileManager.default.removeItem(at: flagURL)
        } else {
            try? FileManager.default.createDirectory(
                at: flagURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: flagURL.path, contents: nil)
        }
        updateUI()
    }

    func updateUI() {
        let muted = isMuted
        let symbol = muted ? "bell.slash.fill" : "bell.fill"
        let desc = muted ? "Claude completion sound muted" : "Claude completion sound on"
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: desc) {
            img.isTemplate = true   // adapts to light/dark menu bar
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.image = nil
            statusItem.button?.title = muted ? "🔕" : "🔔"
        }
        toggleItem.state = muted ? .on : .off
        statusItem.button?.toolTip = desc
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
