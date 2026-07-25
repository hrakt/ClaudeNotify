# ClaudeNotify

A tiny macOS menu-bar app that toggles whether [Claude Code](https://claude.com/claude-code) plays its completion sound.

Claude Code can run a **Stop hook** that pings you when a turn finishes. That's great, until you're heads-down and every response dings. ClaudeNotify puts a bell in the menu bar so you can mute or unmute that ping with one click, no config editing.

## How it works

The app doesn't hook notifications directly. Toggling it just creates or removes a flag file:

```
~/.claude/notifications-muted
```

Your Claude Code Stop hook checks that flag and skips the sound when it exists:

```bash
test -f ~/.claude/notifications-muted || afplay /System/Library/Sounds/Glass.aiff
```

So: **menu-bar toggle → flag file → hook reads the flag → sound plays or not.** The bell icon reflects state (`bell.fill` when on, `bell.slash.fill` when muted).

## Build

```bash
./build.sh            # compiles main.swift → ClaudeNotify.app
open ClaudeNotify.app # runs it (menu-bar only, no Dock icon)
```

Requires the Swift toolchain (Xcode command line tools) and macOS 13+.

## Hook setup

Add a Stop hook to `~/.claude/settings.json` that respects the flag:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "test -f ~/.claude/notifications-muted || afplay /System/Library/Sounds/Glass.aiff"
          }
        ]
      }
    ]
  }
}
```

## Stack

Swift + Cocoa (`NSStatusItem`), ~75 lines, no dependencies.
