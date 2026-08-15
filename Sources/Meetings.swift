import Cocoa
import CoreAudio
import UserNotifications

extension AppDelegate {
    var quietInMeetings: Bool {
        guard let raw = try? String(contentsOf: quietInMeetingsURL, encoding: .utf8) else {
            return true
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }

    @objc func toggleQuietInMeetings() {
        let next = quietInMeetings ? "0" : "1"
        try? next.write(to: quietInMeetingsURL, atomically: true, encoding: .utf8)

        // Turning it off mid-meeting has to release what is being held, or the
        // held banners wait for an end that will never be detected.
        if next == "0" { endMeeting() }
        evaluateMeeting()
    }

    // Polled rather than driven by a property listener: the default input device
    // changes when headphones come and go, which means tearing down and
    // re-registering the listener on the right object each time. Two property
    // reads every few seconds costs nothing and cannot drift out of sync.
    func startWatchingMicrophone() {
        Timer.scheduledTimer(withTimeInterval: meetingPollInterval, repeats: true) { [weak self] _ in
            self?.evaluateMeeting()
        }
        evaluateMeeting()
    }

    func audioProperty(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    // Asked per process rather than per device. Gating this on whether the
    // *default* input is running looks like a cheap shortcut but silently loses
    // every meeting held on an explicitly chosen microphone, which Zoom, Teams
    // and Meet all let you pick. The process scan is authoritative on its own,
    // and the prefix list is what keeps dictation out.
    func meetingAppOnMicrophone() -> String? {
        // Testing affordance. The rest of this cannot be exercised without
        // joining a real call, which makes the one notification the user sees
        // least testable part of the app. `touch ~/.claude/claudenotify/
        // force-meeting` stands in for a detection; delete it to end the
        // meeting. Opt-in by creating a file, so it cannot fire by accident.
        if FileManager.default.fileExists(atPath: forceMeetingURL.path) {
            return "a test"
        }

        guard #available(macOS 14.4, *) else {
            if !loggedMeetingUnavailable {
                loggedMeetingUnavailable = true
                NSLog("ClaudeNotify: meeting detection needs macOS 14.4 or later; staying off")
            }
            return nil
        }

        var address = audioProperty(kAudioHardwarePropertyProcessObjectList)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return nil }

        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &objects) == noErr else { return nil }

        for object in objects where processIsRecording(object) {
            guard let bundle = processBundleID(object) else { continue }
            if let app = meetingApps.first(where: { bundle.hasPrefix($0.prefix) }) {
                return app.name
            }
        }
        return nil
    }

    func processIsRecording(_ object: AudioObjectID) -> Bool {
        var address = audioProperty(kAudioProcessPropertyIsRunningInput)
        var running = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }

    // CoreAudio hands back a retained string, so it is taken as retained rather
    // than read through a CFString variable: doing the latter leaks one string
    // per process per poll, which at this cadence adds up.
    func processBundleID(_ object: AudioObjectID) -> String? {
        var address = audioProperty(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?

        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    // Debounced in both directions. Joining waits, so dictation cannot pass for
    // a meeting; leaving waits longer, so a moment of silence between speakers
    // cannot let a ding through mid-call.
    func evaluateMeeting() {
        guard quietInMeetings else {
            if inMeeting { endMeeting() }
            // Cleared, not frozen: leaving these set means re-enabling while a
            // listed app happens to hold the mic compares against a timestamp
            // from days ago and skips the debounce entirely. The override goes
            // with them, or switching the feature off while one is in effect
            // strands it: the menu would claim to be notifying anyway for a
            // meeting that ended days ago, and switching the feature back on
            // during the same call would silently do nothing.
            micLiveSince = nil
            micIdleSince = nil
            meetingOverridden = false
            return
        }

        let now = Date()
        let detected = meetingAppOnMicrophone()

        if let detected {
            micIdleSince = nil
            if micLiveSince == nil { micLiveSince = now }
            // Overridden means you already answered this meeting's question, so
            // it is not asked again until the call actually ends.
            if !inMeeting, !meetingOverridden,
               now.timeIntervalSince(micLiveSince ?? now) >= meetingStartDebounce {
                beginMeeting()
            }

            // The notice can decline to post at the moment a meeting starts:
            // muting silences everything anyway, and with no session running
            // there is nothing to hold back. Both of those change during a
            // call — a timed mute runs out, a session gets started — and either
            // would otherwise leave notifications held with nothing having said
            // so and no button to escape with. So it is retried, not posted
            // once and forgotten.
            if inMeeting, !meetingNoticePosted {
                postMeetingNotice(detectedIn: detected)
            }
        } else {
            micLiveSince = nil
            if micIdleSince == nil { micIdleSince = now }
            if now.timeIntervalSince(micIdleSince ?? now) >= meetingEndGrace {
                if inMeeting { endMeeting() }
                // The override belongs to one meeting. Clearing it here, once
                // the mic has genuinely been idle, is what re-arms the next one.
                meetingOverridden = false
            }
        }
    }

    func heldCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(
            at: deferredDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]))?.count ?? 0
    }

    func beginMeeting() {
        inMeeting = true
        meetingNoticePosted = false
        // Identifies this meeting for the lifetime of its notice. Notification
        // Center keeps delivered banners around, so without it the button on a
        // notice from a finished call would silence the one happening now.
        meetingID += 1
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: inMeetingURL.path, contents: nil)
        updateUI()
    }

    // Going quiet without saying so is indistinguishable from being broken, and
    // this app's whole job is making noise. So the one notification allowed
    // through is the one announcing that the rest are being held, and it carries
    // the way out with it: a detection this owns can be wrong, and being wrong
    // must cost a click rather than a missed afternoon.
    func postMeetingNotice(detectedIn app: String) {
        // Muting already silences everything, so a notice about silence would be
        // both redundant and the only banner to survive the mute.
        guard !isMuted else { return }

        // Nothing running means nothing to hold back, and a browser in this list
        // takes the microphone for plenty of things that are not meetings: a
        // dictation field, a voice message, a recorder in a page. Announcing a
        // hold in that state trades a silent false positive for a banner that
        // interrupts to say nothing is being interrupted.
        guard !liveSessions().isEmpty else { return }

        meetingNoticePosted = true
        deliver(sessionID: "",
                title: "Meeting in \(app)",
                subtitle: "Holding Claude notifications until it ends",
                body: "Sounds and banners resume by themselves.",
                fallbackSubtitle: "Meeting in \(app)",
                // The fallback banner is a plain osascript one and cannot carry
                // a button, so it names the way out rather than offering it.
                fallbackBody: "Holding notifications. Quiet During Meetings in the menu overrides it",
                category: meetingCategoryID,
                info: ["meeting": meetingID])
    }

    // Deliberately scoped to this meeting rather than to the setting. Someone
    // reaching for this wants the notifications they are waiting on now, not to
    // turn the feature off and rediscover a month later why calls got noisy.
    func overrideMeeting() {
        meetingOverridden = true
        endMeeting()
    }

    func endMeeting() {
        let wasInMeeting = inMeeting
        inMeeting = false
        try? FileManager.default.removeItem(at: inMeetingURL)
        if wasInMeeting { postDeferredSummary() }
        updateUI()
    }

    // One banner for the whole meeting rather than a burst of them, since the
    // useful question coming out of a call is what finished, not how often.
    func postDeferredSummary() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: deferredDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]), !files.isEmpty else { return }

        // Anything held from long enough ago is not news any more: the app was
        // quit mid-meeting and is only now starting again. Those are discarded
        // rather than announced, so a relaunch cannot report yesterday's work as
        // though it just finished.
        let cutoff = Date().addingTimeInterval(-liveStaleWindow)
        let held = files
            .map { file -> (id: String, label: String, at: Date) in
                let label = (try? String(contentsOf: file, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? Date.distantPast
                return (file.lastPathComponent,
                        label.isEmpty ? describeSession(file.lastPathComponent) : label,
                        at)
            }
            .filter { $0.at > cutoff }
            .sorted { $0.at > $1.at }

        for file in files { try? fm.removeItem(at: file) }

        // Clicking goes to the most recent, which is the one still waiting.
        guard let newest = held.first else { return }
        let title = held.count == 1
            ? "Claude finished during your meeting"
            : "Claude finished \(held.count) sessions during your meeting"
        let body = held.count == 1
            ? newest.label
            : held.prefix(4).map { $0.label }.joined(separator: ", ")

        postSummaryNotification(sessionID: newest.id, title: title, body: body)
    }
}
