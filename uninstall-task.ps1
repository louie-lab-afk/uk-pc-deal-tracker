[CmdletBinding()]
param(
    [string]$TaskName = "UK-PC-Deal-Tracker"
)

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Scheduled task '$TaskName' removed." -ForegroundColor Green
} else {
    Write-Host "Scheduled task '$TaskName' was not found." -ForegroundColor Yellow
}
