import Cocoa
import UserNotifications

extension AppDelegate {
    func startWatchingPending() {
        let descriptor = open(pendingDir.path, O_EVTONLY)
        guard descriptor >= 0 else {
            note("could not watch \(pendingDir.path)")
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

    // Delivered banners outlive the thing they announced. Once a session has been
    // dealt with, its old cards are saying something that is no longer true, so
    // they are taken down rather than left to accumulate. This is what keeps the
    // count in the menu bar and the list in Notification Center telling the same
    // story.
    func clearDeliveredNotifications(for sessionID: String) {
        guard !sessionID.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let mine = delivered
                .filter { $0.request.content.threadIdentifier == sessionID }
                .map { $0.request.identifier }
            guard !mine.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: mine)
        }
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

            // What the hook knew: which event this was, and whether it stood
            // aside and so owes a ding.
            let meta = pendingMetaDir.appendingPathComponent(sessionID)
            let lines = ((try? String(contentsOf: meta, encoding: .utf8)) ?? "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let owesSound = lines.count > 1 && lines[1] == "owed"
            let needsYou = lines.first == "Notification"
            try? fm.removeItem(at: meta)

            // Draining also happens at launch, where the queue may hold whatever
            // a force quit left behind. Replaying those is worse than losing
            // them: a ding for work that finished yesterday, and one that
            // arrives while the bell says muted, since the mute is enforced in
            // the hook and the hook is long gone for a file already written.
            let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            let stale = Date().timeIntervalSince(written) > liveStaleWindow

            // Held rather than posted: a banner during a call is the thing being
            // avoided, and one summary afterwards says the same thing better.
            // Keyed by session id, so a session finishing twice is held once.
            if inMeeting {
                markWaiting(sessionID)
                try? fm.createDirectory(at: deferredDir, withIntermediateDirectories: true)
                let held = deferredDir.appendingPathComponent(sessionID)
                try? fm.removeItem(at: held)
                try? fm.moveItem(at: file, to: held)
                continue
            }

            try? fm.removeItem(at: file)
            guard !stale else { continue }

            // Recorded whether or not anything is audible: this is the half that
            // still works while muted.
            markWaiting(sessionID)

            // A Focus costs the sound and the announcement, not the banner:
            // macOS holds banners itself while one is on, and the ding is the
            // half it has no say over.
            if owesSound, !isMuted, !focusIsOn() {
                // A per-session sound still wins over the attention sound: it
                // was chosen to tell sessions apart, which is the more specific
                // thing to be saying.
                let sound = assignedSound(for: sessionID)
                    ?? (needsYou ? attentionSound
                        : (projectSound(for: sessionID) ?? selectedSound))
                playLoweringOthers(sound, volume: sessionVolume(for: sessionID))

                // After the sound, not instead of it: the chime is what gets
                // your attention and the name is what it then tells you.
                if speakProject, let project = projectName(for: sessionID) {
                    let delay = max(preview?.duration ?? 0, 0.3)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self else { return }
                        self.speak(self.spokenProject(project))
                    }
                }
            }

            postFinishedNotification(for: sessionID, label: label, needsYou: needsYou)
        }
    }

    func postFinishedNotification(for sessionID: String,
                                  label: String? = nil,
                                  reminder: String? = nil,
                                  needsYou: Bool = false) {
        let resolved = (label?.isEmpty == false) ? label! : describeSession(sessionID)

        // The body promises only what the click can deliver: an unknown
        // terminal cannot be raised, so it is named rather than offered.
        let destination: String
        switch sessionTerminal(sessionID) {
        case .none:
            destination = "Click to switch to your terminal."
        case .some(let record) where record.app == nil:
            destination = "This session is in \(record.displayName)."
        case .some(let record) where record.program == "Orca" && !record.handle.isEmpty:
            destination = "Click to open this tab in \(record.displayName)."
        case .some(let record):
            destination = "Click to switch to \(record.displayName)."
        }

        deliver(sessionID: sessionID,
                title: needsYou ? "Claude needs you"
                    : (reminder == nil ? "Claude finished" : "Claude still waiting"),
                subtitle: resolved,
                body: reminder.map { "\($0). \(destination)" } ?? destination,
                fallbackSubtitle: resolved,
                fallbackBody: reminder,
                icon: needsYou ? .needsYou : .finished)
    }

    func postSummaryNotification(sessionID: String, title: String, body: String) {
        deliver(sessionID: sessionID,
                title: title,
                subtitle: body,
                body: "Click to go to the most recent.",
                fallbackSubtitle: body,
                fallbackBody: title,
                icon: .finished)
    }

    // Every failure path ends in a visible banner. Permission can be refused at
    // launch, revoked later, or the post itself can fail, and none of those may
    // result in silence: the app raises its own plain banner instead.
    func deliver(sessionID: String,
                 title: String,
                 subtitle: String,
                 body: String,
                 fallbackSubtitle: String,
                 fallbackBody: String?,
                 category: String? = nil,
                 info: [String: Any] = [:],
                 icon: NotificationIcon? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let self else { return }

            guard settings.authorizationStatus == .authorized else {
                DispatchQueue.main.async {
                    self.recordNotificationPermission(false)
                    self.postFallbackBanner(fallbackSubtitle, reminder: fallbackBody)
                }
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = subtitle
            content.body = body
            content.userInfo = info.merging(["session": sessionID]) { current, _ in current }

            // Grouped by session, so Notification Center collapses repeats into
            // one card with a count instead of a column of near-identical ones.
            // Twelve cards for five situations is a pile, not a list.
            if !sessionID.isEmpty { content.threadIdentifier = sessionID }
            if let category { content.categoryIdentifier = category }
            if let icon, let image = self.attachment(icon) { content.attachments = [image] }

            let request = UNNotificationRequest(
                identifier: "\(sessionID)-\(Date().timeIntervalSince1970)",
                content: content,
                trigger: nil)

            UNUserNotificationCenter.current().add(request) { error in
                guard let error else { return }
                note("could not post notification: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.postFallbackBanner(fallbackSubtitle, reminder: fallbackBody)
                }
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
        // Both buttons are scoped to the meeting they were posted about, since a
        // delivered banner outlives it. Muting the app days later off a stale
        // notice is the same class of mistake as silencing the wrong call.
        let announced = response.notification.request.content.userInfo["meeting"] as? Int

        if response.actionIdentifier == stayQuietActionID {
            if announced == meetingID { stayQuiet() }
            completionHandler()
            return
        }

        if response.actionIdentifier == meetingOverrideActionID {
            if announced == meetingID { overrideMeeting() }
            completionHandler()
            return
        }

        // The meeting notice carries no session, and falling through would raise
        // a terminal at random on a banner that is not about one.
        guard let sessionID = response.notification.request.content.userInfo["session"] as? String,
              !sessionID.isEmpty else {
            completionHandler()
            return
        }

        focusTerminal(for: sessionID)
        completionHandler()
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

    func checkReminders() {
        let minutes = reminderMinutes
        // A meeting is exactly the situation a nag should stay out of, and the
        // summary afterwards already covers what was missed.
        guard minutes > 0, !isMuted, !inMeeting else { return }

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
            playLoweringOthers(assignedSound(for: session.id) ?? selectedSound,
                               volume: sessionVolume(for: session.id))
        }
    }

}
