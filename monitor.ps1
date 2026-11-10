param(
    [string]$ConfigPath = ".\config.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-LocalPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    return Join-Path -Path $PSScriptRoot -ChildPath $Path
}

function Read-JsonFile {
    param([string]$Path, [object]$Default)
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    $raw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
    return $raw | ConvertFrom-Json
}

function Save-JsonFile {
    param([string]$Path, [object]$Value)
    $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Convert-ToHashtable {
    param([object]$Value)
    if ($Value -is [hashtable]) { return $Value }
    $result = @{}
    if ($null -ne $Value) {
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = $property.Value
        }
    }
    return $result
}

function Get-OptionalProperty {
    param([object]$Object, [string]$Name, [object]$Default = $null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
        return $Object.PSObject.Properties[$Name].Value
    }
    return $Default
}

function Get-StateValue {
    param([hashtable]$State, [string]$Key, [object]$Default)
    if ($State.ContainsKey($Key)) { return $State[$Key] }
    return $Default
}

function Set-StateValue {
    param([hashtable]$State, [string]$Key, [object]$Value)
    $State[$Key] = $Value
}

function Send-ProblemAlert {
    param(
        [string]$Key, [string]$Title, [string]$Detail,
        [int]$Color = 15158332, [switch]$Ping
    )

    if (Get-StateValue -State $state -Key $Key -Default $false) { return }
    Write-Host "$Title - $Detail"
    if ([string]::IsNullOrWhiteSpace($config.DiscordWebhookUrl)) { return }

    $payload = @{
        allowed_mentions = @{ parse = @() }
        embeds = @(@{
            title = $Title
            description = $Detail
            color = $Color
            fields = @(@{ name = "Monitor host"; value = $env:COMPUTERNAME; inline = $true })
            footer = @{ text = "Jellyfin Health Monitor" }
            timestamp = [datetime]::UtcNow.ToString("o")
        })
    }
    $userId = Get-OptionalProperty -Object $config -Name "DiscordUserId" -Default ""
    if ($Ping -and $userId -match '^[0-9]{17,20}$') {
        $payload.content = "<@$userId>"
        $payload.allowed_mentions.users = @([string]$userId)
    }
    try {
        Invoke-RestMethod -Method Post -Uri $config.DiscordWebhookUrl -ContentType "application/json" `
            -Body ($payload | ConvertTo-Json -Depth 8 -Compress) -TimeoutSec 15 | Out-Null
        Set-StateValue -State $state -Key $Key -Value $true
    }
    catch {
        Write-Warning "Discord could not deliver the alert. The next run will retry if the problem persists."
    }
}

function Invoke-HealthRequest {
    param([string]$Uri, [string]$ApiKey = "")
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $headers["X-Emby-Token"] = $ApiKey
        $headers["X-Api-Key"] = $ApiKey
    }
    Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -TimeoutSec 15
}

function Get-JellyfinProcessSample {
    param([string[]]$ProcessNames)
    $processes = foreach ($name in $ProcessNames) { Get-Process -Name $name -ErrorAction SilentlyContinue }
    $processes = @($processes | Sort-Object Id -Unique)
    if ($processes.Count -eq 0) { return $null }
    $cpuBefore = ($processes | Measure-Object -Property CPU -Sum).Sum
    Start-Sleep -Seconds 1
    $after = @(foreach ($process in $processes) { Get-Process -Id $process.Id -ErrorAction SilentlyContinue })
    if ($after.Count -eq 0) { return $null }
    $cpuAfter = ($after | Measure-Object -Property CPU -Sum).Sum
    $cpuPercent = (($cpuAfter - $cpuBefore) / [Environment]::ProcessorCount) * 100
    $memoryBytes = ($after | Measure-Object -Property WorkingSet64 -Sum).Sum
    return [pscustomobject]@{
        CpuPercent = [math]::Max(0, $cpuPercent)
        MemoryBytes = [int64]$memoryBytes
        ProcessCount = $after.Count
    }
}

function Restart-Jellyfin {
    param([object]$Config)
    $serviceName = Get-OptionalProperty -Object $Config.Jellyfin -Name "ServiceName" -Default ""
    if (-not [string]::IsNullOrWhiteSpace($serviceName)) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            Restart-Service -Name $serviceName -Force -ErrorAction Stop
            return "Restarted Jellyfin service '$serviceName'."
        }
    }
    $exe = Get-OptionalProperty -Object $Config.Jellyfin -Name "ExecutablePath" -Default ""
    if (-not [string]::IsNullOrWhiteSpace($exe) -and (Test-Path -LiteralPath $exe)) {
        foreach ($name in $Config.Jellyfin.ProcessNames) {
            Stop-Process -Name $name -Force -ErrorAction SilentlyContinue
        }
        Start-Process -FilePath $exe -WindowStyle Hidden
        return "Started Jellyfin from executable path."
    }
    throw "No Jellyfin service or executable path was available for restart."
}

function Restart-WindowsServiceIfPresent {
    param([string]$ServiceName)
    if ([string]::IsNullOrWhiteSpace($ServiceName)) { throw "Service name is blank." }
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $service) { throw "Windows service '$ServiceName' was not found." }
    Restart-Service -Name $ServiceName -Force -ErrorAction Stop
    return "Restarted Windows service '$ServiceName'."
}

function Test-DockerContainerRunning {
    param([string]$Name)
    $result = docker inspect --format "{{.State.Running}}" $Name 2>$null
    return ($LASTEXITCODE -eq 0 -and $result -eq "true")
}

function Restart-DockerContainer {
    param([string]$Name)
    docker restart $Name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "docker restart failed for $Name" }
}

function Add-StatusItem {
    param([string]$Name, [string]$Status, [string]$Detail, [object]$Value = $null)
    $script:StatusItems += [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Value = $Value }
}

function Write-Dashboard {
    param([string]$Path, [object[]]$Items, [datetime]$GeneratedAt)
    $criticalCount = @($Items | Where-Object { $_.Status -eq "critical" }).Count
    $warnCount = @($Items | Where-Object { $_.Status -eq "warn" }).Count
    $overall = if ($criticalCount -gt 0) { "critical" } elseif ($warnCount -gt 0) { "warn" } else { "ok" }
    $overallText = if ($overall -eq "ok") { "All systems online" } elseif ($overall -eq "warn") { "Needs attention" } else { "Action needed" }
    $cards = foreach ($item in $Items) {
        $name = [System.Net.WebUtility]::HtmlEncode($item.Name)
        $detail = [System.Net.WebUtility]::HtmlEncode($item.Detail)
        $valueHtml = ""
        if ($null -ne $item.Value) {
            $value = [math]::Min(100, [math]::Max(0, [double]$item.Value))
            $valueText = "{0:N1}%" -f $item.Value
            $valueHtml = "<div class='meter'><span style='width:$value%'></span></div><div class='metric'>$valueText</div>"
        }
        "<section class='card $($item.Status)'><div class='row'><h2>$name</h2><span>$($item.Status)</span></div><p>$detail</p>$valueHtml</section>"
    }
    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60">
<title>Jellyfin Health Monitor</title>
<style>
:root{color-scheme:dark;font-family:"Segoe UI",system-ui,sans-serif;background:#101417;color:#f3f5f4}
body{margin:0;min-height:100vh;background:#101417}
main{max-width:1040px;margin:0 auto;padding:28px}
header{display:flex;justify-content:space-between;gap:16px;align-items:flex-end;margin-bottom:22px;border-bottom:1px solid #2b3336;padding-bottom:18px}
h1{font-size:30px;line-height:1.1;margin:0;font-weight:700}
.stamp{color:#aeb8b6;font-size:14px;text-align:right}
.summary{display:inline-flex;align-items:center;gap:10px;margin-top:10px;font-size:18px}
.dot{width:12px;height:12px;border-radius:999px;background:#4ade80;box-shadow:0 0 18px #4ade80}
.summary.warn .dot{background:#facc15;box-shadow:0 0 18px #facc15}
.summary.critical .dot{background:#fb7185;box-shadow:0 0 18px #fb7185}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:12px}
.card{border:1px solid #293135;background:#171d20;border-radius:8px;padding:15px;min-height:118px}
.card.ok{border-left:4px solid #4ade80}.card.warn{border-left:4px solid #facc15}.card.critical{border-left:4px solid #fb7185}
.row{display:flex;justify-content:space-between;gap:12px;align-items:center}
h2{margin:0;font-size:16px;font-weight:650}.row span{text-transform:uppercase;font-size:11px;color:#c9d2d0;letter-spacing:.08em}
p{color:#b9c3c0;margin:12px 0 0;font-size:14px;line-height:1.35}
.meter{height:9px;background:#2b3336;border-radius:999px;overflow:hidden;margin-top:14px}.meter span{display:block;height:100%;background:#5eead4}
.warn .meter span{background:#facc15}.critical .meter span{background:#fb7185}.metric{margin-top:7px;color:#e6ecea;font-size:13px}
</style>
</head>
<body><main><header><div><h1>Jellyfin Health Monitor</h1><div class="summary $overall"><span class="dot"></span><span>$overallText</span></div></div><div class="stamp">Updated<br>$($GeneratedAt.ToString("yyyy-MM-dd HH:mm:ss"))</div></header><div class="grid">$($cards -join "`n")</div></main></body>
</html>
"@
    Set-Content -LiteralPath $Path -Value $html -Encoding UTF8
}

$resolvedConfigPath = Resolve-LocalPath -Path $ConfigPath
if (-not (Test-Path -LiteralPath $resolvedConfigPath)) {
    throw "Config file not found. Copy config.example.json to config.json first."
}

$config = Get-Content -LiteralPath $resolvedConfigPath -Raw | ConvertFrom-Json
$statePath = Resolve-LocalPath -Path $config.StatePath
$statusJsonPath = Resolve-LocalPath -Path $config.StatusJsonPath
$dashboardPath = Resolve-LocalPath -Path $config.DashboardPath
$state = Convert-ToHashtable (Read-JsonFile -Path $statePath -Default @{})
$script:StatusItems = @()
$generatedAt = Get-Date

try {
    $publicInfo = Invoke-HealthRequest -Uri "$($config.Jellyfin.Url.TrimEnd('/'))/System/Info/Public"
    if (-not [string]::IsNullOrWhiteSpace($config.Jellyfin.ApiKey)) {
        Invoke-HealthRequest -Uri "$($config.Jellyfin.Url.TrimEnd('/'))/System/Info" -ApiKey $config.Jellyfin.ApiKey | Out-Null
    }
    Set-StateValue -State $state -Key "JellyfinFailedChecks" -Value 0
    $state.Remove("alert-jellyfin")
    Add-StatusItem -Name "Jellyfin Local" -Status "ok" -Detail "Jellyfin is reachable."
}
catch {
    $failedChecks = [int](Get-StateValue -State $state -Key "JellyfinFailedChecks" -Default 0) + 1
    Set-StateValue -State $state -Key "JellyfinFailedChecks" -Value $failedChecks
    if ($failedChecks -ge 3) {
        Send-ProblemAlert -Key "alert-jellyfin" -Title "Jellyfin is offline" `
            -Detail "**Check:** Local Jellyfin`n**Consecutive failures:** $failedChecks`n**Error:** $($_.Exception.Message)" -Ping
    }
    Add-StatusItem -Name "Jellyfin Local" -Status "critical" -Detail "Unreachable. Failed checks: $failedChecks."
    if ($config.Jellyfin.RestartEnabled -and $failedChecks -ge [int]$config.Jellyfin.RestartAfterFailedChecks) {
        try {
            $restartMessage = Restart-Jellyfin -Config $config
            Set-StateValue -State $state -Key "JellyfinFailedChecks" -Value 0
            Write-Host $restartMessage
        }
        catch {
            Write-Host "Jellyfin restart failed: $($_.Exception.Message)"
        }
    }
}

foreach ($publicUrl in @($config.Jellyfin.PublicUrls)) {
    if ([string]::IsNullOrWhiteSpace($publicUrl)) { continue }
    $publicKey = "public-$publicUrl"
    try {
        Invoke-HealthRequest -Uri "$($publicUrl.TrimEnd('/'))/System/Info/Public" | Out-Null
        $state.Remove($publicKey)
        $state.Remove("alert-$publicKey")
        Add-StatusItem -Name "Public URL" -Status "ok" -Detail "$publicUrl is reachable."
    }
    catch {
        $failedChecks = [int](Get-StateValue -State $state -Key $publicKey -Default 0) + 1
        Set-StateValue -State $state -Key $publicKey -Value $failedChecks
        if ($failedChecks -ge 3 -and (Get-StateValue -State $state -Key "JellyfinFailedChecks" -Default 0) -eq 0) {
            Send-ProblemAlert -Key "alert-$publicKey" -Title "JayFlix is unreachable from outside" `
                -Detail "**Public URL:** $publicUrl`n**Consecutive failures:** $failedChecks`nJellyfin is responding locally." -Ping
        }
        Add-StatusItem -Name "Public URL" -Status "critical" -Detail "$publicUrl is unreachable. Failed checks: $failedChecks."
        if ($config.Tunnel.RestartEnabled -and $failedChecks -ge [int]$config.Tunnel.RestartAfterFailedChecks) {
            try {
                $restartMessage = Restart-WindowsServiceIfPresent -ServiceName $config.Tunnel.ServiceName
                Set-StateValue -State $state -Key $publicKey -Value 0
                Write-Host $restartMessage
            }
            catch {
                Write-Host "Tunnel restart failed: $($_.Exception.Message)"
            }
        }
    }
}

$sample = Get-JellyfinProcessSample -ProcessNames $config.Jellyfin.ProcessNames
if ($null -eq $sample) {
    Add-StatusItem -Name "Jellyfin Process" -Status "critical" -Detail "No matching Jellyfin process found."
}
else {
    $os = Get-CimInstance Win32_OperatingSystem
    $totalMemoryBytes = [int64]$os.TotalVisibleMemorySize * 1KB
    $memoryPercent = ($sample.MemoryBytes / $totalMemoryBytes) * 100
    Add-StatusItem -Name "Jellyfin CPU" -Status $(if ($sample.CpuPercent -ge [double]$config.Jellyfin.CpuWarnPercent) { "warn" } else { "ok" }) -Detail "$($sample.ProcessCount) process(es) sampled." -Value $sample.CpuPercent
    Add-StatusItem -Name "Jellyfin Memory" -Status $(if ($memoryPercent -ge [double]$config.Jellyfin.MemoryWarnPercentOfHost) { "warn" } else { "ok" }) -Detail "Percent of host RAM." -Value $memoryPercent
}

foreach ($disk in $config.MediaDisks) {
    $capacityKey = "alert-capacity-$($disk.Path)"
    $healthKey = "alert-drive-$($disk.Path)"
    try {
        $item = Get-Item -LiteralPath $disk.Path -ErrorAction Stop
        $drive = New-Object System.IO.DriveInfo($item.PSDrive.Root)
        $free = $drive.AvailableFreeSpace
        $total = $drive.TotalSize
        $usedPercent = 100 * (1 - $free / $total)
        $volume = Get-Volume -DriveLetter $item.PSDrive.Name -ErrorAction SilentlyContinue
        if ($null -ne $volume -and $volume.HealthStatus -in @("Warning", "Unhealthy")) {
            throw "Windows reports volume health as $($volume.HealthStatus)."
        }
        $state.Remove($healthKey)
        $status = if ($usedPercent -ge [double]$disk.WarnPercent) { "warn" } else { "ok" }
        Add-StatusItem -Name "Disk: $($disk.Name)" -Status $status -Detail $disk.Path -Value $usedPercent
        if ($status -eq "warn") {
            Send-ProblemAlert -Key $capacityKey -Title "Media drive is nearly full" -Color 15105570 `
                -Detail ("**Drive:** {0} ({1})`n**Used:** {2:N1}%`n**Free:** {3:N1} GiB`n**Threshold:** {4}%" -f $disk.Name, $disk.Path, $usedPercent, ($free / 1GB), $disk.WarnPercent)
        }
        else {
            $state.Remove($capacityKey)
        }
    }
    catch {
        Add-StatusItem -Name "Disk: $($disk.Name)" -Status "critical" -Detail "Disk check failed."
        Send-ProblemAlert -Key $healthKey -Title "Media drive needs attention" `
            -Detail "**Drive:** $($disk.Name) ($($disk.Path))`n**Error:** $($_.Exception.Message)"
    }
}

foreach ($container in $config.DockerContainers) {
    try {
        if (Test-DockerContainerRunning -Name $container.Name) {
            Add-StatusItem -Name "Docker: $($container.Name)" -Status "ok" -Detail "Container is running."
        }
        else {
            Add-StatusItem -Name "Docker: $($container.Name)" -Status "critical" -Detail "Container is not running."
            Write-Host "Docker container '$($container.Name)' is not running."
            if ($container.RestartEnabled) { Restart-DockerContainer -Name $container.Name }
        }
    }
    catch {
        Add-StatusItem -Name "Docker: $($container.Name)" -Status "critical" -Detail "Docker check failed."
    }
}

foreach ($service in $config.ArrServices) {
    if (-not $service.Enabled) { continue }
    try {
        Invoke-RestMethod -Method Get -Uri "$($service.Url.TrimEnd('/'))/api/v3/system/status" -Headers @{ "X-Api-Key" = $service.ApiKey } -TimeoutSec 15 | Out-Null
        $health = @(Invoke-RestMethod -Method Get -Uri "$($service.Url.TrimEnd('/'))/api/v3/health" -Headers @{ "X-Api-Key" = $service.ApiKey } -TimeoutSec 15)
        if ($health.Count -gt 0) {
            $messages = @($health | ForEach-Object { "$($_.type): $($_.message)" })
            Add-StatusItem -Name $service.Name -Status "warn" -Detail "$($messages -join '; ')"
        }
        else {
            Add-StatusItem -Name $service.Name -Status "ok" -Detail "API is healthy."
        }
    }
    catch {
        Add-StatusItem -Name $service.Name -Status "critical" -Detail "API check failed."
    }
}

Save-JsonFile -Path $statusJsonPath -Value ([pscustomobject]@{ GeneratedAt = $generatedAt.ToString("o"); Items = @($script:StatusItems) })
Write-Dashboard -Path $dashboardPath -Items @($script:StatusItems) -GeneratedAt $generatedAt
Save-JsonFile -Path $statePath -Value $state
