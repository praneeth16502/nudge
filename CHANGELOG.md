# Changelog

## 0.2.1
- Stays silent inside the Claude desktop app by default, since the app sends its own notifications (as Claude, and a click opens the session). Set `NUDGE_IN_DESKTOP_APP=1` to nudge there anyway.

## 0.2.0
- Headline is now "Claude is waiting for you", with the project and what Claude needs underneath. Change it with `NUDGE_TITLE`.
- macOS: with `terminal-notifier` installed, clicking the notification brings back the app Claude runs in (`NUDGE_ACTIVATE` to choose another; `NUDGE_NOTIFIER=osascript` to opt out). New nudges replace the previous banner.

## 0.1.0
- First release: sound + notification on Notification and Stop hooks when another app is in front. macOS, Linux, Windows. Custom sound/music, debounce, pause file.
