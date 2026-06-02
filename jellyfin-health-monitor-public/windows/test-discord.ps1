param(
    [string]$ConfigPath = ".\config.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resolvedConfig = if ([System.IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath } else { Join-Path $PSScriptRoot $ConfigPath }
$config = Get-Content -LiteralPath $resolvedConfig -Raw | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($config.DiscordWebhookUrl)) {
    throw "DiscordWebhookUrl is blank in $resolvedConfig"
}

$payload = @{ content = "Jellyfin Health Monitor Discord test succeeded." } | ConvertTo-Json -Compress
Invoke-RestMethod -Method Post -Uri $config.DiscordWebhookUrl -ContentType "application/json" -Body $payload | Out-Null
Write-Host "Sent Discord test alert."
