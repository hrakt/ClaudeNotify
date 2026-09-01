import Cocoa

extension AppDelegate {
    // Just the name Claude gave the work, with no project glued to the front.
    // The project belongs in the notification's title where it cannot be
    // truncated, so the two are wanted separately rather than as one string.
    func sessionTitle(for sessionID: String) -> String? {
        guard let transcript = transcriptURL(for: sessionID) else { return nil }
        let title = lastJSONValue("aiTitle", in: tailText(of: transcript) ?? "")
        return (title?.isEmpty == false) ? title : nil
    }

    func describeSession(_ sessionID: String) -> String {
        let cwd = (try? String(contentsOf: liveDir.appendingPathComponent(sessionID), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var project = (cwd?.isEmpty == false) ? URL(fileURLWithPath: cwd!).lastPathComponent : ""
        var title = ""

        if let transcript = transcriptURL(for: sessionID) {
            let text = tailText(of: transcript) ?? ""
            title = lastJSONValue("aiTitle", in: text) ?? ""
            if project.isEmpty, let recorded = lastJSONValue("cwd", in: text) {
                project = URL(fileURLWithPath: recorded).lastPathComponent
            }
        }

        if !project.isEmpty && !title.isEmpty { return "\(project) · \(title)" }
        if !title.isEmpty { return title }
        if !project.isEmpty { return project }
        return "Claude Code"
    }

    // Transcripts reach tens of megabytes, so the title is read from the tail
    // rather than by parsing the file.
    func tailText(of url: URL, bytes: UInt64 = 200_000) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func lastJSONValue(_ key: String, in text: String) -> String? {
        let needle = "\"\(key)\":\""
        guard let found = text.range(of: needle, options: .backwards) else { return nil }
        let rest = text[found.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let value = String(rest[..<end])
        return value.isEmpty ? nil : value.replacingOccurrences(of: "\\\"", with: "\"")
    }

    func transcriptURL(for sessionID: String) -> URL? {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: transcriptsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return nil }

        for directory in dirs {
            let candidate = directory.appendingPathComponent("\(sessionID).jsonl")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    func liveSessions() -> [SessionInfo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: liveDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        let cutoff = Date().addingTimeInterval(-liveStaleWindow)
        var sessions: [SessionInfo] = []

        for file in files {
            let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey, .creationDateKey])
            guard let heartbeat = values?.contentModificationDate else { continue }

            guard heartbeat > cutoff else {
                try? fm.removeItem(at: file)
                continue
            }

            let id = file.lastPathComponent
            let cwd = (try? String(contentsOf: file, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // A session with no transcript yet has not been typed into, so the
            // only facts available are where it started and when.
            var title = "New session, \(startedLabel(values?.creationDate ?? heartbeat))"
            var project = (cwd?.isEmpty == false) ? URL(fileURLWithPath: cwd!).lastPathComponent : ""

            if let transcript = transcriptURL(for: id) {
                let text = tailText(of: transcript) ?? ""
                title = lastJSONValue("aiTitle", in: text) ?? title
                if project.isEmpty, let recorded = lastJSONValue("cwd", in: text) {
                    project = URL(fileURLWithPath: recorded).lastPathComponent
                }
            }

            sessions.append(SessionInfo(
                id: id,
                title: title,
                project: project.isEmpty ? "session" : project,
                modified: heartbeat))
        }

        pruneOrphanedRecords(keeping: Set(sessions.map { $0.id }))
        return sessions.sorted { $0.modified > $1.modified }
    }

    // live/ prunes itself by heartbeat above, but the records keyed to a session
    // are only deleted by SessionEnd, which a session killed outright never
    // sends. A record with no live entry and no write in the stale window
    // belongs to a session that is long gone.
    //
    // Only the machine-recorded directories are swept. The per-session sound,
    // volume and speak markers are choices the user made, and a session id that
    // comes back deserves to find them still there.
    func pruneOrphanedRecords(keeping ids: Set<String>) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-liveStaleWindow)

        for directory in [ttyDir, terminalsDir] {
            guard let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }

            for file in files where !ids.contains(file.lastPathComponent) {
                // The age check is what makes this safe against a session still
                // starting up, whose live entry may not be written yet.
                guard let modified = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified < cutoff else { continue }
                try? fm.removeItem(at: file)
            }
        }
    }

    // Sessions that predate the hooks being registered have no registry entry
    // until they next respond, so fall back to transcript times rather than
    // showing an empty menu.
    func recentSessions() -> [SessionInfo] {
        let live = liveSessions()
        if !live.isEmpty { return Array(live.prefix(sessionLimit)) }
        return transcriptSessions()
    }

    func transcriptSessions() -> [SessionInfo] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: transcriptsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }

        let cutoff = Date().addingTimeInterval(-sessionWindow)
        var candidates: [(url: URL, modified: Date)] = []

        for directory in projectDirs {
            let files = (try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let modified = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate,
                      modified > cutoff else { continue }
                candidates.append((file, modified))
            }
        }

        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(sessionLimit)
            .map { candidate in
                let text = tailText(of: candidate.url) ?? ""
                let id = candidate.url.deletingPathExtension().lastPathComponent
                let title = lastJSONValue("aiTitle", in: text) ?? "Untitled session"
                let cwd = lastJSONValue("cwd", in: text)
                let project = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? candidate.url.deletingLastPathComponent().lastPathComponent
                return SessionInfo(id: id, title: title, project: project, modified: candidate.modified)
            }
    }

    func startedLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    func relativeAge(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }

    // A session counts as still waiting only if nothing has touched it since it
    // finished. The transcript moves while Claude works, so it is the honest
    // activity signal; the heartbeat alone would nag during a long turn.
    func lastActivity(of session: SessionInfo) -> Date {
        var latest = session.modified
        if let transcript = transcriptURL(for: session.id),
           let modified = try? transcript.resourceValues(
               forKeys: [.contentModificationDateKey]).contentModificationDate,
           modified > latest {
            latest = modified
        }
        return latest
    }
}
