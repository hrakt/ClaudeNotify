import Cocoa

// Two small things that both answer "should this make a noise, and what should
// it say" — kept together because they are the only two places the app decides
// to stay quiet for reasons that are not the user reaching for the bell.
extension AppDelegate {
    // MARK: - Focus

    var respectFocus: Bool {
        guard let raw = try? String(contentsOf: respectFocusURL, encoding: .utf8) else { return true }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) != "0"
    }

    // macOS hides banners under a Focus and does nothing about sound, which is
    // the half that actually interrupts. The state is not exposed by any public
    // API that does not want a permission prompt of its own, and this app has
    // got this far without asking for anything, so it reads the file the system
    // keeps instead.
    //
    // Undocumented, therefore read at arm's length: a missing file, unreadable
    // JSON, or a shape that has changed all mean "not focused". The cost of
    // being wrong that way is a ding you did not want; the cost of the other way
    // is silence you cannot explain.
    // Whether the system's Focus file can be read at all. macOS keeps it inside a
    // directory it withholds from ordinary apps, so this is false until the app
    // is given Full Disk Access — and false is indistinguishable from "no Focus
    // is on" if you only look at the file, which is why it is asked separately
    // and asked once.
    func focusIsReadable() -> Bool {
        if let known = focusReadable { return known }
        let readable = (try? FileManager.default.contentsOfDirectory(
            atPath: focusAssertionsURL.deletingLastPathComponent().path)) != nil
        focusReadable = readable
        if !readable {
            note("Focus state is not readable without Full Disk Access; "
                + "the sound will play through a Focus until that is granted")
        }
        return readable
    }

    func focusIsOn() -> Bool {
        guard respectFocus, focusIsReadable() else { return false }

        // Read failures are reported once. This file sits inside a directory
        // macOS may withhold from a bundled app, and a feature that silently
        // does nothing is the hardest kind to diagnose from the outside.
        // Absent means no Focus is on: macOS writes it when one starts.
        guard let data = try? Data(contentsOf: focusAssertionsURL) else { return false }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        // The file survives a Focus ending, holding an empty record list, so
        // its mere existence is not the answer.
        guard let records = root["storeAssertionRecords"] as? [[String: Any]] else { return false }
        return !records.isEmpty
    }

    // The hook cannot parse JSON without a lot of shell, and it needs the answer
    // in the one case where it plays the ding itself. So the app keeps a flag
    // for it, the same arrangement meetings already use.
    func refreshFocusFlag() {
        let fm = FileManager.default
        if focusIsOn() {
            fm.createFile(atPath: inFocusURL.path, contents: nil)
        } else {
            try? fm.removeItem(at: inFocusURL)
        }
    }

    // MARK: - Announcing the project

    // Off unless asked for. Spoken words cost more attention than a chime, and
    // something that talks on every turn across several sessions should be
    // opted into rather than discovered.
    var speakProject: Bool {
        guard let raw = try? String(contentsOf: speakProjectURL, encoding: .utf8) else { return false }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    @objc func toggleSpeakProject() {
        let next = speakProject ? "0" : "1"
        try? next.write(to: speakProjectURL, atomically: true, encoding: .utf8)
        if next == "1" { speak(spokenProject("ClaudeNotify")) }
    }

    // The working directory's last component, which in a project-per-folder
    // setup is exactly the name shown in the sidebar: cam-fe, cam-api.
    func projectName(for sessionID: String) -> String? {
        guard !sessionID.isEmpty else { return nil }
        let cwd = (try? String(contentsOf: liveDir.appendingPathComponent(sessionID), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let cwd, !cwd.isEmpty { return URL(fileURLWithPath: cwd).lastPathComponent }

        guard let transcript = transcriptURL(for: sessionID),
              let recorded = lastJSONValue("cwd", in: tailText(of: transcript) ?? "") else { return nil }
        return URL(fileURLWithPath: recorded).lastPathComponent
    }

    // A folder name is not a phrase. Hyphens read as silence, camel case runs
    // together, and the short pieces in this kind of name are initialisms rather
    // than words — "cam-fe" is "cam F E", not a word rhyming with cafe.
    // prettyName already does the splitting for the menu, so this only has to
    // decide which pieces are letters.
    func spokenProject(_ name: String) -> String {
        prettyName(name)
            .split(separator: " ")
            .map { part -> String in
                let word = String(part)
                guard word.count <= 2 || spokenAsLetters.contains(word.lowercased()) else {
                    return word
                }
                return word.uppercased().map(String.init).joined(separator: " ")
            }
            .joined(separator: " ")
    }

    func speak(_ text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-r", "220", text]
        try? process.run()
    }
}
