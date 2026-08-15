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

    func audioProperty(_ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    // The microphone being live is the whole test. It is the same thing the
    // orange dot in the menu bar is drawn from, so what the app considers a
    // meeting is exactly what macOS is already telling you about itself, with
    // nothing to keep in sync and no app it can fail to have heard of.
    //
    // The cost is that dictation and voice memos count too. Three things make
    // that survivable rather than annoying: joining takes ten unbroken seconds,
    // which most dictation never reaches; nothing is announced unless a session
    // is actually running to be held back; and when something is announced it
    // arrives with a button that undoes it.
    func detectedActivity() -> String? {
        // Testing affordance. The rest of this cannot be exercised without
        // joining a real call, which makes the one notification the user sees
        // least testable part of the app. `touch ~/.claude/claudenotify/
        // force-meeting` stands in for a detection; delete it to end the
        // meeting. Opt-in by creating a file, so it cannot fire by accident.
        if FileManager.default.fileExists(atPath: forceMeetingURL.path) {
            return "Meeting in a test"
        }

        guard micIsRunning() else { return nil }

        // Naming is best-effort and detection does not depend on it, so an
        // unrecognised app still holds notifications; it is just described by
        // what is true rather than by a guess at what it is for.
        if #available(macOS 14.4, *), let app = processInputUsage().app {
            return "Meeting in \(app)"
        }
        return "Your microphone is in use"
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
        let detected = detectedActivity()

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
                if inMeeting { endMeeting(micWentIdle: true) }
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

        // Nothing running means nothing to hold back. The microphone goes live
        // for plenty of things that are not meetings — dictation, a voice
        // message, a recorder in a page — and announcing a hold in that state
        // trades a silent false positive for a banner that interrupts to say
        // nothing is being interrupted.
        guard !liveSessions().isEmpty else { return }

        meetingNoticePosted = true
        deliver(sessionID: "",
                title: app,
                subtitle: "Holding Claude notifications until it ends",
                body: "Sounds and banners resume by themselves.",
                fallbackSubtitle: app,
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

    // `micWentIdle` distinguishes the meeting actually ending from the other
    // three ways this is reached — the override, the setting being switched off,
    // and the feature being disabled mid-call. Only the first has anything to
    // announce. Without it, pressing Notify Anyway answers you with "your
    // microphone is free again" while you are still on the call, offering a Stay
    // Quiet button that does the exact opposite of what you just asked for.
    func endMeeting(micWentIdle: Bool = false) {
        let wasInMeeting = inMeeting
        let announced = meetingNoticePosted
        inMeeting = false
        meetingNoticePosted = false
        try? FileManager.default.removeItem(at: inMeetingURL)

        if wasInMeeting {
            // The summary already says notifications are back, so a second
            // banner saying the same thing would be noise. Only a meeting that
            // held nothing needs telling.
            let reported = postDeferredSummary()
            if micWentIdle, announced, !reported { postResumedNotice() }
        }
        updateUI()
    }

    // The other half of the promise. Having been told notifications were being
    // held, you are told when they are not, so the quiet has a visible end
    // rather than just an absence you eventually stop noticing.
    //
    // Only ever sent when the hold was announced in the first place. A detection
    // that never said anything — muted, or nothing running to hold — has nothing
    // to report the end of, and announcing one would make every stray minute of
    // dictation cost a banner.
    func postResumedNotice() {
        guard !isMuted else { return }

        deliver(sessionID: "",
                title: "Notifications are back on",
                subtitle: "Your microphone is free again",
                body: "Nothing finished while you were away.",
                fallbackSubtitle: "Notifications are back on",
                fallbackBody: "Your microphone is free again",
                category: meetingEndedCategoryID,
                info: ["meeting": meetingID])
    }

    // The inverse of Notify Anyway: the detection was right that you were busy
    // but wrong that you are finished, so this keeps the quiet going. It sets
    // the ordinary mute rather than inventing a third state, which means the
    // bell shows it and one click on the bell undoes it.
    func stayQuiet() {
        try? FileManager.default.createDirectory(at: flagURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: flagURL.path, contents: nil)
        updateUI()
    }

    // One banner for the whole meeting rather than a burst of them, since the
    // useful question coming out of a call is what finished, not how often.
    // Reports whether it had anything to say, so the caller knows whether the
    // end of the meeting has already been announced.
    @discardableResult
    func postDeferredSummary() -> Bool {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: deferredDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]), !files.isEmpty else { return false }

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
        guard let newest = held.first else { return false }
        let title = held.count == 1
            ? "Claude finished during your meeting"
            : "Claude finished \(held.count) sessions during your meeting"
        let body = held.count == 1
            ? newest.label
            : held.prefix(4).map { $0.label }.joined(separator: ", ")

        postSummaryNotification(sessionID: newest.id, title: title, body: body)
        return true
    }
}
