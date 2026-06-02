param(
    [string]$TaskName = "Jellyfin Health Monitor",
    [string]$ScriptPath = ".\monitor.ps1",
    [string]$ConfigPath = ".\config.json",
    [int]$IntervalMinutes = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resolvedScript = if ([System.IO.Path]::IsPathRooted($ScriptPath)) { $ScriptPath } else { Join-Path $PSScriptRoot $ScriptPath }
$resolvedConfig = if ([System.IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath } else { Join-Path $PSScriptRoot $ConfigPath }

if (-not (Test-Path -LiteralPath $resolvedScript)) {
    throw "Monitor script not found: $resolvedScript"
}

if (-not (Test-Path -LiteralPath $resolvedConfig)) {
    throw "Config not found: $resolvedConfig. Copy config.example.json to config.json first."
}

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$resolvedScript`" -ConfigPath `"$resolvedConfig`""

$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
    -RepetitionDuration (New-TimeSpan -Days 365)

$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "Installed scheduled task '$TaskName' to run every $IntervalMinutes minutes."
