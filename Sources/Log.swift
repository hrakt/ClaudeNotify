import Foundation

// NSLog from this app does not reach the unified log at all: `log show` with any
// predicate returns nothing, so every "it says why in the log" this app promised
// has been saying it into a void. Diagnostics go to a file instead, which is
// consistent with how the rest of its state is kept and, more to the point, can
// actually be read.
let logURL = supportDir.appendingPathComponent("log.txt")
private let logLimit = 64 * 1024

func note(_ message: String) {
    NSLog("ClaudeNotify: \(message)")

    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm:ss"
    let line = "\(formatter.string(from: Date()))  \(message)\n"

    let fm = FileManager.default
    try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true)

    guard let handle = try? FileHandle(forWritingTo: logURL) else {
        try? line.data(using: .utf8)?.write(to: logURL)
        return
    }
    defer { try? handle.close() }

    // Trimmed by halving rather than rotated. A second file to manage would be
    // more machinery than a debug log is worth.
    if (try? handle.seekToEnd()) ?? 0 > UInt64(logLimit),
       let existing = try? String(contentsOf: logURL, encoding: .utf8) {
        let kept = existing.suffix(logLimit / 2)
        try? (kept + line).write(to: logURL, atomically: true, encoding: .utf8)
        return
    }
    try? handle.seekToEnd()
    if let data = line.data(using: .utf8) { handle.write(data) }
}
