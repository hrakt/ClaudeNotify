# ClaudeNotify

A macOS menu bar app that tells you when Claude Code wants you, without being annoying about it.

Claude Code can run a hook when a turn ends. Point it at this app and you get a sound and a clickable banner naming the session that finished, so you can start something long and go do something else.

## What it does

**Tells your sessions apart.** Each project can get its own tone, so you know which one finished before you look. Clicking the banner opens the terminal tab it came from, including the exact tab in Orca.

**Knows when to shut up.** It goes quiet while your microphone is live, so a chime never lands in the middle of a call. When the call ends you get one banner saying what finished while you were away, with a button to overrule it if the detection was wrong.

**Stays out of the way of your music.** Rather than a ding loud enough to beat whatever you are playing, it dips the other audio for a second and chimes at a normal volume.

**Sounds different when it is stuck.** A turn that finished and a turn waiting on your permission are not the same thing, so they do not sound the same or say the same words.

Everything is off a right click away: 101 sounds already on your Mac, per session volume, reminders for a session you walked away from, and a spoken project name if a tone is not enough.

## Install

```bash
git clone git@github.com:hrakt/ClaudeNotify.git
cd ClaudeNotify
./build.sh
open ClaudeNotify.app
```

Launching it writes `~/.claude/claudenotify/notify.sh`. Point your hooks at that script once in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop":         [{ "hooks": [{ "type": "command", "command": "~/.claude/claudenotify/notify.sh" }] }],
    "Notification": [{ "hooks": [{ "type": "command", "command": "~/.claude/claudenotify/notify.sh" }] }],
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "~/.claude/claudenotify/notify.sh" }] }],
    "SessionEnd":   [{ "hooks": [{ "type": "command", "command": "~/.claude/claudenotify/notify.sh" }] }]
  }
}
```

`Stop` is the one that makes noise. `Notification` fires when Claude is blocked on you. The other two are silent and only keep the session list honest. You edit this file once. Every later change ships by the app rewriting its own script.

## Using it

Click the bell to mute, click again to unmute. Right click for sounds, sessions, volume, reminders and settings.

## Requirements

macOS 13 or later, plus the Xcode command line tools to build it. No dependencies, no frameworks, about 3,400 lines of Swift.

## Why it is built this way

The app owns a shell script and rewrites it on launch, so new behaviour never means editing your Claude Code config again. State is plain files in `~/.claude/claudenotify/`, which is what lets the hook and the app agree without talking to each other.

Meetings are detected from CoreAudio rather than by integrating with Zoom, Slack and Meet separately. Ducking uses the same call Siri uses to lower your music. Neither needs a permission prompt.

[DESIGN.md](DESIGN.md) has the reasoning behind each piece, including the things that were tried first and did not work.
