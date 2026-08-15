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
            if meetingAppPrefixes.contains(where: { bundle.hasPrefix($0) }) { return bundle }
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
            // from days ago and skips the debounce entirely.
            micLiveSince = nil
            micIdleSince = nil
            return
        }

        let now = Date()
        let live = meetingAppOnMicrophone() != nil

        if live {
            micIdleSince = nil
            if micLiveSince == nil { micLiveSince = now }
            if !inMeeting, now.timeIntervalSince(micLiveSince ?? now) >= meetingStartDebounce {
                beginMeeting()
            }
        } else {
            micLiveSince = nil
            if micIdleSince == nil { micIdleSince = now }
            if inMeeting, now.timeIntervalSince(micIdleSince ?? now) >= meetingEndGrace {
                endMeeting()
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
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: inMeetingURL.path, contents: nil)
        updateUI()
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
