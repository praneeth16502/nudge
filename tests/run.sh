#!/usr/bin/env bash
# Test suite for scripts/nudge.sh.
#
# Every external command nudge calls (osascript, afplay, lsappinfo, notify-send,
# xdotool, mpv, powershell.exe, uname …) is replaced by a stub that logs its
# arguments, so tests run on any OS, make no noise, and can assert exactly what
# would have happened. The hook runs under `env -i` with a minimal PATH, so the
# user's own environment can't leak in.
#
# Usage:  tests/run.sh               (uses `bash`)
#         BASH_BIN=/bin/bash tests/run.sh
# Needs:  jq (to build test JSON).
#
# shellcheck disable=SC2086,SC2016,SC2046
# SC2086: $MAC/$LIN/$WIN hold one VAR=value each and are split on purpose.
# SC2016: check strings are single-quoted so `eval` expands them later.
# SC2046: $(seq …) is split on purpose.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/nudge.sh"
BASH_BIN="${BASH_BIN:-$(command -v bash)}"
REAL_UNAME="$(command -v uname)"
command -v jq >/dev/null 2>&1 || { echo "tests need jq"; exit 2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/nudge-test.XXXXXX")"
cleanup() { case "$TMP" in */nudge-test.*) rm -rf "$TMP" ;; esac; }
trap cleanup EXIT
LOG="$TMP/calls.log"
H="$TMP/home"; mkdir -p "$H/.claude"

pass=0; fail=0; failed_names=""

# ---- stubs ----------------------------------------------------------------------
mkstub() { # dir name [body]
  mkdir -p "$1"
  {
    echo '#!/bin/sh'
    echo '[ -n "$NUDGE_TEST_SLOW" ] && sleep 5'
    [ -n "${3:-}" ] && echo "$3"
    # Build the whole line first, then append it in one write (stubs run concurrently).
    echo 'line="$(basename "$0")"; for a in "$@"; do line="$line [$a]"; done'
    echo 'printf "%s\n" "$line" >> "$NUDGE_TEST_LOG"'
  } > "$1/$2"
  chmod +x "$1/$2"
}
S="$TMP/stubs"
for c in osascript afplay notify-send; do mkstub "$S/core" "$c"; done
cat > "$S/core/lsappinfo" <<'EOF'
#!/bin/sh
case "$1" in
  front) echo "ASN:0x0-0x1:" ;;
  info)  [ -n "$FAKE_FRONT" ] || exit 1
         printf '"App" ASN:0x0-0x1: (in front)\n    bundleID="%s"\n' "$FAKE_FRONT" ;;
esac
EOF
cat > "$S/core/uname" <<EOF
#!/bin/sh
if [ -n "\$FAKE_UNAME" ]; then echo "\$FAKE_UNAME"; else exec "$REAL_UNAME" "\$@"; fi
EOF
mkdir -p "$S/x"
cat > "$S/x/xdotool" <<'EOF'
#!/bin/sh
[ -n "$FAKE_XPID" ] && echo "$FAKE_XPID" || exit 1
EOF
chmod +x "$S/core/lsappinfo" "$S/core/uname" "$S/x/xdotool"
mkstub "$S/mpv" mpv; mkstub "$S/ffplay" ffplay; mkstub "$S/paplay" paplay
mkstub "$S/pwsh" powershell.exe
# Warm up: macOS scans brand-new executables on first launch, which can be slow.
for f in "$S"/*/*; do NUDGE_TEST_LOG=/dev/null "$f" front >/dev/null 2>&1; done

# ---- minimal PATH with only the tools nudge is allowed to rely on ---------------
T="$TMP/tools"; mkdir -p "$T/base" "$T/jq" "$T/py" "$T/timeout"
for t in sh cat sed tr basename dirname date find awk grep head sleep; do
  p="$(command -v "$t")" && ln -s "$p" "$T/base/$t"
done
ln -s "$BASH_BIN" "$T/base/bash"
ln -s "$(command -v jq)" "$T/jq/jq"
command -v python3 >/dev/null 2>&1 && ln -s "$(command -v python3)" "$T/py/python3"
command -v timeout >/dev/null 2>&1 && ln -s "$(command -v timeout)" "$T/timeout/timeout"
DEFAULT_PATH="$S/core:$T/base:$T/jq"
TPATH="$DEFAULT_PATH"

# ---- fixtures ---------------------------------------------------------------------
M="$TMP/media"; mkdir -p "$M/folder with space" "$M/empty" "$H/Music"
printf 'x' > "$M/my song.mp3"
printf 'x' > "$M/folder with space/a.mp3"
printf 'x' > "$M/folder with space/b.m4a"
printf 'x' > "$M/folder with space/readme.txt"
printf 'x' > "$H/Music/tilde.m4a"

# ---- helpers ----------------------------------------------------------------------
json() { # json EVENT [MESSAGE] [CWD]
  jq -cn --arg e "$1" --arg m "${2-}" --arg c "${3-/work/proj}" \
    '{hook_event_name:$e, session_id:"t", cwd:$c} + (if $m=="" then {} else {message:$m} end)'
}
reset_state() { rm -f "$H/.claude/.nudge.last" "$H/.claude/nudge.off"; }
hook() { # hook JSON [VAR=val ...]   (appends to $LOG; call reset_log first)
  local j="$1"; shift
  printf '%s' "$j" | env -i HOME="$H" PATH="$TPATH" NUDGE_TEST_LOG="$LOG" "$@" \
    "$BASH_BIN" "$SCRIPT" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  sleep 0.2   # let detached stubs write their log lines
}
run() { : > "$LOG"; reset_state; hook "$@"; }

ok()      { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()     { fail=$((fail+1)); failed_names="$failed_names
  - $1"; printf '  FAIL  %s\n' "$1"; [ -s "$LOG" ] && sed 's/^/          log: /' "$LOG"; [ -s "$TMP/err" ] && sed 's/^/          err: /' "$TMP/err"; }
check()   { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
has()     { # detached stubs may land a moment late: retry for up to ~2s
  local i=0; while [ $i -lt 10 ]; do grep -qF -- "$1" "$LOG" && return 0; sleep 0.2; i=$((i+1)); done; return 1; }
hasnt()   { ! grep -qF -- "$1" "$LOG"; }
silent()  { [ ! -s "$LOG" ]; }
clean()   { [ "$RC" = 0 ] && [ ! -s "$TMP/err" ] && [ ! -s "$TMP/out" ]; }
count()   { grep -c -- "^$1" "$LOG"; }
section() { printf '\n%s\n' "$1"; }

echo "nudge tests  (bash: $("$BASH_BIN" -c 'echo $BASH_VERSION'))"

# =================================================================================
section "macOS: focus check"
MAC="FAKE_UNAME=Darwin"
SND="NUDGE_SOUND=$M/my song.mp3"

run "$(json Stop)" $MAC FAKE_FRONT=com.anthropic.claudefordesktop
check "silent when Claude desktop is in front" silent
check "  ...and exits 0 with no output" clean
run "$(json Stop)" $MAC FAKE_FRONT=com.apple.Terminal
check "silent when Terminal is in front" silent
run "$(json Stop)" $MAC FAKE_FRONT=com.microsoft.VSCode
check "silent when VS Code is in front" silent
run "$(json Stop)" $MAC FAKE_FRONT=com.apple.Safari "$SND"
check "notifies when another app is in front" has "osascript"
check "  ...plays the sound" has "afplay"
check "  ...exits 0 with no output" clean
run "$(json Stop)" $MAC FAKE_FRONT=com.apple.Terminal2
check "quiet list matches whole IDs, not prefixes" has "osascript"
run "$(json Stop)" $MAC FAKE_FRONT=
check "notifies when the front app can't be read" has "osascript"
run "$(json Stop)" $MAC FAKE_FRONT=com.apple.Safari "NUDGE_QUIET_APPS=foo, com.apple.Safari"
check "NUDGE_QUIET_APPS adds apps (spaces ignored)" silent
run "$(json Stop)" $MAC FAKE_FRONT=com.anthropic.claudefordesktop NUDGE_FORCE=1
check "NUDGE_FORCE=1 skips the focus check" has "osascript"

section "macOS: message content"
run "$(json Stop "" "/Users/me/my project")" $MAC FAKE_FRONT=x
check "Stop: project name in title" has "[Claude Code · my project]"
check "Stop: 'Finished' body" has "[Finished. Waiting for your next message.]"
run "$(json Notification "Claude needs your permission to use Bash")" $MAC FAKE_FRONT=x
check "Notification: message becomes the body" has "[Claude needs your permission to use Bash]"
run "$(json Notification "" )" $MAC FAKE_FRONT=x
check "Notification without message: fallback body" has "[Needs your input]"
run "$(json SubagentStop)" $MAC FAKE_FRONT=x
check "unknown event: generic body" has "[Waiting for you]"
run "$(json Stop "" "")" $MAC FAKE_FRONT=x
check "no cwd: plain title" has "[Claude Code] [Finished"
EVIL='$(touch '"$TMP"'/pwned) `touch '"$TMP"'/pwned2` "quoted" it'"'"'s \ back'
run "$(json Notification "$EVIL")" $MAC FAKE_FRONT=x
check "shell metacharacters are not executed" test ! -e "$TMP/pwned" -a ! -e "$TMP/pwned2"
check "  ...and reach the notification verbatim" has "[$EVIL]"
check "  ...passed as argv, never spliced into AppleScript" has "[on run argv]"
run "$(json Notification "日本語 ✅ émoji 🚀")" $MAC FAKE_FRONT=x
check "unicode / emoji message" has "[日本語 ✅ émoji 🚀]"
run "$(json Notification "line one
line two")" $MAC FAKE_FRONT=x
check "multi-line message: exits 0, still notifies" has "osascript"
LONG="$(printf 'x%.0s' $(seq 1 5000))"
run "$(json Notification "$LONG")" $MAC FAKE_FRONT=x
check "5000-char message: exits 0, still notifies" has "osascript"

section "macOS: sound"
if [ -f /System/Library/Sounds/Glass.aiff ]; then
  run "$(json Stop)" $MAC FAKE_FRONT=x
  check "default sound is Glass, 8s cap, full volume" has "afplay [-t] [8] [-v] [1.00] [/System/Library/Sounds/Glass.aiff]"
fi
run "$(json Stop)" $MAC FAKE_FRONT=x "$SND"
check "custom file with spaces in path" has "[$M/my song.mp3]"
run "$(json Stop)" $MAC FAKE_FRONT=x "$SND" NUDGE_SOUND_SECONDS=3 NUDGE_VOLUME=50
check "NUDGE_SOUND_SECONDS / NUDGE_VOLUME" has "afplay [-t] [3] [-v] [0.50]"
run "$(json Stop)" $MAC FAKE_FRONT=x "$SND" NUDGE_SOUND_SECONDS=abc NUDGE_VOLUME=500
check "bad seconds/volume fall back to 8 / 100" has "afplay [-t] [8] [-v] [1.00]"
check "  ...without shell errors" clean
run "$(json Stop)" $MAC FAKE_FRONT=x NUDGE_SOUND=none
check "NUDGE_SOUND=none: no sound" hasnt "afplay"
check "  ...but still notifies" has "osascript"
run "$(json Stop)" $MAC FAKE_FRONT=x "NUDGE_SOUND=$M/missing.mp3"
check "missing sound file: notifies, doesn't try the bad path" eval 'has osascript && hasnt missing.mp3'
if [ -f /System/Library/Sounds/Glass.aiff ]; then
  check "  ...falls back to the default sound" has "[/System/Library/Sounds/Glass.aiff]"
fi
run "$(json Stop)" $MAC FAKE_FRONT=x "NUDGE_SOUND=~/Music/tilde.m4a"
check "~ in path expands to HOME" has "[$H/Music/tilde.m4a]"
run "$(json Stop)" $MAC FAKE_FRONT=x "NUDGE_SOUND=$M/empty"
check "empty folder: notifies, doesn't try the folder" eval 'has osascript && hasnt "$M/empty"'
: > "$LOG"; reset_state
for i in $(seq 1 30); do hook "$(json Stop)" $MAC FAKE_FRONT=x "NUDGE_SOUND=$M/folder with space" NUDGE_DEBOUNCE=0; done
check "folder: only audio files are picked" hasnt "readme.txt"
check "folder: picks vary between runs" eval 'has "/a.mp3]" && has "/b.m4a]"'

section "debounce, pause, NUDGE_ON_STOP"
: > "$LOG"; reset_state
hook "$(json Stop)" $MAC FAKE_FRONT=x NUDGE_SOUND=none
hook "$(json Notification hi)" $MAC FAKE_FRONT=x NUDGE_SOUND=none
check "second nudge within 10s is suppressed" test "$(count osascript)" = 1
: > "$LOG"; reset_state
hook "$(json Stop)" $MAC FAKE_FRONT=x NUDGE_SOUND=none NUDGE_DEBOUNCE=0
hook "$(json Stop)" $MAC FAKE_FRONT=x NUDGE_SOUND=none NUDGE_DEBOUNCE=0
check "NUDGE_DEBOUNCE=0 disables debounce" test "$(count osascript)" = 2
: > "$LOG"; reset_state; echo garbage > "$H/.claude/.nudge.last"
hook "$(json Stop)" $MAC FAKE_FRONT=x NUDGE_SOUND=none NUDGE_DEBOUNCE=abc
check "corrupt stamp + bad NUDGE_DEBOUNCE: still works, no errors" eval 'has osascript && clean'
run "$(json Stop)" $MAC FAKE_FRONT=x; touch "$H/.claude/nudge.off"; : > "$LOG"; rm -f "$H/.claude/.nudge.last"
hook "$(json Stop)" $MAC FAKE_FRONT=x
check "~/.claude/nudge.off pauses everything" silent
rm -f "$H/.claude/nudge.off"
run "$(json Stop)" $MAC FAKE_FRONT=x NUDGE_ON_STOP=0
check "NUDGE_ON_STOP=0: no nudge on Stop" silent
run "$(json Notification "perm")" $MAC FAKE_FRONT=x NUDGE_ON_STOP=0
check "NUDGE_ON_STOP=0: still nudges on Notification" has "osascript"

section "robustness"
for input in "" "not json" "{" "[]" '{"hook_event_name":42}'; do
  run "$input" $MAC FAKE_FRONT=x NUDGE_SOUND=none
  check "bad input '${input:-<empty>}': exit 0, no output" clean
done
: > "$LOG"; reset_state; chmod 500 "$H/.claude"
hook "$(json Stop)" $MAC FAKE_FRONT=x NUDGE_SOUND=none
check "read-only ~/.claude: still notifies, no errors" eval 'has osascript && clean'
chmod 700 "$H/.claude"
mv "$H/.claude" "$H/.claude-away"
run "$(json Stop)" $MAC FAKE_FRONT=x NUDGE_SOUND=none
check "no ~/.claude at all: still notifies, no errors" eval 'has osascript && clean'
mv "$H/.claude-away" "$H/.claude"
run "$(json Stop)" FAKE_UNAME=SunOS
check "unsupported OS: silent, exit 0" eval 'silent && clean'
: > "$LOG"; reset_state
start=$SECONDS
hook "$(json Stop)" $MAC FAKE_FRONT=x "$SND" NUDGE_TEST_SLOW=1
elapsed=$((SECONDS - start))
check "hook returns at once even if sound/notifier hang (took ${elapsed}s)" test "$elapsed" -le 2

section "JSON parsing fallbacks"
TPATH="$S/core:$T/base:$T/py"
if [ -e "$T/py/python3" ]; then
  run "$(json Notification 'Allow "x" to run' "/a/py proj")" $MAC FAKE_FRONT=x
  check "no jq → python3 parses quotes correctly" eval 'has "[Allow \"x\" to run]" && has "[Claude Code · py proj]"'
fi
TPATH="$S/core:$T/base"
run "$(json Notification 'Plain message' /a/sedproj)" $MAC FAKE_FRONT=x
check "no jq, no python3 → sed parses simple values" eval 'has "[Plain message]" && has "[Claude Code · sedproj]"'
TPATH="$DEFAULT_PATH"

section "Linux"
LIN="FAKE_UNAME=Linux"
run "$(json Notification "perm" /x/lproj)" $LIN
check "notify-send gets app name, title, body" has "notify-send [-a] [Claude Code] [-i] [dialog-information] [--] [Claude Code · lproj] [perm]"
run "$(json Notification "-u critical")" $LIN
check "body starting with '-' isn't read as an option" has "[--] [Claude Code · proj] [-u critical]"
TPATH="$S/mpv:$S/ffplay:$S/paplay:$DEFAULT_PATH"
run "$(json Stop)" $LIN "$SND" NUDGE_SOUND_SECONDS=4 NUDGE_VOLUME=70
check "mpv preferred, with length + volume" has "mpv [--no-video] [--really-quiet] [--length=4] [--volume=70] [$M/my song.mp3]"
TPATH="$S/ffplay:$S/paplay:$DEFAULT_PATH"
run "$(json Stop)" $LIN "$SND"
check "ffplay when no mpv" has "ffplay [-nodisp] [-autoexit] [-loglevel] [quiet] [-t] [8] [-volume] [100]"
TPATH="$S/paplay:$DEFAULT_PATH"
run "$(json Stop)" $LIN "$SND"
check "paplay fallback" has "paplay [$M/my song.mp3]"
TPATH="$DEFAULT_PATH"
run "$(json Stop)" $LIN "$SND"
check "no player installed: still notifies" eval 'has notify-send && clean'
run "$(json Stop)" $LIN NUDGE_SOUND=none
check "no xdotool (Wayland): always notifies" has "notify-send"
if [ -r /proc/self/comm ]; then
  TPATH="$S/x:$DEFAULT_PATH"
  sleep 30 & SLEEPPID=$!
  run "$(json Stop)" $LIN NUDGE_SOUND=none FAKE_XPID=$SLEEPPID NUDGE_QUIET_APPS=sleep
  check "X11: focused process in quiet list → silent" silent
  run "$(json Stop)" $LIN NUDGE_SOUND=none FAKE_XPID=$SLEEPPID
  check "X11: focused process not in list → notifies" has "notify-send"
  kill $SLEEPPID 2>/dev/null; wait $SLEEPPID 2>/dev/null
  TPATH="$DEFAULT_PATH"
fi

section "Windows (Git Bash) hand-off"
WIN="FAKE_UNAME=MINGW64_NT-10.0-22631"
TPATH="$S/pwsh:$DEFAULT_PATH"
run "$(json Notification "perm" /c/proj)" $WIN
check "calls PowerShell with nudge-windows.ps1" has "powershell.exe [-NoProfile] [-NonInteractive] [-ExecutionPolicy] [Bypass] [-File] [$ROOT/scripts/nudge-windows.ps1]"
check "  ...passes title/body/seconds/volume" has "[-Title] [Claude Code · proj] [-Body] [perm] [-Seconds] [8] [-Volume] [100]"
check "  ...omits -Sound when unset (PS 5.1 drops empty args)" hasnt "[-Sound]"
run "$(json Stop)" $WIN NUDGE_SOUND=none
check "  ...passes -Sound none" has "[-Sound] [none]"
run "$(json Stop)" $WIN "$SND"
check "  ...passes custom sound path" has "[-Sound] [$M/my song.mp3]"
TPATH="$DEFAULT_PATH"
run "$(json Stop)" $WIN
check "no PowerShell found: silent, exit 0" eval 'silent && clean'

section "plugin wiring"
for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  check "$f is valid JSON" jq -e . "$ROOT/$f" >/dev/null
done
check "plugin name matches marketplace entry" test \
  "$(jq -r .name "$ROOT/.claude-plugin/plugin.json")" = "$(jq -r '.plugins[0].name' "$ROOT/.claude-plugin/marketplace.json")"
check "version is semver" eval "jq -r .version '$ROOT/.claude-plugin/plugin.json' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\$'"
check "hooks cover Notification and Stop" test "$(jq -r '.hooks | keys | sort | join(",")' "$ROOT/hooks/hooks.json")" = "Notification,Stop"
# Run the exact hook command from hooks.json, with the plugin installed under a path with spaces.
P="$TMP/plugin cache/nudge 0.1"; mkdir -p "$P"; cp -R "$ROOT/scripts" "$P/"
while IFS= read -r cmd; do
  : > "$LOG"; reset_state
  printf '%s' "$(json Stop)" | env -i HOME="$H" PATH="$DEFAULT_PATH" NUDGE_TEST_LOG="$LOG" \
    CLAUDE_PLUGIN_ROOT="$P" FAKE_UNAME=Darwin FAKE_FRONT=x NUDGE_SOUND=none \
    "$BASH_BIN" -c "$cmd" >"$TMP/out" 2>"$TMP/err"; RC=$?; sleep 0.2
  check "hooks.json command runs from a path with spaces" eval 'has osascript && clean'
done < <(jq -r '.hooks[][].hooks[].command' "$ROOT/hooks/hooks.json" | sort -u)

# =================================================================================
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ] || { printf 'Failed:%s\n' "$failed_names"; exit 1; }
