import Cocoa
import ServiceManagement
import UserNotifications

extension AppDelegate {
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
            self?.refreshFocusFlag()
            self?.ensureProjectSounds()
        }
        renderNotificationIcons()
        refreshFocusFlag()
        ensureProjectSounds()

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: meetingCategoryID,
                actions: [UNNotificationAction(identifier: meetingOverrideActionID,
                                               title: "Notify Anyway",
                                               options: [])],
                intentIdentifiers: [],
                options: []),
            UNNotificationCategory(
                identifier: meetingEndedCategoryID,
                actions: [UNNotificationAction(identifier: stayQuietActionID,
                                               title: "Stay Quiet",
                                               options: [])],
                intentIdentifiers: [],
                options: []),
        ])
        center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
            NSLog("ClaudeNotify: notification authorization granted=\(granted) error=\(error?.localizedDescription ?? "none")")
            DispatchQueue.main.async { self?.recordNotificationPermission(granted) }
        }
        startWatchingPending()
        startWatchingMicrophone()

        // Anything still held was held by a previous run that ended mid-meeting.
        // Reporting it now is the whole point of holding it; left alone it would
        // otherwise surface at the end of some unrelated meeting days later.
        postDeferredSummary()
        drainPending()
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

    func installSupportFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: soundsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: sessionSoundsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: sessionVolumesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: speakDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: terminalsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: deferredDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: pendingDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: pendingMetaDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: projectSoundsDir, withIntermediateDirectories: true)

        // If macOS no longer offers the ducking call, the preference is written
        // off rather than merely greyed out in Settings. The hook reads that
        // file to decide whether to stand aside, and it cannot check for the
        // symbol itself — left on, it would keep handing the ding to an app that
        // can no longer do anything special with it, with no way to take it back.
        if audioDeviceDuck == nil, duckOtherAudio {
            try? "0".write(to: duckAudioURL, atomically: true, encoding: .utf8)
        }

        // The app owns this flag. Left behind by a crash or a force quit it
        // would silence every ding until the next meeting ended, so launching
        // clears it and detection puts it back within a poll if a call is live.
        try? fm.removeItem(at: inMeetingURL)
        // Same reasoning: the app owns this one too, and one left by a crash
        // would silence the hook until the next time a Focus happened to end.
        try? fm.removeItem(at: inFocusURL)

        let existing = try? String(contentsOf: scriptURL, encoding: .utf8)
        if existing != scriptBody {
            try? scriptBody.write(to: scriptURL, atomically: true, encoding: .utf8)
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }

    // SMAppService registers the bundle itself as a login item, which is the
    // supported route and needs no helper target and no plist of our own. It can
    // land in requiresApproval, because macOS lets the user veto login items in
    // System Settings, and a checkbox that silently disagreed with that would be
    // worse than one that admits it.
    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    @objc func toggleLaunchAtLogin(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("ClaudeNotify: could not change login item: \(error.localizedDescription)")
        }
        refreshSettings()
    }

    func loginItemNote() -> String? {
        switch SMAppService.mainApp.status {
        case .requiresApproval: return "Approve it in System Settings › General › Login Items"
        case .notFound: return "macOS cannot find this copy of the app"
        default: return nil
        }
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
        // A meeting reads as its own state rather than as muting, because it
        // ends by itself and the bell should not look like something you left
        // switched off.
        let symbol = muted ? "bell.slash.fill" : (inMeeting ? "bell.badge.slash.fill" : "bell.fill")
        var desc = muted ? "Claude completion sound muted" : "Claude completion sound on"
        if let deadline {
            desc = "Claude completion sound muted, \(remainingLabel(until: deadline))"
        } else if inMeeting && !muted {
            let held = heldCount()
            desc = held == 0
                ? "In a meeting, holding notifications"
                : "In a meeting, \(held) notification\(held == 1 ? "" : "s") held"
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

    // Quitting mid-meeting must not leave the flag behind. The script ignores a
    // flag with no app running, so this is belt and braces rather than the only
    // guard, but it keeps the on-disk state honest.
    func applicationWillTerminate(_ notification: Notification) {
        try? FileManager.default.removeItem(at: inMeetingURL)
        // Quitting mid-ding would otherwise leave every other app at a quarter
        // volume, with nothing on screen to explain it and no way to undo it
        // short of relaunching this app.
        restoreOtherAudio(ramp: 0)
    }

    @objc func quit() { NSApp.terminate(nil) }
}
