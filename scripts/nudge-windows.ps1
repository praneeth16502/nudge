# nudge (Windows): focus check + debounce + toast. Called by nudge.sh.
# Settings come from the same NUDGE_* environment variables as nudge.sh.
param([string]$Title = "Claude Code", [string]$Body = "Waiting for you",
      [string]$Sound = "", [int]$Seconds = 8, [int]$Volume = 100)
$ErrorActionPreference = "SilentlyContinue"

# ---- already looking at Claude? -> stay quiet --------------------------------
$quiet = @("claude", "WindowsTerminal", "powershell", "pwsh", "cmd", "Code", "Code - Insiders",
           "Cursor", "Windsurf", "wezterm-gui", "alacritty", "mintty", "Zed", "idea64", "pycharm64")
if ($env:NUDGE_QUIET_APPS) { $quiet += $env:NUDGE_QUIET_APPS.Split(",") | ForEach-Object { $_.Trim() } }

if (-not $env:NUDGE_FORCE) {
  Add-Type -Namespace Nudge -Name Win -MemberDefinition @"
[DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
"@
  $procId = 0
  [void][Nudge.Win]::GetWindowThreadProcessId([Nudge.Win]::GetForegroundWindow(), [ref]$procId)
  $front = (Get-Process -Id $procId).ProcessName
  if ($front -and ($quiet -contains $front)) { exit 0 }
}

# ---- debounce -------------------------------------------------------------------
$stateDir = Join-Path $env:USERPROFILE ".claude"
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir | Out-Null }
$stamp = Join-Path $stateDir ".nudge.last"
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
[long]$last = 0
if (Test-Path -LiteralPath $stamp) { [void][long]::TryParse((Get-Content -LiteralPath $stamp -Raw).Trim(), [ref]$last) }
[int]$debounce = 10
if ($env:NUDGE_DEBOUNCE) { [void][int]::TryParse($env:NUDGE_DEBOUNCE, [ref]$debounce) }
if (($now - $last) -lt $debounce) { exit 0 }
Set-Content -LiteralPath $stamp -Value $now

# ---- toast (Windows PowerShell 5.1 has the WinRT types) -------------------------
$custom = $Sound -and ($Sound -ne "none") -and (Test-Path -LiteralPath $Sound -PathType Leaf)
# Custom file or "none" -> silent toast (we play the file ourselves below).
$silent = if ($custom -or $Sound -eq "none") { '<audio silent="true"/>' } else { '<audio src="ms-winsoundevent:Notification.Reminder"/>' }
$t = [System.Security.SecurityElement]::Escape($Title)
$b = [System.Security.SecurityElement]::Escape($Body)
try {
  [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
  [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
  $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
  $xml.LoadXml("<toast><visual><binding template=`"ToastGeneric`"><text>$t</text><text>$b</text></binding></visual>$silent</toast>")
  $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
  [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
    [Windows.UI.Notifications.ToastNotification]::new($xml))
} catch {
  # Fallback: tray balloon (works on PowerShell 7 too).
  Add-Type -AssemblyName System.Windows.Forms
  $n = New-Object System.Windows.Forms.NotifyIcon
  $n.Icon = [System.Drawing.SystemIcons]::Information
  $n.Visible = $true
  $n.ShowBalloonTip(5000, $Title, $Body, "Info")
  if (-not $custom -and $Sound -ne "none") { [System.Media.SystemSounds]::Asterisk.Play() }
  if (-not $custom) { Start-Sleep -Seconds 6 }
}

# ---- custom sound / music (mp3, m4a, wav, wma…) via Windows Media Foundation --------
if ($custom) {
  Add-Type -AssemblyName PresentationCore
  $p = New-Object System.Windows.Media.MediaPlayer
  $p.Volume = [Math]::Max(0, [Math]::Min(100, $Volume)) / 100
  $p.Open([Uri]((Resolve-Path -LiteralPath $Sound).Path))
  $p.Play()
  Start-Sleep -Seconds ([Math]::Max(1, $Seconds))
  $p.Stop(); $p.Close()
}
if ($n) { $n.Dispose() }
exit 0
