import Cocoa
import Foundation
import ServiceManagement

// Two jobs. Given --emit-hook it writes the generated shell script somewhere the
// shell tests can run it, so those test the real thing rather than a copy that
// has drifted. Otherwise it runs the unit tests.
//
// Only pure functions are exercised here. Anything that reads or writes would
// touch the real ~/.claude, and a test suite that can damage the thing it is
// testing is worse than no test suite.

var failures: [String] = []
var checks = 0

func check(_ label: String, _ actual: String, _ expected: String) {
    checks += 1
    if actual != expected {
        failures.append("\(label)\n      got: \(actual)\n      want: \(expected)")
    }
}

func check(_ label: String, _ condition: Bool) {
    checks += 1
    if !condition { failures.append(label) }
}

// The script is the most failure-prone thing in the project and the least
// visible: it is a string literal, so nothing lints it. These assertions pin
// the specific mistakes that have already been made once.
func testScriptInvariants() {
    let s = scriptBody

    check("hook: pgrep pattern matches the real bundle path",
          s.contains("pgrep -f \"ClaudeNotify.app/Contents/MacOS/ClaudeNotify\""))

    // A leading dash in tr's first argument is read as an option, so this
    // silently spoke empty strings.
    check("hook: tr separators do not start with a dash", s.contains("tr '_-'"))
    check("hook: tr separators are not the broken order", !s.contains("tr '-_'"))

    // Standing aside without a session id meant neither side played anything.
    check("hook: standing aside requires a session id",
          s.contains("if [ -n \"$APP_RUNNING\" ] && [ -n \"$SESSION_ID\" ]; then"))

    // Every reason to stay silent has to gate the ding, not just the first one.
    check("hook: the ding is gated on meeting, focus and ducking",
          s.contains("if [ -z \"$QUIET\" ] && [ -z \"$FOCUS\" ] && [ -z \"$DUCK\" ]; then"))

    // Honouring a leftover flag with no app behind it silenced the hook
    // completely and permanently.
    check("hook: the meeting flag is only honoured while the app runs",
          s.contains("if [ -n \"$APP_RUNNING\" ] && [ -f \"$HOME/.claude/claudenotify/in-meeting\" ]"))
    check("hook: the focus flag is only honoured while the app runs",
          s.contains("if [ -n \"$APP_RUNNING\" ] && [ -f \"$HOME/.claude/claudenotify/in-focus\" ]"))

    check("hook: mute exits before anything can make noise",
          s.range(of: "notifications-muted")!.lowerBound < s.range(of: "afplay")!.lowerBound)

    check("hook: default tone agrees with the app's",
          s.contains(defaultSound.lastPathComponent))
    check("hook: attention tone agrees with the app's",
          s.contains(defaultAttentionSound.lastPathComponent))
}

func testSpokenProject() {
    let app = AppDelegate()
    check("spoken: cam-fe",        app.spokenProject("cam-fe"), "Cam F E")
    check("spoken: cam-api",       app.spokenProject("cam-api"), "Cam A P I")
    check("spoken: cm-intranet",   app.spokenProject("cm-intranet"), "C M intranet")
    check("spoken: ClaudeNotify",  app.spokenProject("ClaudeNotify"), "Claude Notify")
    check("spoken: wisplet",       app.spokenProject("wisplet"), "Wisplet")
    check("spoken: three letter words stay words",
          app.spokenProject("cam"), "Cam")
    check("spoken: never empty for a plain name", !app.spokenProject("cam-fe").isEmpty)
}

func testPrettyName() {
    let app = AppDelegate()
    check("pretty: strips the tone suffix",
          app.prettyName("Droplet-EncoreInfinitum"), "Droplet")
    check("pretty: splits camel case", app.prettyName("DeskView"), "Desk View")
    check("pretty: underscores become spaces", app.prettyName("voice_memo"), "Voice memo")
}

func testOrcaHandle() {
    let app = AppDelegate()
    check("handle: accepts a real one",
          app.isValidOrcaHandle("term_dfac8f1e-8154-4029-8b90-7a0e46b24caa"))
    check("handle: rejects a missing prefix", !app.isValidOrcaHandle("dfac8f1e"))
    check("handle: rejects shell metacharacters",
          !app.isValidOrcaHandle("term_a;rm -rf /"))
    check("handle: rejects something absurdly long",
          !app.isValidOrcaHandle("term_" + String(repeating: "a", count: 200)))
}

func testJSONReading() {
    let app = AppDelegate()
    let text = #"{"cwd":"/one"} {"cwd":"/two"}"#
    check("json: takes the last value", app.lastJSONValue("cwd", in: text) ?? "", "/two")
    check("json: absent key is nil", app.lastJSONValue("nope", in: text) == nil)
    check("json: empty value is nil", app.lastJSONValue("k", in: #"{"k":""}"#) == nil)
}

// Tones are assigned by hashing the project name so a project keeps its sound
// across restarts. Handing them out in arrival order was the first attempt and
// depended on which project happened to start first.
func testProjectToneAssignment() {
    let app = AppDelegate()
    check("tones: hashing is stable across calls",
          app.stableHash("cam-fe") == app.stableHash("cam-fe"))
    check("tones: different names differ",
          app.stableHash("cam-fe") != app.stableHash("cam-api"))
    check("tones: rotation has no duplicates",
          Set(projectSoundRotation.map { $0.path }).count == projectSoundRotation.count)
    check("tones: rotation leads with the default",
          projectSoundRotation.first?.lastPathComponent == defaultSound.lastPathComponent)
    check("tones: every tone in the rotation exists on disk",
          projectSoundRotation.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
}

// The login item itself cannot be tested here: registering touches the real
// system. What can be pinned is that its preference lives with the others and
// that every status the app might report has wording, since an unhandled case
// would show the user an empty checkbox label.
func testLoginItemPreference() {
    check("login: preference sits under the support directory",
          openAtLoginURL.deletingLastPathComponent().path == supportDir.path)
    check("login: preference is named for what it does",
          openAtLoginURL.lastPathComponent, "open-at-login")

    let app = AppDelegate()
    let described = [SMAppService.Status.enabled, .requiresApproval, .notRegistered, .notFound]
        .map { app.describe($0) }
    check("login: every status has wording", described.allSatisfy { !$0.isEmpty })
    check("login: statuses read differently", Set(described).count == described.count)
}

func testWaitingPaths() {
    check("waiting: markers sit under the support directory",
          waitingDir.deletingLastPathComponent().path == supportDir.path)
    check("waiting: a reply is not mistaken for the turn that ended",
          transcriptAnswerGrace > 0 && transcriptAnswerGrace < 10)
    // Cleared by SessionEnd, so the hook has to know where they live.
    check("hook: session end clears the waiting mark",
          scriptBody.contains("claudenotify/waiting/$SESSION_ID"))
}

// Dismissal is only reported for categories that asked to be told, and one card
// per session only happens if the identifier is reused. Both are easy to undo by
// accident, and neither fails loudly.
func testNotificationPlumbing() {
    check("banners: session category exists to hear about dismissals",
          !sessionCategoryID.isEmpty)
    check("banners: the go-to action is distinct from the dismiss ones",
          Set([goToSessionActionID, stayQuietActionID, meetingOverrideActionID]).count == 3)
    check("banners: the categories are all distinct",
          Set([sessionCategoryID, meetingCategoryID, meetingEndedCategoryID]).count == 3)
}

// The project has to come out of the label when the transcript has not named
// the session yet, or it appears in both the title and the line beneath it.
func testLabelSplitting() {
    let app = AppDelegate()
    check("label: strips a hook style project prefix",
          app.stripProject("cam-fe: SMART-6479 deployment"), "SMART-6479 deployment")
    check("label: strips the app style separator",
          app.stripProject("cam-fe · SMART-6479 deployment"), "SMART-6479 deployment")
    check("label: leaves a bare title alone",
          app.stripProject("SMART-6479 deployment"), "SMART-6479 deployment")
    check("label: keeps colons inside the title",
          app.stripProject("cam-fe: fix: the parser"), "fix: the parser")
}

// The whole point of composing the menu bar icon by hand: every state has to
// come out the same size, or the item resizes and shoves every icon to its left
// along with it.
func testMenuBarWidthIsConstant() {
    let app = AppDelegate()
    let states: [(String, Int)] = [
        ("bell.fill", 0), ("bell.slash.fill", 0), ("bell.badge.slash.fill", 0),
        ("bell.fill", 1), ("bell.fill", 9), ("bell.fill", 42),
    ]
    let sizes = Set(states.map { app.menuBarImage(symbol: $0.0, count: $0.1).size.width })
    check("menu bar: one width for every state", sizes.count == 1)
    check("menu bar: that width is the declared one",
          sizes.first == menuBarItemWidth)
    check("menu bar: an unknown symbol still yields the same size",
          app.menuBarImage(symbol: "not.a.symbol", count: 0).size.width == menuBarItemWidth)
    check("menu bar: drawn as a template so it tints itself",
          app.menuBarImage(symbol: "bell.fill", count: 0).isTemplate)
}

func testIconSet() {
    check("icons: every kind has a distinct name",
          Set(NotificationIcon.all.map { $0.name }).count == NotificationIcon.all.count)
    check("icons: every kind names a real SF Symbol",
          NotificationIcon.all.allSatisfy {
              NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil
          })
}

// MARK: - entry

// Renders the menu bar states so they can be looked at. Composed images are
// easy to get subtly wrong in ways no assertion catches: a clipped bell, a
// count sitting on top of it.
if let index = CommandLine.arguments.firstIndex(of: "--emit-menubar"),
   CommandLine.arguments.count > index + 1 {
    let app = AppDelegate()
    let states: [(String, Int)] = [
        ("bell.fill", 0), ("bell.slash.fill", 0), ("bell.badge.slash.fill", 0),
        ("bell.fill", 3), ("bell.slash.fill", 3), ("bell.fill", 12),
    ]
    let scale: CGFloat = 4, gap: CGFloat = 8
    let cell = menuBarItemWidth * scale
    let width = (cell + gap) * CGFloat(states.count) + gap
    let height = menuBarItemHeight * scale + gap * 2
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.93, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    for (i, state) in states.enumerated() {
        let image = app.menuBarImage(symbol: state.0, count: state.1)
        let box = NSRect(x: gap + (cell + gap) * CGFloat(i), y: gap,
                         width: cell, height: menuBarItemHeight * scale)
        // a template image draws black, which is what a light menu bar shows
        NSColor.white.setFill()
        box.fill()
        image.draw(in: box)
    }
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--emit-hook"),
   CommandLine.arguments.count > index + 1 {
    let target = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    try! scriptBody.write(to: target, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
    exit(0)
}

testScriptInvariants()
testSpokenProject()
testPrettyName()
testOrcaHandle()
testJSONReading()
testProjectToneAssignment()
testLoginItemPreference()
testWaitingPaths()
testNotificationPlumbing()
testLabelSplitting()
testMenuBarWidthIsConstant()
testIconSet()

if failures.isEmpty {
    print("  swift: \(checks) checks passed")
    exit(0)
}
print("  swift: \(failures.count) of \(checks) checks FAILED")
for f in failures { print("    ✗ \(f)") }
exit(1)
