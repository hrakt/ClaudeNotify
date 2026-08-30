import Cocoa

extension AppDelegate {
    // Two steps, in this order: switch the tab first, then raise the app, so the
    // window that comes forward is already showing the right session rather than
    // visibly flipping to it afterwards.
    func focusTerminal(for sessionID: String) {
        // Going to a session is the clearest possible statement that you have
        // seen it, so it stops counting immediately rather than waiting for the
        // transcript to move.
        clearWaiting(sessionID)
        defer { updateUI() }

        note("click for session \(sessionID.prefix(8)) -> "
            + "\(sessionTerminal(sessionID)?.program ?? "no record")")

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

    // Three things happen here and the order matters. Since macOS 14 an app that
    // is not frontmost cannot simply raise another one: activation is
    // cooperative, and the request is dropped silently. Clicking a notification
    // does give this app the right to come forward, so it takes that first and
    // then hands it straight on, which is what makes the second call stick.
    //
    // openApplication is the fallback rather than the primary, because it also
    // launches the app, and launching a terminal you did not ask for is worse
    // than doing nothing.
    func activate(_ app: TerminalApp) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first

        if let running {
            NSApp.activate(ignoringOtherApps: true)
            let raised = running.activate(options: [.activateAllWindows])
            note("raising \(app.name) -> \(raised)")
            guard !raised else { return }
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
            note("no app installed for \(app.bundleID)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                note("could not open \(app.name): \(error.localizedDescription)")
            }
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
            note("could not switch Orca tab: \(error.localizedDescription)")
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
