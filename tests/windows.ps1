# Windows tests for scripts/nudge-windows.ps1 (run on a real Windows machine / CI runner).
$ErrorActionPreference = "Stop"
$root   = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root "scripts\nudge-windows.ps1"
$stamp  = Join-Path $env:USERPROFILE ".claude\.nudge.last"
$failed = 0
function Check($name, $cond) {
  if ($cond) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name"; $script:failed++ }
}
function Run([string[]]$extra) {
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script @extra
  return $LASTEXITCODE
}

Write-Host "nudge-windows.ps1 tests"

$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$errors)
Check "script parses without errors" ($errors.Count -eq 0)

Remove-Item -Force -ErrorAction SilentlyContinue $stamp
$env:NUDGE_FORCE = "1"; $env:NUDGE_DEBOUNCE = ""
$before = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$rc = Run @("-Title", "Claude Code - proj", "-Body", "Needs <your> input & ""quotes""", "-Sound", "none")
Check "exits 0 (XML special chars in body)" ($rc -eq 0)
Check "writes the debounce stamp" (Test-Path $stamp)
$first = [long](Get-Content $stamp -Raw).Trim()
Check "stamp is current unix time" ([Math]::Abs($first - $before) -le 15)

Start-Sleep -Seconds 1
$rc = Run @("-Title", "t", "-Body", "b", "-Sound", "none")
Check "second call within 10s exits 0" ($rc -eq 0)
Check "  ...and is debounced (stamp unchanged)" ([long](Get-Content $stamp -Raw).Trim() -eq $first)

$env:NUDGE_DEBOUNCE = "abc"
$rc = Run @("-Title", "t", "-Body", "b", "-Sound", "none")
Check "bad NUDGE_DEBOUNCE doesn't crash" ($rc -eq 0)

$env:NUDGE_DEBOUNCE = "0"
$wav = "$env:WINDIR\Media\chimes.wav"
$t0 = Get-Date
$rc = Run @("-Title", "t", "-Body", "custom sound", "-Sound", $wav, "-Seconds", "1", "-Volume", "10")
Check "custom sound file plays and exits 0" ($rc -eq 0)
Check "  ...stops after -Seconds (took $([int]((Get-Date) - $t0).TotalSeconds)s)" (((Get-Date) - $t0).TotalSeconds -lt 15)

$rc = Run @("-Title", "t", "-Body", "missing", "-Sound", "C:\nope\missing.mp3")
Check "missing sound file exits 0" ($rc -eq 0)

Remove-Item Env:NUDGE_FORCE
$rc = Run @("-Title", "t", "-Body", "focus check path")
Check "focus-check path exits 0" ($rc -eq 0)

Write-Host ""
if ($failed -gt 0) { Write-Host "$failed failed"; exit 1 } else { Write-Host "all passed"; exit 0 }
