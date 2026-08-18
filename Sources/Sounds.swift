import Cocoa
import CoreAudio
import UniformTypeIdentifiers

// The ducking call itself. macOS ships it — it is what Siri and VoiceOver use to
// dip your music while they speak — but it is not in any public header, so it is
// looked up by symbol rather than linked against. Everything that uses it treats
// a failed lookup as "no ducking", which is what a future macOS removing it
// would look like: the ding still plays, it just no longer gets out of the way.
typealias AudioDeviceDuckFn =
    @convention(c) (AudioDeviceID, Float32, UnsafePointer<AudioTimeStamp>?, Float32) -> OSStatus

let audioDeviceDuck: AudioDeviceDuckFn? = {
    // RTLD_DEFAULT: CoreAudio is already linked, so this searches what is loaded
    // rather than opening anything new.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioDeviceDuck") else {
        NSLog("ClaudeNotify: AudioDeviceDuck unavailable; other audio will not be lowered")
        return nil
    }
    return unsafeBitCast(symbol, to: AudioDeviceDuckFn.self)
}()

extension AppDelegate {
    func soundList(in directory: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return contents
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func prettyName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "-EncoreInfinitum", with: "")
        name = name.replacingOccurrences(of: "_", with: " ")
        name = name.replacingOccurrences(of: "-", with: " ")

        var spaced = ""
        var previous: Character?
        for character in name {
            if let previous, character.isUppercase, previous.isLowercase || previous.isNumber {
                spaced.append(" ")
            }
            spaced.append(character)
            previous = character
        }

        name = spaced.trimmingCharacters(in: .whitespaces)
        guard let first = name.first else { return raw }
        return first.uppercased() + name.dropFirst()
    }

    func assignedSound(for sessionID: String) -> URL? {
        let pointer = sessionSoundsDir.appendingPathComponent(sessionID)
        guard let raw = try? String(contentsOf: pointer, encoding: .utf8) else { return nil }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // A session with no override follows the global slider, so the absence of a
    // file is meaningful and is not the same as storing the current level.
    func sessionVolume(for sessionID: String) -> Double? {
        let pointer = sessionVolumesDir.appendingPathComponent(sessionID)
        guard let raw = try? String(contentsOf: pointer, encoding: .utf8),
              let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return min(max(value, 0.1), 1.0)
    }

    @objc func selectSound(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        try? url.path.write(to: soundPointerURL, atomically: true, encoding: .utf8)
        play(url)
        rebuildMenu()
        updateUI()
    }

    @objc func addSound() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose audio files to add to your ClaudeNotify sounds."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }

        var lastAdded: URL?
        for source in panel.urls {
            if let copied = copyIntoLibrary(source) { lastAdded = copied }
        }

        if let added = lastAdded {
            try? added.path.write(to: soundPointerURL, atomically: true, encoding: .utf8)
            play(added)
        }
        rebuildMenu()
        updateUI()
    }

    func copyIntoLibrary(_ source: URL) -> URL? {
        let fm = FileManager.default
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var destination = soundsDir.appendingPathComponent(source.lastPathComponent)

        var counter = 2
        while fm.fileExists(atPath: destination.path) {
            destination = soundsDir.appendingPathComponent("\(base) \(counter).\(ext)")
            counter += 1
        }

        do {
            try fm.copyItem(at: source, to: destination)
            return destination
        } catch {
            presentError("Couldn't add \(source.lastPathComponent)", error.localizedDescription)
            return nil
        }
    }

    @objc func revealSoundsFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: soundsDir.path)
    }

    @objc func playTestSound() {
        play(selectedSound)
    }

    var attentionSound: URL {
        guard let raw = try? String(contentsOf: attentionSoundPointerURL, encoding: .utf8) else {
            return defaultAttentionSound
        }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return defaultAttentionSound
        }
        return URL(fileURLWithPath: path)
    }

    var duckOtherAudio: Bool {
        guard let raw = try? String(contentsOf: duckAudioURL, encoding: .utf8) else { return true }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }

    func defaultOutputDevice() -> AudioDeviceID? {
        var address = audioProperty(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }

    // Ducking has to be done by whatever plays the sound, since the point is to
    // dip everything *except* this. That is why the completion ding moves into
    // the app when this is on: the hook's afplay is a separate process, and
    // ducking from here would dip that too.
    func playLoweringOthers(_ url: URL, volume: Double? = nil) {
        guard duckOtherAudio, let duck = audioDeviceDuck, let device = defaultOutputDevice() else {
            play(url, volume: volume)
            return
        }

        // Output can change between one ding and the next — headphones going in
        // is exactly the moment a second session lands. Ducking the new device
        // while the old one is still held would cancel the old one's restore and
        // strand it at a quarter volume for good.
        if let held = duckedDevice, held != device {
            audioDeviceDuck?(held, 1.0, nil, duckRamp)
        }

        duck(device, duckedLevel, nil, duckRamp)
        play(url, volume: volume)

        // Two sounds close together must not have the first one's restore cut
        // the second one short, so only the most recent duck restores.
        duckGeneration &+= 1
        let generation = duckGeneration
        duckedDevice = device

        let hold = max(preview?.duration ?? 0, 0.5) + Double(duckRamp) + 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self, self.duckGeneration == generation else { return }
            self.restoreOtherAudio()
        }
    }

    // Whatever else happens, the dip must not outlive the ding. Left in place it
    // would quietly hold every other app at a quarter volume with nothing on
    // screen to explain why, and no obvious way to undo it.
    // The ramp is a parameter because quitting cannot afford one: the process
    // exits the instant this returns, and a level still on its way back up when
    // that happens is the thing this exists to prevent.
    func restoreOtherAudio(ramp: Float32 = duckRamp) {
        guard let device = duckedDevice, let duck = audioDeviceDuck else { return }
        duck(device, 1.0, nil, ramp)
        duckedDevice = nil
    }

    func play(_ url: URL, volume: Double? = nil) {
        preview?.stop()
        preview = NSSound(contentsOf: url, byReference: true)
        preview?.volume = Float(volume ?? currentVolume)
        preview?.play()
    }
}
