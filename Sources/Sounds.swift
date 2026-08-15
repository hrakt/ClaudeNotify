import Cocoa
import UniformTypeIdentifiers

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

    func play(_ url: URL, volume: Double? = nil) {
        preview?.stop()
        preview = NSSound(contentsOf: url, byReference: true)
        preview?.volume = Float(volume ?? currentVolume)
        preview?.play()
    }
}
