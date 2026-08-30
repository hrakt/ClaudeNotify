import Cocoa

// A count of sessions that have finished and not been picked up again.
//
// This app's answer to being too noisy has always been to shape the noise, and
// the answer to that has been the mute flag, which has been on for days at a
// time. A muted app tells you nothing at all. This is the part that still works
// when the sound is off: a number in the menu bar saying how many are sitting
// there waiting on you, glanceable without opening anything.
extension AppDelegate {
    // Written when a turn finishes, cleared when you come back to it. The file's
    // timestamp is the whole mechanism: a session stops waiting the moment its
    // transcript moves on, which is exactly what happens when you reply.
    func markWaiting(_ sessionID: String) {
        try? FileManager.default.createDirectory(at: waitingDir, withIntermediateDirectories: true)
        let marker = waitingDir.appendingPathComponent(sessionID)
        try? Data().write(to: marker)
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: marker.path)
    }

    func clearWaiting(_ sessionID: String) {
        try? FileManager.default.removeItem(at: waitingDir.appendingPathComponent(sessionID))
    }

    // Sweeps as it counts. A session whose transcript has moved on since the
    // marker was written has been answered, whether that happened through this
    // app or by the obvious route of typing into the terminal.
    func waitingSessions() -> [String] {
        let fm = FileManager.default
        guard let markers = try? fm.contentsOfDirectory(
            at: waitingDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }

        var waiting: [String] = []
        for marker in markers {
            let sessionID = marker.lastPathComponent
            guard let markedAt = try? marker.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }

            // Nothing is owed forever. A session left alone for longer than the
            // registry keeps it is not waiting, it is abandoned.
            guard Date().timeIntervalSince(markedAt) < liveStaleWindow else {
                try? fm.removeItem(at: marker)
                continue
            }

            if let transcript = transcriptURL(for: sessionID),
               let touched = try? transcript.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate,
               touched > markedAt.addingTimeInterval(transcriptAnswerGrace) {
                try? fm.removeItem(at: marker)
                continue
            }
            waiting.append(sessionID)
        }
        return waiting
    }
}
