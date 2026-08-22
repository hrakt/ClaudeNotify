#!/bin/bash
# Behaviour tests for the generated hook. Everything here runs against a sandbox
# HOME with afplay, say and osascript replaced by stubs that record their
# arguments, so the suite is silent and can assert on exactly what would have
# been heard.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SB="$(mktemp -d)"
HOOK="$SB/notify.sh"
TOKEN="CLAUDENOTIFY-TEST-APP-RUNNING"
SID="11111111-2222-3333-4444-555555555555"
pass=0; fail=0; current=""

cleanup() { app_down; rm -rf "$SB"; }
trap cleanup EXIT

# The pgrep pattern is rewritten to a token this suite can start and stop at
# will. A unit test pins the real pattern, so this rewrite cannot hide a broken
# one; it only makes both branches reachable while the real app is running.
"$ROOT/build/tests" --emit-hook "$HOOK" || { echo "could not emit hook"; exit 1; }
sed -i '' "s|ClaudeNotify.app/Contents/MacOS/ClaudeNotify|$TOKEN|" "$HOOK"

mkdir -p "$SB/bin"
for cmd in afplay say osascript; do
    cat > "$SB/bin/$cmd" <<STUB
#!/bin/bash
printf '%s %s\n' "$cmd" "\$*" >> "$SB/calls.log"
STUB
    chmod +x "$SB/bin/$cmd"
done
mkdir -p "$SB/fakeapp"
# exec -a keeps the token in argv so pgrep still matches, while replacing the
# wrapper shell so killing the pid actually kills the sleep. Plain exec loses the
# token; a plain background call leaves an orphan holding the output pipe.
printf '#!/bin/bash\nexec -a "%s" sleep 600\n' "$TOKEN" > "$SB/fakeapp/$TOKEN"
chmod +x "$SB/fakeapp/$TOKEN"

# exec'd and detached: a wrapper shell would survive the kill as an orphaned
# sleep still holding the output pipe, which hangs whatever is running the suite.
app_up() { "$SB/fakeapp/$TOKEN" >/dev/null 2>&1 & APPPID=$!; sleep 0.4; }
app_down() {
    if [ -n "${APPPID:-}" ]; then
        kill "$APPPID" 2>/dev/null
        wait "$APPPID" 2>/dev/null   # reaped quietly, or the shell announces it
    fi
    APPPID=""; sleep 0.3
}

reset() {
    rm -rf "$SB/.claude"
    mkdir -p "$SB/.claude/claudenotify"/{live,ttys,terminals,pending,pending-meta,sessions,session-volumes,project-sounds,deferred,icons}
    : > "$SB/calls.log"
}

hook() {
    local event="$1" cwd="${2:-/Users/me/cam-fe}" session="${3:-$SID}"
    local payload
    if [ "$session" = "NONE" ]; then
        payload="{\"hook_event_name\":\"$event\",\"cwd\":\"$cwd\"}"
    else
        payload="{\"session_id\":\"$session\",\"hook_event_name\":\"$event\",\"cwd\":\"$cwd\"}"
    fi
    printf '%s' "$payload" | env HOME="$SB" PATH="$SB/bin:$PATH" TERM_PROGRAM=ghostty bash "$HOOK"
}

it() { current="$1"; }
ok() { pass=$((pass+1)); }
no() { fail=$((fail+1)); echo "    ✗ $current: $1"; }

played()      { grep -q "^afplay" "$SB/calls.log" && ok || no "expected a sound"; }
silent()      { grep -q "^afplay" "$SB/calls.log" && no "expected silence, got $(grep '^afplay' "$SB/calls.log" | head -1)" || ok; }
played_tone() { grep -q "^afplay.*$1" "$SB/calls.log" && ok || no "expected tone $1, got $(grep '^afplay' "$SB/calls.log" | sed 's|.*/||' | head -1)"; }
spoke()       { grep -q "^say.*$1" "$SB/calls.log" && ok || no "expected to say '$1', got '$(grep '^say' "$SB/calls.log" | head -1)'"; }
mute_speech() { grep -q "^say" "$SB/calls.log" && no "expected no speech" || ok; }
bannered()    { grep -q "^osascript" "$SB/calls.log" && ok || no "expected the fallback banner"; }
no_banner()   { grep -q "^osascript" "$SB/calls.log" && no "expected no fallback banner" || ok; }
has()         { [ -e "$SB/.claude/claudenotify/$1" ] && ok || no "expected $1 to exist"; }
hasnt()       { [ -e "$SB/.claude/claudenotify/$1" ] && no "expected $1 to be absent" || ok; }
meta_says()   { grep -q "$1" "$SB/.claude/claudenotify/pending-meta/$SID" 2>/dev/null && ok || no "expected meta to say $1"; }

echo "  hooks: running"

# --- the app is not running: the hook is on its own ---------------------------
app_down
it "plain finish, no app";        reset; hook Stop; played; bannered; hasnt "pending/$SID"
it "muted";                       reset; touch "$SB/.claude/notifications-muted"; hook Stop; silent; no_banner
it "timed mute, still running";   reset; echo $(( $(date +%s) + 300 )) > "$SB/.claude/claudenotify/muted-until"; hook Stop; silent
it "timed mute, expired";         reset; echo $(( $(date +%s) - 10 )) > "$SB/.claude/claudenotify/muted-until"; hook Stop; played; hasnt "muted-until"
it "session start is silent";     reset; hook SessionStart; silent; has "live/$SID"; has "terminals/$SID"
it "session end cleans up";       reset; hook SessionStart; hook SessionEnd; hasnt "live/$SID"; hasnt "terminals/$SID"
it "no session id still dings";   reset; hook Stop /Users/me/cam-fe NONE; played
it "malformed session id dings";  reset; hook Stop /Users/me/cam-fe "not!valid"; played
it "blocked on you sounds different"; reset; hook Notification; played_tone Submarine
it "a stale meeting flag is ignored"; reset; touch "$SB/.claude/claudenotify/in-meeting"; hook Stop; played; bannered
it "a stale focus flag is ignored";   reset; touch "$SB/.claude/claudenotify/in-focus"; hook Stop; played

# --- the app is running: it takes over the ding -------------------------------
app_up
it "ducking hands the ding over";  reset; hook Stop; silent; has "pending/$SID"; meta_says owed
it "ducking off, the hook plays";  reset; echo 0 > "$SB/.claude/claudenotify/duck-audio"; hook Stop; played; has "pending/$SID"
it "in a meeting: held, no ding";  reset; touch "$SB/.claude/claudenotify/in-meeting"; hook Stop; silent; has "pending/$SID"
it "in a meeting: nothing owed";   reset; touch "$SB/.claude/claudenotify/in-meeting"; hook Stop; \
    { grep -q owed "$SB/.claude/claudenotify/pending-meta/$SID" && no "nothing should be owed in a meeting" || ok; }
it "under a focus: no ding";       reset; touch "$SB/.claude/claudenotify/in-focus"; hook Stop; silent; has "pending/$SID"
it "meta records the event";       reset; hook Notification; meta_says Notification
it "handoff survives blocked notifications"; reset; touch "$SB/.claude/claudenotify/notifications-blocked"; hook Stop; has "pending/$SID"; no_banner

# --- sound selection ---------------------------------------------------------
app_down
it "session sound wins";  reset; echo /System/Library/Sounds/Hero.aiff > "$SB/.claude/claudenotify/sessions/$SID"; hook Stop; played_tone Hero
it "session sound beats the attention tone"; reset; echo /System/Library/Sounds/Hero.aiff > "$SB/.claude/claudenotify/sessions/$SID"; hook Notification; played_tone Hero
it "project tone when enabled"; reset; echo 1 > "$SB/.claude/claudenotify/project-sounds-on"; \
    echo /System/Library/Sounds/Tink.aiff > "$SB/.claude/claudenotify/project-sounds/cam-fe"; hook Stop; played_tone Tink
it "project tone ignored when off"; reset; \
    echo /System/Library/Sounds/Tink.aiff > "$SB/.claude/claudenotify/project-sounds/cam-fe"; hook Stop; \
    { grep -q "Tink" "$SB/calls.log" && no "project tone used while disabled" || ok; }
it "attention tone beats the project tone"; reset; echo 1 > "$SB/.claude/claudenotify/project-sounds-on"; \
    echo /System/Library/Sounds/Tink.aiff > "$SB/.claude/claudenotify/project-sounds/cam-fe"; hook Notification; played_tone Submarine

# --- the spoken project ------------------------------------------------------
it "silent unless asked";         reset; hook Stop; mute_speech
it "says the project";            reset; echo 1 > "$SB/.claude/claudenotify/speak-project"; hook Stop; spoke "cam fe"
it "says nothing empty";          reset; echo 1 > "$SB/.claude/claudenotify/speak-project"; hook Stop; \
    { grep -qE "^say -r 220 *$" "$SB/calls.log" && no "spoke an empty string" || ok; }
it "muted beats speaking";        reset; echo 1 > "$SB/.claude/claudenotify/speak-project"; \
    touch "$SB/.claude/notifications-muted"; hook Stop; mute_speech

echo "  hooks: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
