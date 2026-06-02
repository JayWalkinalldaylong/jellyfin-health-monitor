# Jellyfin Health Monitor

A lightweight cross-platform health monitor for Jellyfin servers.

It checks Jellyfin availability, public URLs, resource usage, disks, Docker containers, and optional Sonarr/Radarr-style services. It can send Discord alerts, generate a local dashboard, and optionally restart Jellyfin or tunnel services after repeated failures.

## Features

- Local Jellyfin health check
- Optional public URL check for reverse proxies or tunnels
- Discord webhook alerts
- Jellyfin CPU and memory monitoring
- Media disk usage warnings
- Docker container checks, useful for Jellyseerr
- Optional Jellyfin auto-restart
- Optional tunnel service auto-restart
- Optional Sonarr/Radarr health checks
- Local `dashboard.html` status page
- Windows Task Scheduler setup
- Linux systemd timer setup

<img width="1189" height="680" alt="Screenshot 2026-06-03 012103" src="https://github.com/user-attachments/assets/b8482caf-2d90-4838-bc7d-26712b445863" />

## Folders

| Folder | Platform |
| --- | --- |
| `windows` | PowerShell monitor for Windows installs |
| `linux` | Python monitor for Linux installs |

## Windows Setup

Open PowerShell in the `windows` folder.

Copy the example config:

```powershell
Copy-Item .\config.example.json .\config.json
```

Edit `config.json`:

- Add your Discord webhook to `DiscordWebhookUrl`
- Set `Jellyfin.Url`
- Add public URLs to `Jellyfin.PublicUrls` if needed
- Add your Jellyfin API key if you want authenticated checks
- Set media disk paths in `MediaDisks`
- Set Docker container names in `DockerContainers`
- Enable restarts only after testing

Test Discord:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\test-discord.ps1
```

Run one manual health check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\monitor.ps1
```

Install as a scheduled task:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-scheduled-task.ps1 -IntervalMinutes 5
```

Run PowerShell as Administrator if you want the monitor to restart Windows services.

## Linux Setup

Open a terminal in the `linux` folder.

Copy the example config:

```bash
cp config.example.json config.json
```

Edit `config.json`:

- Add your Discord webhook to `DiscordWebhookUrl`
- Set `Jellyfin.Url`
- Add public URLs to `Jellyfin.PublicUrls` if needed
- Set `Jellyfin.SystemdService`, usually `jellyfin`
- Set media disk paths in `MediaDisks`
- Set Docker container names in `DockerContainers`
- Enable restarts only after testing

Test Discord:

```bash
python3 test_discord.py
```

Run one manual health check:

```bash
python3 monitor.py
```

Install the systemd timer:

```bash
sudo ./install-systemd.sh
```

The timer runs every 5 minutes.

## Dashboard

Each monitor run writes:

- `status.json`
- `dashboard.html`

Open `dashboard.html` in a browser to view the local status dashboard. The page refreshes automatically.

## Auto-Restart

Auto-restart is disabled by default.

Enable it only after you confirm the monitor works manually.

Windows Jellyfin restart:

```json
"RestartEnabled": true
```

Linux Jellyfin restart:

```json
"RestartEnabled": true
```

Tunnel restart can also be enabled in the `Tunnel` config section.

## Security

Do not commit `config.json`.

It may contain:

- Discord webhooks
- Jellyfin API keys
- Sonarr/Radarr API keys
- Private hostnames or paths

The included `.gitignore` excludes local config, state, dashboard, and log files.

## License

MIT
