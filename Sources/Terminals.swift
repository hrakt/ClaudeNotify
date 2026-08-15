import Cocoa

extension AppDelegate {
    // Two steps, in this order: switch the tab first, then raise the app, so the
    // window that comes forward is already showing the right session rather than
    // visibly flipping to it afterwards.
    func focusTerminal(for sessionID: String) {
        // Only a session with no record at all gets the legacy fallback. A
        // session recorded in a terminal this app does not know stays put:
        // raising some *other* terminal is worse than doing nothing, and the
        // banner already told the truth about where the session is.
        guard let record = sessionTerminal(sessionID) else {
            activate(legacyTerminal)
            return
        }
        guard let app = record.app else { return }

        // The tab switch is worth waiting on only when Orca is already up. With
        // Orca closed the CLI spends a couple of seconds discovering there is no
        // runtime, which reads as a dead click, so skip straight to launching.
        let running = !NSRunningApplication.runningApplications(
            withBundleIdentifier: app.bundleID).isEmpty

        guard running, record.program == "Orca", !record.handle.isEmpty else {
            activate(app)
            return
        }

        let handle = record.handle
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.switchOrcaTab(to: handle)
            DispatchQueue.main.async { self?.activate(app) }
        }
    }

    func activate(_ app: TerminalApp) {
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: app.bundleID).first {
            running.activate(options: [.activateAllWindows])
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // Orca ships no URL scheme and no AppleScript dictionary, but its CLI takes
    // the same per-tab handle the session was launched with, which is the one
    // supported way in from outside.
    func switchOrcaTab(to handle: String) {
        guard isValidOrcaHandle(handle),
              let cli = orcaCLICandidates.first(where: {
                  FileManager.default.isExecutableFile(atPath: $0)
              }) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["terminal", "switch", "--terminal", handle]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("ClaudeNotify: could not switch Orca tab: \(error.localizedDescription)")
        }
    }

    func isValidOrcaHandle(_ handle: String) -> Bool {
        guard handle.hasPrefix("term_"), handle.count < 80 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return handle.allSatisfy { allowed.contains($0) }
    }

    func sessionTTY(_ sessionID: String) -> String? {
        guard let raw = try? String(contentsOf: ttyDir.appendingPathComponent(sessionID), encoding: .utf8) else {
            return nil
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // Line one is TERM_PROGRAM, line two the Orca tab handle when there is one.
    // Terminals other than Orca write an empty second line, which reads back as
    // "raise the app, no tab to target".
    func sessionTerminal(_ sessionID: String) -> SessionTerminal? {
        guard !sessionID.isEmpty,
              let raw = try? String(contentsOf: terminalsDir.appendingPathComponent(sessionID),
                                    encoding: .utf8) else { return nil }

        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let program = lines.first, !program.isEmpty else { return nil }

        return SessionTerminal(program: program,
                               handle: lines.count > 1 ? lines[1] : "")
    }
}
