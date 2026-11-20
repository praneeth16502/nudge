# nudge

A Claude Code plugin that tells you when Claude is waiting for you.

When Claude Code stops for a permission prompt, asks a question, or finishes a turn, nudge plays a sound and shows a desktop notification. It only does this when you're in another app. If Claude, your terminal, or your editor is already in front, it stays quiet.

It's made for Claude Code in a **terminal** or **editor** (Terminal, iTerm2, Ghostty, VS Code, Cursor, …), which have no notifications like this of their own. Works on macOS, Linux, and Windows. Nothing else to install.

> nudge is a community plugin. It is not made by or affiliated with Anthropic.

## Using the Claude desktop app?

The Claude desktop app already sends its own notifications. They show Claude's icon, and clicking one opens that session. So nudge **stays silent inside the desktop app** by default, which avoids double notifications. To get banners from the app, check its notification settings, and allow Claude in System Settings → Notifications. Setting the alert style to Persistent keeps banners on screen until you dismiss them.

To have nudge play in the desktop app anyway, for example to use your own music, set `NUDGE_IN_DESKTOP_APP` to `1`.

## What you see

The headline is always **Claude is waiting for you**. The line under it names the project and says what Claude needs:

| When | Notification text |
|---|---|
| Claude finished its turn | my-app: Finished its turn |
| Permission prompt | my-app: Claude needs your permission to use Bash |
| Idle, waiting for input | my-app: Claude is waiting for your input |

The text after the project name comes from Claude Code. You can change the headline with `NUDGE_TITLE`.

## Clicking the notification (macOS)

A plugin is a script, not an app, so macOS can't show its notifications as coming from Claude. nudge has two ways to post them:

- **Default:** a built-in macOS notification. macOS treats it as coming from Script Editor, so clicking it opens Script Editor.
- **With [terminal-notifier](https://github.com/julienXX/terminal-notifier) installed:** clicking it brings back the app Claude is running in (Terminal, iTerm2, VS Code, …). nudge finds it on your `PATH` or in Homebrew's folders and uses it automatically. A new nudge replaces the previous banner instead of stacking up.

```bash
brew install terminal-notifier
```

terminal-notifier is optional. Everything else works the same without it. A click brings the app forward, but it can't pick a specific tab or session.

## Install

In Claude Code:

```
/plugin marketplace add praneeth16502/nudge
/plugin install nudge@nudge
```

Or from a terminal:

```bash
claude plugin marketplace add praneeth16502/nudge
claude plugin install nudge@nudge
```

Start a new Claude Code session afterwards so the hooks load.

## Try it

Ask Claude to do something that needs your permission, then switch to your browser. You should hear a sound and see a notification.

To fire one by hand, even while your terminal is in front:

```bash
echo '{"hook_event_name":"Stop","cwd":"/tmp/demo"}' | NUDGE_FORCE=1 bash ~/.claude/plugins/cache/nudge/nudge/*/scripts/nudge.sh
```

## Settings

Set these in the `env` block of `~/.claude/settings.json`:

```json
{
  "env": {
    "NUDGE_SOUND": "/System/Library/Sounds/Hero.aiff",
    "NUDGE_DEBOUNCE": "20",
    "NUDGE_ON_STOP": "0",
    "NUDGE_QUIET_APPS": "com.apple.Safari"
  }
}
```

| Variable | Default | What it does |
|---|---|---|
| `NUDGE_SOUND` | Glass (macOS), `complete.oga` (Linux), Reminder (Windows) | A sound or music file, a folder of them (random track each time), or `none` for a silent notification |
| `NUDGE_SOUND_SECONDS` | `8` | Stop playback after this many seconds, so a full song doesn't play |
| `NUDGE_VOLUME` | `100` | Volume from 0 to 100 |
| `NUDGE_DEBOUNCE` | `10` | Minimum seconds between nudges |
| `NUDGE_ON_STOP` | `1` | `0` = only nudge for prompts and questions, not finished turns |
| `NUDGE_QUIET_APPS` | (none) | Extra apps that count as "looking at Claude", comma-separated |
| `NUDGE_TITLE` | `Claude is waiting for you` | Notification headline |
| `NUDGE_ACTIVATE` | the app Claude runs in | macOS + terminal-notifier: bundle ID of the app a click brings forward |
| `NUDGE_NOTIFIER` | (auto) | macOS: `osascript` = never use terminal-notifier |
| `NUDGE_IN_DESKTOP_APP` | `0` | `1` = also nudge inside the Claude desktop app, which has its own notifications |
| `NUDGE_FORCE` | (unset) | `1` = skip the focused-app check (testing) |

On macOS, sounds live in `/System/Library/Sounds/` (Glass, Ping, Hero, Submarine, Funk, …).

### Use your own music

Point `NUDGE_SOUND` at any audio file you own (mp3, m4a, wav, aiff, …), or at a folder of them to hear a random one each time. `~` works in the path.

```json
{
  "env": {
    "NUDGE_SOUND": "~/Music/nudge",
    "NUDGE_SOUND_SECONDS": "6",
    "NUDGE_VOLUME": "60"
  }
}
```

- The file has to be a plain audio file on disk. Songs downloaded from Apple Music or Spotify are copy-protected and won't play.
- Pick a short clip, or keep `NUDGE_SOUND_SECONDS` low. The sound keeps playing after you switch back to Claude.
- **Linux:** mp3 and m4a need `mpv` or `ffplay`. Without them, only wav and ogg files play.
- **Windows:** playback uses Windows Media Foundation, which handles mp3, m4a, wav and wma.

**App names for `NUDGE_QUIET_APPS`:**
- macOS: the bundle ID. Find it with `osascript -e 'id of app "Safari"'`.
- Linux: the process name, as in `/proc/<pid>/comm`.
- Windows: the process name without `.exe`.

**Pause nudges:** `touch ~/.claude/nudge.off`. Resume with `rm ~/.claude/nudge.off`.

**Uninstall:** `/plugin uninstall nudge@nudge`.

## Quiet by default in

Claude desktop app, Terminal, iTerm2, Ghostty, Warp, kitty, Alacritty, WezTerm, VS Code, Cursor, Windsurf, Zed, JetBrains IDEs, Windows Terminal, PowerShell, and common Linux terminals.

## Platform notes

**macOS.**
- The focused app is read with `lsappinfo`, which needs no Automation permission.
- The first notification may ask you to allow notifications for Script Editor, or for terminal-notifier if it's installed. If notifications never show up, turn that app on in System Settings → Notifications.

**Linux.**
- Notifications use `notify-send` (libnotify). Sound uses `mpv` or `ffplay` when installed, otherwise `paplay`, `pw-play`, or `aplay`.
- The focus check needs `xdotool` on X11. Wayland doesn't let apps see the focused window, so there nudge always notifies.

**Windows.**
- Needs Git Bash, which Claude Code on Windows already uses for hooks.
- Notifications are Windows toasts sent through Windows PowerShell. With PowerShell 7 only, nudge falls back to a tray balloon.

## How it works

The plugin adds two [hooks](https://docs.claude.com/en/docs/claude-code/hooks):
- `Notification` fires for permission prompts and when Claude is idle waiting for input.
- `Stop` fires when Claude finishes a turn.

Both run `scripts/nudge.sh`. The script reads the event JSON, checks which app is in front, applies the debounce, then starts the sound and notification in the background. It always exits 0 within a fraction of a second, so it never slows down or breaks Claude Code.

## Development

```bash
bash tests/run.sh                    # full suite (needs jq), any OS
BASH_BIN=/bin/bash bash tests/run.sh # macOS system bash 3.2, which hooks use
```

The suite swaps every external command (`osascript`, `afplay`, `notify-send`, `powershell.exe`, …) for a stub that logs its arguments. That means it runs silently on any OS and checks exactly what would be called. CI runs it on macOS and Linux, runs `tests/windows.ps1` on real Windows, and runs shellcheck and `claude plugin validate`.

## License

MIT
