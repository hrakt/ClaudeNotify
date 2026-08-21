import Cocoa
import CoreAudio

// What drives the orange dot in the menu bar: an input device running somewhere
// on the system. macOS exposes no API for the dot itself, but it exposes what
// the dot is drawn from, and CoreAudio will call back on change rather than
// having to be asked. Reading this is not recording, so it needs no microphone
// permission and raises no prompt.
extension AppDelegate {
    // MARK: - Reading

    // Every input device, not just the default one. A call held on a USB
    // interface or a headset while the built-in mic stays the system default
    // would otherwise read as silence for its whole duration.
    func inputAudioDevices() -> [AudioDeviceID] {
        var address = audioProperty(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else { return [] }

        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &devices) == noErr else { return [] }

        return devices.filter { hasInputChannels($0) }
    }

    // An output-only device answers the running question too, and answers yes
    // whenever anything is playing, so the list has to be narrowed to devices
    // that can actually listen. Otherwise the completion sound itself would look
    // like a meeting starting.
    func hasInputChannels(_ device: AudioDeviceID) -> Bool {
        var address = audioProperty(kAudioDevicePropertyStreamConfiguration,
                                    scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }

        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).contains { $0.mNumberChannels > 0 }
    }

    // A device running is NOT the same as something recording, and the
    // difference is the whole reason this is two steps rather than one.
    // kAudioDevicePropertyDeviceIsRunningSomewhere trips on playback as readily
    // as on capture — measured here as an output device reading running=1 under
    // afplay while no process reported input — and any headset or audio
    // interface enumerates channels in both directions, so it passes the
    // input-capable filter. Trusting the device alone would mean music through
    // AirPods reads as a meeting for exactly as long as the music lasts.
    //
    // So the device answers the cheap question, "is anything using audio at
    // all", and the process list answers the real one.
    func micIsRunning() -> Bool {
        guard inputDeviceIsRunning() else { return false }
        guard #available(macOS 14.4, *) else {
            // Without the process API there is nothing more precise to ask. The
            // device signal is kept rather than dropping the feature, since a
            // meeting held through is worse than music occasionally read as one.
            if !loggedMeetingUnavailable {
                loggedMeetingUnavailable = true
                note("macOS 14.4+ needed to tell recording from playback; using the device signal")
            }
            return true
        }
        return processInputUsage().recording
    }

    func inputDeviceIsRunning() -> Bool {
        inputAudioDevices().contains { device in
            var address = audioProperty(kAudioDevicePropertyDeviceIsRunningSomewhere)
            var running: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else {
                return false
            }
            return running != 0
        }
    }

    // One pass answers both questions: whether anything is recording at all, and
    // whether any of it is an app worth naming. A process can hold the input
    // without reporting a bundle id, which still counts as recording.
    @available(macOS 14.4, *)
    func processInputUsage() -> (recording: Bool, app: String?) {
        var address = audioProperty(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return (false, nil) }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return (false, nil) }

        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &objects) == noErr else { return (false, nil) }

        var recording = false
        for object in objects where processIsRecording(object) {
            recording = true
            guard let bundle = processBundleID(object) else { continue }
            if let app = meetingApps.first(where: { bundle.hasPrefix($0.prefix) }) {
                return (true, app.name)
            }
        }
        return (recording, nil)
    }

    // MARK: - Listening

    // Two levels. The per-device listeners report a microphone starting or
    // stopping; the hardware-list listener reports devices themselves appearing
    // and disappearing, which happens every time headphones are plugged in, and
    // is the moment the per-device registrations have to be rebuilt against the
    // new list. Missing that is how a listener-based design quietly stops
    // working halfway through the afternoon.
    func startWatchingMicrophone() {
        var deviceList = audioProperty(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &deviceList, .main) { [weak self] _, _ in
                self?.rebuildDeviceListeners()
                self?.deviceActivityChanged()
            }

        rebuildDeviceListeners()
        startWatchingForcedMeeting()

        // A slow sweep behind the listeners. They have never been observed to
        // miss an edge, but a missed one would mean silence with no way back,
        // and a property read a minute costs nothing to rule that out.
        Timer.scheduledTimer(withTimeInterval: meetingSweepInterval, repeats: true) { [weak self] _ in
            self?.evaluateMeeting()
        }

        evaluateMeeting()
    }

    // The faked meeting is a file, and creating a file produces no CoreAudio
    // callback. Without this it would be driven only by the slow sweep, which
    // would make the documented ten second wait take up to two minutes — and
    // since this is the only way to exercise the notice without joining a real
    // call, anyone testing would reasonably conclude the feature was broken.
    func startWatchingForcedMeeting() {
        let descriptor = open(supportDir.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write],
            queue: .main)
        source.setEventHandler { [weak self] in self?.deviceActivityChanged() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        forcedMeetingWatcher = source
    }

    func rebuildDeviceListeners() {
        for (device, block) in audioListeners {
            var address = audioProperty(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, block)
        }
        audioListeners.removeAll()

        for device in inputAudioDevices() {
            var address = audioProperty(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.deviceActivityChanged()
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
                audioListeners.append((device, block))
            }
        }
    }

    // A transition is only the start of the question, since neither joining nor
    // leaving is acted on immediately. The exact moment is recorded here and the
    // decision scheduled for when the debounce is actually up, which is what
    // makes the wait ten seconds rather than "ten seconds, give or take however
    // long until the next sweep".
    func deviceActivityChanged() {
        evaluateMeeting()
        meetingCheckTimer?.invalidate()

        // An override outstanding is also waiting on the leave grace, since that
        // is what clears it and re-arms the next meeting. Waking on the shorter
        // debounce instead would leave the override uncleared with nothing
        // scheduled, so a call joined before the next sweep would ding all the
        // way through it.
        let waitingOnLeave = inMeeting || meetingOverridden
        let delay = (waitingOnLeave ? meetingEndGrace : meetingStartDebounce) + 0.5
        meetingCheckTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.evaluateMeeting()
        }
    }
}
