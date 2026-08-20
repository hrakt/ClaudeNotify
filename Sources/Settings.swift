import Cocoa

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
        let height: CGFloat = 656
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

        let duck = NSButton(checkboxWithTitle: "Lower other audio while the sound plays",
                            target: self,
                            action: #selector(settingsDuckChanged(_:)))
        duck.frame = NSRect(x: 20, y: height - 96, width: 380, height: 20)
        duck.toolTip = "Dips music and video for the length of the notification, "
            + "so it can be heard without being loud."
        content.addSubview(duck)
        settingsDuckCheckbox = duck

        let focus = NSButton(checkboxWithTitle: "Stay silent while a Focus is on",
                             target: self,
                             action: #selector(settingsFocusChanged(_:)))
        focus.frame = NSRect(x: 20, y: height - 120, width: 380, height: 20)
        focus.toolTip = "macOS already hides banners under a Focus but has no say over "
            + "the sound. This silences that too."
        content.addSubview(focus)
        settingsFocusCheckbox = focus

        let perProject = NSButton(checkboxWithTitle: "A different sound for each project",
                                  target: self,
                                  action: #selector(settingsProjectSoundsChanged(_:)))
        perProject.frame = NSRect(x: 20, y: height - 144, width: 380, height: 20)
        perProject.toolTip = "Gives every project its own tone, so which one finished is "
            + "audible without looking."
        content.addSubview(perProject)
        settingsProjectSoundsCheckbox = perProject

        let login = NSButton(checkboxWithTitle: "Open at login",
                             target: self,
                             action: #selector(toggleLaunchAtLogin(_:)))
        login.frame = NSRect(x: 20, y: height - 168, width: 380, height: 20)
        content.addSubview(login)
        settingsLoginCheckbox = login

        content.addSubview(label("Volume", NSRect(x: 20, y: height - 202, width: 120, height: 20)))
        let volume = NSSlider(frame: NSRect(x: 150, y: height - 204, width: 300, height: 24))
        volume.minValue = 0.1
        volume.maxValue = 1.0
        volume.isContinuous = true
        volume.target = self
        volume.action = #selector(settingsVolumeChanged(_:))
        content.addSubview(volume)
        settingsVolumeSlider = volume

        let volumeValue = label("", NSRect(x: 460, y: height - 202, width: 60, height: 20))
        content.addSubview(volumeValue)
        settingsVolumeLabel = volumeValue

        content.addSubview(label("Remind me again", NSRect(x: 20, y: height - 240, width: 130, height: 20)))
        let cadence = NSPopUpButton(frame: NSRect(x: 150, y: height - 244, width: 200, height: 26))
        for choice in reminderChoices { cadence.addItem(withTitle: choice.title) }
        cadence.target = self
        cadence.action = #selector(settingsCadenceChanged(_:))
        content.addSubview(cadence)
        settingsCadencePopup = cadence

        content.addSubview(label("Repeats", NSRect(x: 20, y: height - 278, width: 130, height: 20)))
        let repeats = NSPopUpButton(frame: NSRect(x: 150, y: height - 282, width: 200, height: 26))
        for choice in reminderLimitChoices { repeats.addItem(withTitle: choice.title) }
        repeats.target = self
        repeats.action = #selector(settingsRepeatsChanged(_:))
        content.addSubview(repeats)
        settingsRepeatsPopup = repeats

        let divider = NSBox(frame: NSRect(x: 20, y: height - 304, width: width - 40, height: 1))
        divider.boxType = .separator
        content.addSubview(divider)

        content.addSubview(label("Notification sound", NSRect(x: 20, y: height - 336, width: 250, height: 18), bold: true))

        let search = NSSearchField(frame: NSRect(x: 20, y: height - 370, width: width - 40, height: 24))
        search.placeholderString = "Search sounds"
        search.target = self
        search.action = #selector(settingsSearchChanged(_:))
        content.addSubview(search)

        let scroll = NSScrollView(frame: NSRect(x: 20, y: 60, width: width - 40, height: height - 442))
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
        settingsDuckCheckbox?.state = duckOtherAudio ? .on : .off
        // Offering a tick for something macOS will not let the app see would be
        // a promise it cannot keep, so the box says why instead.
        let canSeeFocus = focusIsReadable()
        settingsProjectSoundsCheckbox?.state = distinctProjectSounds ? .on : .off
        settingsLoginCheckbox?.state = launchesAtLogin ? .on : .off
        settingsLoginCheckbox?.title = loginItemNote().map { "Open at login — \($0)" }
            ?? "Open at login"

        settingsFocusCheckbox?.state = (respectFocus && canSeeFocus) ? .on : .off
        settingsFocusCheckbox?.isEnabled = canSeeFocus
        settingsFocusCheckbox?.title = canSeeFocus
            ? "Stay silent while a Focus is on"
            : "Stay silent while a Focus is on — needs Full Disk Access"
        // Nothing to offer if macOS has stopped providing the call at all, and a
        // tickable box that does nothing is worse than a greyed-out one.
        settingsDuckCheckbox?.isEnabled = audioDeviceDuck != nil
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

    @objc func settingsDuckChanged(_ sender: NSButton) {
        try? (sender.state == .on ? "1" : "0")
            .write(to: duckAudioURL, atomically: true, encoding: .utf8)

        // Turning it off while a dip is in progress has to put the level back,
        // or the setting that stops it lowering audio leaves audio lowered.
        if sender.state == .off { restoreOtherAudio() }

        // Preview it the way it will actually happen, which is the only way to
        // judge whether the dip is worth having.
        playLoweringOthers(selectedSound)
    }

    @objc func settingsProjectSoundsChanged(_ sender: NSButton) {
        try? (sender.state == .on ? "1" : "0")
            .write(to: distinctProjectSoundsURL, atomically: true, encoding: .utf8)
        // Assign straight away rather than waiting for the next sweep, so the
        // very next ding already sounds like its project.
        ensureProjectSounds()
        if sender.state == .on, let first = liveSessions().first {
            playLoweringOthers(projectSound(for: first.id) ?? selectedSound)
        }
    }

    @objc func settingsFocusChanged(_ sender: NSButton) {
        try? (sender.state == .on ? "1" : "0")
            .write(to: respectFocusURL, atomically: true, encoding: .utf8)
        // The hook reads a flag rather than the preference, so it has to be
        // brought back in line straight away or the change waits for the timer.
        refreshFocusFlag()
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
