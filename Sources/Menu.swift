import Cocoa

extension AppDelegate {
    func showMenu() {
        rebuildMenu()
        updateUI()
        statusItem.menu = mainMenu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
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

        let speak = NSMenuItem(title: "Speak Project Name",
                               action: #selector(toggleSpeakProject),
                               keyEquivalent: "")
        speak.target = self
        speak.state = speakProject ? .on : .off
        menu.addItem(speak)

        let quiet = NSMenuItem(title: "Quiet During Meetings",
                               action: #selector(toggleQuietInMeetings),
                               keyEquivalent: "")
        quiet.target = self
        quiet.state = quietInMeetings ? .on : .off
        menu.addItem(quiet)

        if inMeeting {
            let held = heldCount()
            let status = NSMenuItem(
                title: held == 0
                    ? "In a meeting, holding notifications"
                    : "In a meeting, \(held) held",
                action: nil,
                keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        } else if meetingOverridden {
            let status = NSMenuItem(title: "Notifying anyway for this meeting",
                                    action: nil,
                                    keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        let waiting = waitingSessions()
        if !waiting.isEmpty {
            let status = NSMenuItem(
                title: "\(waiting.count) waiting on you",
                action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
            menu.addItem(actionItem("Mark All as Seen", #selector(markAllSeen)))
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

    func soundItem(for url: URL, current: String) -> NSMenuItem {
        let item = NSMenuItem(title: prettyName(url.deletingPathExtension().lastPathComponent),
                              action: #selector(selectSound(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = url
        item.state = url.resolvingSymlinksInPath().path == current ? .on : .off
        return item
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

        let waiting = Set(waitingSessions())
        for session in sessions {
            let assigned = assignedSound(for: session.id)
            // Marked in the list too, so the count in the menu bar can be turned
            // into "which ones" without opening every submenu.
            var title = (waiting.contains(session.id) ? "• " : "")
                + "\(session.project) · \(session.title)"
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

            let goTo = NSMenuItem(title: "Go to This Session",
                                  action: #selector(goToSession(_:)),
                                  keyEquivalent: "")
            goTo.target = self
            goTo.representedObject = session.id
            submenu.addItem(goTo)

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
}

extension AppDelegate {
    // The same jump the banner does, reachable from the menu. Useful on its own,
    // and it means the path can be exercised without waiting for a session to
    // finish something.
    @objc func markAllSeen() {
        for sessionID in waitingSessions() { clearWaiting(sessionID) }
        rebuildMenu()
        updateUI()
    }

    @objc func goToSession(_ sender: NSMenuItem) {
        guard let sessionID = sender.representedObject as? String else { return }
        focusTerminal(for: sessionID)
    }
}
