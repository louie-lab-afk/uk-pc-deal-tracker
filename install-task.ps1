[CmdletBinding()]
param(
    [int]$IntervalMinutes = 5,
    [string]$TaskName = "UK-PC-Deal-Tracker"
)

$ErrorActionPreference = "Stop"

if ($IntervalMinutes -lt 1 -or $IntervalMinutes -gt 1440) {
    throw "IntervalMinutes must be between 1 and 1440."
}

$vbsPath = Join-Path $PSScriptRoot "run-hidden.vbs"
if (-not (Test-Path $vbsPath)) {
    throw "Launcher not found at $vbsPath"
}

$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$vbsPath`""

# Repeat indefinitely every N minutes starting 1 minute from now, plus trigger at logon
$repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 3650)

$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 4)

$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger @($repeatTrigger, $logonTrigger) `
    -Settings $settings `
    -Principal $principal `
    -Description "Checks UK RSS deal feeds (HotUKDeals & CamelCamelCamel UK) for NVMe SSD, GPU, CPU, DDR5 RAM, and Motherboard 30-day lows and misprices." `
    -Force | Out-Null

Write-Host "Scheduled task '$TaskName' installed successfully!" -ForegroundColor Green
Write-Host "  Schedule : Every $IntervalMinutes minutes (silent background run, even when Antigravity is closed)"
Write-Host "  Script   : $(Join-Path $PSScriptRoot 'check-deals.ps1')"
Write-Host "  Logs     : $(Join-Path $PSScriptRoot 'data\tracker.log')"
Write-Host ""
Write-Host "Tip: Run '.\check-deals.ps1 -TestAlert' to verify your Discord / ntfy.sh alerts." -ForegroundColor Cyan
