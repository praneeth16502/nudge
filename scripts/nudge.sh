#!/usr/bin/env bash
# nudge — notify when Claude Code is waiting for you, unless you're already looking.
# Runs as a Claude Code hook on Notification + Stop. Reads hook JSON on stdin.
# Always exits 0 and returns fast: it never blocks or fails Claude Code.
#
# Settings (environment variables; set them in the "env" block of ~/.claude/settings.json):
#   NUDGE_SOUND        a sound or music file (mp3, m4a, wav, aiff…), a folder of them
#                      (a random one plays each time), or "none" for silent banners
#   NUDGE_SOUND_SECONDS  stop playback after this many seconds (default 8)
#   NUDGE_VOLUME       0-100 (default 100)
#   NUDGE_DEBOUNCE    seconds between nudges (default 10)
#   NUDGE_QUIET_APPS   extra comma-separated app IDs / process names that count as
#                      "looking at Claude" (macOS bundle ID, Linux process name,
#                      Windows process name)
#   NUDGE_ON_STOP      "0" = don't nudge when a turn finishes, only on prompts
#   NUDGE_TITLE        notification headline (default "Claude is waiting for you")
#   NUDGE_ACTIVATE     macOS: app (bundle ID) to bring forward when the banner is
#                      clicked; default = the app Claude Code is running in
#   NUDGE_NOTIFIER     macOS: "osascript" to never use terminal-notifier
#   NUDGE_IN_DESKTOP_APP "1" = also nudge in the Claude desktop app (off by default,
#                      since the app has its own notifications)
#   NUDGE_FORCE        "1" = ignore the focused-app check (for testing)
# Pause: touch ~/.claude/nudge.off      Resume: rm ~/.claude/nudge.off

input="$(cat 2>/dev/null)"   # always drain stdin first, even when paused

STATE_DIR="${HOME}/.claude"
[ -e "$STATE_DIR/nudge.off" ] && exit 0

# The Claude desktop app sends its own notifications (as Claude, and a click opens
# the session), so by default stay out of its way there to avoid doubles.
if [ "${NUDGE_IN_DESKTOP_APP:-0}" != 1 ]; then
  [ "${CLAUDE_CODE_ENTRYPOINT:-}" = claude-desktop ] && exit 0
  [ "${__CFBundleIdentifier:-}" = com.anthropic.claudefordesktop ] && exit 0
fi

# ---- parse hook JSON: jq, else python3, else a rough sed --------------------
json_get() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // empty' 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    printf '%s' "$input" | python3 -c 'import sys,json
try: v=json.load(sys.stdin).get(sys.argv[1]); print(v if isinstance(v,str) else "")
except Exception: pass' "$1" 2>/dev/null
  else
    # Good enough for simple values; stops at the first escaped quote.
    printf '%s' "$input" | tr -d '\n' \
      | sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p"
  fi
}
event="$(json_get hook_event_name)"
message="$(json_get message)"
cwd="$(json_get cwd)"

[ "$event" = "Stop" ] && [ "${NUDGE_ON_STOP:-1}" = "0" ] && exit 0

project="$(basename "${cwd:-}" 2>/dev/null)"
title="${NUDGE_TITLE:-Claude is waiting for you}"
case "$event" in
  Stop)         detail="Finished its turn" ;;
  Notification) detail="${message:-Needs your input}" ;;
  *)            detail="${message:-Needs your input}" ;;
esac
body="${project:+$project: }$detail"

# ---- platform -----------------------------------------------------------------
case "$(uname -s 2>/dev/null)" in
  Darwin) os=mac ;;
  Linux)  os=linux; grep -qi microsoft /proc/version 2>/dev/null && os=windows ;;
  MINGW*|MSYS*|CYGWIN*) os=windows ;;
  *) exit 0 ;;
esac

# ---- custom sound: expand ~, pick a random track if it's a folder -------------
sound="${NUDGE_SOUND:-}"
# Matching a literal ~ on purpose; it is expanded to $HOME right here.
# shellcheck disable=SC2088
case "$sound" in "~"|"~/"*) sound="$HOME${sound#\~}" ;; esac
if [ -n "$sound" ] && [ -d "$sound" ]; then
  sound="$(find "$sound" -maxdepth 1 -type f \( -iname '*.mp3' -o -iname '*.m4a' \
    -o -iname '*.wav' -o -iname '*.aif' -o -iname '*.aiff' -o -iname '*.aac' \
    -o -iname '*.ogg' -o -iname '*.oga' -o -iname '*.flac' -o -iname '*.caf' \) 2>/dev/null \
    | awk -v s="$$$(date +%s)" 'BEGIN{srand(s % 2147483647)} {a[NR]=$0} END{if (NR) print a[int(rand()*NR)+1]}')"
fi
# Missing file or empty folder -> default sound (a typo shouldn't silence you).
[ -n "$sound" ] && [ "$sound" != none ] && [ ! -f "$sound" ] && sound=""
secs="${NUDGE_SOUND_SECONDS:-8}"; case "$secs" in ''|*[!0-9]*) secs=8 ;; esac
vol="${NUDGE_VOLUME:-100}";       case "$vol"  in ''|*[!0-9]*) vol=100 ;; esac
[ "$vol" -gt 100 ] && vol=100

# Windows has its own script (focus check + toast + sound in one PowerShell call).
if [ "$os" = windows ]; then
  ps1="$(dirname "$0")/nudge-windows.ps1"
  winsound="$sound"
  if command -v cygpath >/dev/null 2>&1; then
    ps1="$(cygpath -w "$ps1")"; [ -f "$sound" ] && winsound="$(cygpath -w "$sound")"
  elif command -v wslpath >/dev/null 2>&1; then
    ps1="$(wslpath -w "$ps1")"; [ -f "$sound" ] && winsound="$(wslpath -w "$sound")"
  fi
  PSH="$(command -v powershell.exe || command -v pwsh.exe || command -v pwsh)"
  [ -z "$PSH" ] && exit 0
  # Debounce is handled in the .ps1 so state lives in one place on Windows.
  # Empty args can be dropped by PowerShell 5.1, so -Sound is only passed when set.
  set -- -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$ps1" \
    -Title "$title" -Body "$body" -Seconds "$secs" -Volume "$vol"
  [ -n "$winsound" ] && set -- "$@" -Sound "$winsound"
  ( "$PSH" "$@" >/dev/null 2>&1 & )
  exit 0
fi

# ---- "already looking at Claude?" -> stay quiet -------------------------------
DEFAULT_QUIET_MAC="com.anthropic.claudefordesktop,com.apple.Terminal,com.googlecode.iterm2,\
com.mitchellh.ghostty,com.microsoft.VSCode,com.microsoft.VSCodeInsiders,com.todesktop.230313mzl4w4u92,\
dev.warp.Warp-Stable,dev.zed.Zed,net.kovidgoyal.kitty,org.alacritty,com.github.wez.wezterm,\
com.jetbrains.intellij,com.jetbrains.pycharm,com.jetbrains.WebStorm,com.exafunction.windsurf"
DEFAULT_QUIET_LINUX="claude,gnome-terminal-server,konsole,kitty,alacritty,wezterm-gui,ghostty,\
foot,tilix,xterm,terminator,xfce4-terminal,code,code-insiders,cursor,zed,zeditor,windsurf"

front=""
if [ "$os" = mac ]; then
  quiet="$DEFAULT_QUIET_MAC"
  # lsappinfo needs no Automation permission (System Events would prompt and can hang).
  front="$(lsappinfo info -only bundleid "$(lsappinfo front 2>/dev/null)" 2>/dev/null \
    | sed -n 's/.*bundleID="\([^"]*\)".*/\1/p' | head -1)"
else
  quiet="$DEFAULT_QUIET_LINUX"
  # X11 only; on Wayland we can't see the focused window, so we always nudge.
  if command -v xdotool >/dev/null 2>&1; then
    pid="$(xdotool getactivewindow getwindowpid 2>/dev/null)"
    [ -n "$pid" ] && front="$(cat "/proc/$pid/comm" 2>/dev/null)"
  fi
fi
[ -n "${NUDGE_QUIET_APPS:-}" ] && quiet="$quiet,$NUDGE_QUIET_APPS"

if [ -z "${NUDGE_FORCE:-}" ] && [ -n "$front" ]; then
  case ",$(printf '%s' "$quiet" | tr -d ' ')," in
    *",$front,"*) exit 0 ;;
  esac
fi

# ---- debounce -----------------------------------------------------------------
stamp="$STATE_DIR/.nudge.last"
now="$(date +%s)"
last="$(cat "$stamp" 2>/dev/null || echo 0)"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
debounce="${NUDGE_DEBOUNCE:-10}"; case "$debounce" in ''|*[!0-9]*) debounce=10 ;; esac
[ $((now - last)) -lt "$debounce" ] && exit 0
{ echo "$now" > "$stamp"; } 2>/dev/null

# ---- sound + notification (detached, so the hook returns immediately) ---------
if [ "$os" = mac ]; then
  [ -z "$sound" ] && sound=/System/Library/Sounds/Glass.aiff
  if [ "$sound" != none ] && [ -f "$sound" ]; then
    v="$(awk -v v="$vol" 'BEGIN{printf "%.2f", v/100}')"
    ( afplay -t "$secs" -v "$v" "$sound" >/dev/null 2>&1 & )
  fi
  # terminal-notifier (optional, see its own install instructions) lets a click bring
  # Claude's app forward. Hooks may run with a short PATH, so also look in Homebrew dirs.
  tn=""
  if [ "${NUDGE_NOTIFIER:-}" != osascript ]; then
    tn="$(command -v terminal-notifier 2>/dev/null)"
    if [ -z "$tn" ]; then
      old_ifs="$IFS"; IFS=:
      for d in ${NUDGE_TN_SEARCH-/opt/homebrew/bin:/usr/local/bin}; do
        [ -n "$d" ] && [ -x "$d/terminal-notifier" ] && { tn="$d/terminal-notifier"; break; }
      done
      IFS="$old_ifs"
    fi
  fi
  if [ -n "$tn" ]; then
    # App to focus on click: explicit setting, else the app this hook was launched from.
    app="${NUDGE_ACTIVATE:-${__CFBundleIdentifier:-}}"
    if [ -z "$app" ]; then
      case "${TERM_PROGRAM:-}" in
        Apple_Terminal) app=com.apple.Terminal ;;
        iTerm.app)      app=com.googlecode.iterm2 ;;
        vscode)         app=com.microsoft.VSCode ;;
        ghostty)        app=com.mitchellh.ghostty ;;
        WezTerm)        app=com.github.wez.wezterm ;;
        WarpTerminal)   app=dev.warp.Warp-Stable ;;
      esac
    fi
    case "$app" in *[!A-Za-z0-9.-]*) app="" ;; esac   # bundle IDs only
    set -- -title "$title" -group nudge
    [ -n "$app" ] && set -- "$@" -activate "$app"
    # Body goes in on stdin, so text starting with "-" or "[" isn't read as an option.
    ( printf '%s' "$body" | "$tn" "$@" >/dev/null 2>&1 & )
  else
    # Text goes in as argv, so quotes in messages can't break the AppleScript.
    ( osascript -e 'on run argv' \
                -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
                -e 'end run' "$title" "$body" >/dev/null 2>&1 & )
  fi
else
  [ -z "$sound" ] && sound=/usr/share/sounds/freedesktop/stereo/complete.oga
  if [ "$sound" != none ] && [ -f "$sound" ]; then
    # mpv / ffplay handle mp3, m4a etc.; paplay / pw-play / aplay are wav/ogg-only fallbacks.
    if command -v mpv >/dev/null 2>&1; then
      ( mpv --no-video --really-quiet --length="$secs" --volume="$vol" "$sound" >/dev/null 2>&1 & )
    elif command -v ffplay >/dev/null 2>&1; then
      ( ffplay -nodisp -autoexit -loglevel quiet -t "$secs" -volume "$vol" "$sound" >/dev/null 2>&1 & )
    else
      # Cap length with `timeout` when it exists.
      set --; command -v timeout >/dev/null 2>&1 && set -- timeout "$secs"
      if command -v paplay >/dev/null 2>&1; then ( "$@" paplay "$sound" >/dev/null 2>&1 & )
      elif command -v pw-play >/dev/null 2>&1; then ( "$@" pw-play "$sound" >/dev/null 2>&1 & )
      elif command -v aplay >/dev/null 2>&1; then ( "$@" aplay -q "$sound" >/dev/null 2>&1 & )
      fi
    fi
  fi
  command -v notify-send >/dev/null 2>&1 && \
    ( notify-send -a "Claude Code" -i dialog-information -- "$title" "$body" >/dev/null 2>&1 & )
fi

exit 0
