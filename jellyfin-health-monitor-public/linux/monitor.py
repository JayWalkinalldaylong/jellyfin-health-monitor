#!/usr/bin/env python3
import argparse
import html
import json
import os
import pathlib
import shutil
import subprocess
import time
import urllib.error
import urllib.request


def load_json(path, default):
    p = pathlib.Path(path)
    if not p.exists() or not p.read_text().strip():
        return default
    return json.loads(p.read_text())


def save_json(path, data):
    pathlib.Path(path).write_text(json.dumps(data, indent=2), encoding="utf-8")


def request_json(url, api_key=""):
    headers = {}
    if api_key:
        headers["X-Emby-Token"] = api_key
        headers["X-Api-Key"] = api_key
    request = urllib.request.Request(url, headers=headers, method="GET")
    with urllib.request.urlopen(request, timeout=15) as response:
        body = response.read().decode()
        return json.loads(body) if body else {}


def send_discord(config, message):
    print(message)
    webhook = config.get("DiscordWebhookUrl", "").strip()
    if not webhook:
        return
    payload = json.dumps({"content": message}).encode()
    request = urllib.request.Request(webhook, data=payload, headers={"Content-Type": "application/json"}, method="POST")
    try:
        urllib.request.urlopen(request, timeout=15).read()
    except urllib.error.URLError as exc:
        print(f"Discord alert failed: {exc}")


def should_alert(state, key, cooldown_minutes):
    now = time.time()
    last_alerts = state.setdefault("LastAlerts", {})
    if now - float(last_alerts.get(key, 0)) < cooldown_minutes:
        return False
    last_alerts[key] = now
    return True


def run(command):
    return subprocess.run(command, text=True, capture_output=True, check=False)


def restart_systemd(service):
    if not service:
        raise RuntimeError("systemd service name is blank")
    result = run(["systemctl", "restart", service])
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"systemctl restart {service} failed")
    return f"Restarted systemd service '{service}'."


def docker_running(name):
    result = run(["docker", "inspect", "--format", "{{.State.Running}}", name])
    return result.returncode == 0 and result.stdout.strip() == "true"


def restart_docker(name):
    result = run(["docker", "restart", name])
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"docker restart {name} failed")


def find_pids(process_names):
    pids = []
    for name in process_names:
        result = run(["pgrep", "-x", name])
        if result.returncode == 0:
            pids.extend(int(pid) for pid in result.stdout.split() if pid.isdigit())
    return sorted(set(pids))


def read_proc_stat(pid):
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return int(stat[13]) + int(stat[14])


def read_proc_memory(pid):
    status = pathlib.Path(f"/proc/{pid}/status").read_text().splitlines()
    for line in status:
        if line.startswith("VmRSS:"):
            return int(line.split()[1]) * 1024
    return 0


def total_memory_bytes():
    for line in pathlib.Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemTotal:"):
            return int(line.split()[1]) * 1024
    return 1


def process_sample(process_names):
    pids = find_pids(process_names)
    if not pids:
        return None
    clk_tck = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
    before = sum(read_proc_stat(pid) for pid in pids if pathlib.Path(f"/proc/{pid}").exists())
    time.sleep(1)
    after = sum(read_proc_stat(pid) for pid in pids if pathlib.Path(f"/proc/{pid}").exists())
    cpu_percent = ((after - before) / clk_tck) * 100 / max(1, os.cpu_count() or 1)
    memory = sum(read_proc_memory(pid) for pid in pids if pathlib.Path(f"/proc/{pid}").exists())
    return {"cpu": max(0, cpu_percent), "memory": memory, "count": len(pids)}


def status_item(name, status, detail, value=None):
    return {"Name": name, "Status": status, "Detail": detail, "Value": value}


def write_dashboard(path, items, generated_at):
    critical = sum(1 for item in items if item["Status"] == "critical")
    warn = sum(1 for item in items if item["Status"] == "warn")
    overall = "critical" if critical else "warn" if warn else "ok"
    overall_text = "All systems online" if overall == "ok" else "Needs attention" if overall == "warn" else "Action needed"
    cards = []
    for item in items:
        value_html = ""
        if item.get("Value") is not None:
            value = min(100, max(0, float(item["Value"])))
            value_html = f"<div class='meter'><span style='width:{value}%'></span></div><div class='metric'>{float(item['Value']):.1f}%</div>"
        cards.append(
            f"<section class='card {html.escape(item['Status'])}'><div class='row'><h2>{html.escape(item['Name'])}</h2>"
            f"<span>{html.escape(item['Status'])}</span></div><p>{html.escape(item['Detail'])}</p>{value_html}</section>"
        )
    document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="60"><title>Jellyfin Health Monitor</title>
<style>
:root{{color-scheme:dark;font-family:system-ui,sans-serif;background:#101417;color:#f3f5f4}}body{{margin:0;min-height:100vh;background:#101417}}
main{{max-width:1040px;margin:0 auto;padding:28px}}header{{display:flex;justify-content:space-between;gap:16px;align-items:flex-end;margin-bottom:22px;border-bottom:1px solid #2b3336;padding-bottom:18px}}
h1{{font-size:30px;line-height:1.1;margin:0;font-weight:700}}.stamp{{color:#aeb8b6;font-size:14px;text-align:right}}.summary{{display:inline-flex;align-items:center;gap:10px;margin-top:10px;font-size:18px}}
.dot{{width:12px;height:12px;border-radius:999px;background:#4ade80;box-shadow:0 0 18px #4ade80}}.summary.warn .dot{{background:#facc15;box-shadow:0 0 18px #facc15}}.summary.critical .dot{{background:#fb7185;box-shadow:0 0 18px #fb7185}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(230px,1fr));gap:12px}}.card{{border:1px solid #293135;background:#171d20;border-radius:8px;padding:15px;min-height:118px}}
.card.ok{{border-left:4px solid #4ade80}}.card.warn{{border-left:4px solid #facc15}}.card.critical{{border-left:4px solid #fb7185}}.row{{display:flex;justify-content:space-between;gap:12px;align-items:center}}
h2{{margin:0;font-size:16px;font-weight:650}}.row span{{text-transform:uppercase;font-size:11px;color:#c9d2d0;letter-spacing:.08em}}p{{color:#b9c3c0;margin:12px 0 0;font-size:14px;line-height:1.35}}
.meter{{height:9px;background:#2b3336;border-radius:999px;overflow:hidden;margin-top:14px}}.meter span{{display:block;height:100%;background:#5eead4}}.warn .meter span{{background:#facc15}}.critical .meter span{{background:#fb7185}}.metric{{margin-top:7px;color:#e6ecea;font-size:13px}}
</style></head><body><main><header><div><h1>Jellyfin Health Monitor</h1><div class="summary {overall}"><span class="dot"></span><span>{overall_text}</span></div></div><div class="stamp">Updated<br>{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(generated_at))}</div></header><div class="grid">{''.join(cards)}</div></main></body></html>"""
    pathlib.Path(path).write_text(document, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", default="config.json")
    args = parser.parse_args()

    config = load_json(args.config, None)
    if config is None:
        raise SystemExit("Config file not found. Copy config.example.json to config.json first.")

    state = load_json(config["StatePath"], {})
    items = []
    generated_at = time.time()

    try:
        request_json(config["Jellyfin"]["Url"].rstrip("/") + "/System/Info/Public")
        if config["Jellyfin"].get("ApiKey"):
            request_json(config["Jellyfin"]["Url"].rstrip("/") + "/System/Info", config["Jellyfin"]["ApiKey"])
        state["JellyfinFailedChecks"] = 0
        items.append(status_item("Jellyfin Local", "ok", "Jellyfin is reachable."))
    except Exception as exc:
        failed = int(state.get("JellyfinFailedChecks", 0)) + 1
        state["JellyfinFailedChecks"] = failed
        send_discord(config, f"Jellyfin is unreachable. Failed checks: {failed}. Error: {exc}")
        items.append(status_item("Jellyfin Local", "critical", f"Unreachable. Failed checks: {failed}."))
        if config["Jellyfin"].get("RestartEnabled") and failed >= int(config["Jellyfin"].get("RestartAfterFailedChecks", 3)):
            try:
                message = restart_systemd(config["Jellyfin"].get("SystemdService", ""))
                state["JellyfinFailedChecks"] = 0
                send_discord(config, message)
            except Exception as restart_exc:
                send_discord(config, f"Jellyfin restart failed: {restart_exc}")

    for public_url in config["Jellyfin"].get("PublicUrls", []):
        try:
            request_json(public_url.rstrip("/") + "/System/Info/Public")
            state["TunnelFailedChecks"] = 0
            items.append(status_item("Public URL", "ok", f"{public_url} is reachable."))
        except Exception:
            failed = int(state.get("TunnelFailedChecks", 0)) + 1
            state["TunnelFailedChecks"] = failed
            if should_alert(state, f"public-url-{public_url}", int(config["AlertCooldownMinutes"])):
                send_discord(config, f"Public Jellyfin URL is unreachable: {public_url}. Failed checks: {failed}.")
            items.append(status_item("Public URL", "critical", f"{public_url} is unreachable. Failed checks: {failed}."))
            if config["Tunnel"].get("RestartEnabled") and failed >= int(config["Tunnel"].get("RestartAfterFailedChecks", 3)):
                try:
                    message = restart_systemd(config["Tunnel"].get("SystemdService", ""))
                    state["TunnelFailedChecks"] = 0
                    send_discord(config, message)
                except Exception as restart_exc:
                    send_discord(config, f"Tunnel restart failed: {restart_exc}")

    sample = process_sample(config["Jellyfin"].get("ProcessNames", ["jellyfin"]))
    if sample is None:
        items.append(status_item("Jellyfin Process", "critical", "No matching Jellyfin process found."))
    else:
        memory_percent = sample["memory"] / total_memory_bytes() * 100
        items.append(status_item("Jellyfin CPU", "warn" if sample["cpu"] >= config["Jellyfin"]["CpuWarnPercent"] else "ok", f"{sample['count']} process(es) sampled.", sample["cpu"]))
        items.append(status_item("Jellyfin Memory", "warn" if memory_percent >= config["Jellyfin"]["MemoryWarnPercentOfHost"] else "ok", "Percent of host RAM.", memory_percent))

    for disk in config.get("MediaDisks", []):
        try:
            usage = shutil.disk_usage(disk["Path"])
            used = usage.used / usage.total * 100
            status = "warn" if used >= disk["WarnPercent"] else "ok"
            items.append(status_item(f"Disk: {disk['Name']}", status, disk["Path"], used))
            if status == "warn" and should_alert(state, f"disk-{disk['Name']}", int(config["AlertCooldownMinutes"])):
                send_discord(config, f"Disk '{disk['Name']}' is almost full: {used:.1f}%.")
        except Exception:
            items.append(status_item(f"Disk: {disk['Name']}", "critical", "Disk check failed."))

    for container in config.get("DockerContainers", []):
        try:
            if docker_running(container["Name"]):
                items.append(status_item(f"Docker: {container['Name']}", "ok", "Container is running."))
            else:
                items.append(status_item(f"Docker: {container['Name']}", "critical", "Container is not running."))
                send_discord(config, f"Docker container '{container['Name']}' is not running.")
                if container.get("RestartEnabled"):
                    restart_docker(container["Name"])
        except Exception:
            items.append(status_item(f"Docker: {container['Name']}", "critical", "Docker check failed."))

    for service in config.get("ArrServices", []):
        if not service.get("Enabled"):
            continue
        try:
            api_url = service["Url"].rstrip("/")
            request_json(api_url + "/api/v3/system/status", service["ApiKey"])
            health = request_json(api_url + "/api/v3/health", service["ApiKey"])
            if health:
                messages = "; ".join(f"{item.get('type')}: {item.get('message')}" for item in health)
                items.append(status_item(service["Name"], "warn", messages))
            else:
                items.append(status_item(service["Name"], "ok", "API is healthy."))
        except Exception:
            items.append(status_item(service["Name"], "critical", "API check failed."))

    save_json(config["StatusJsonPath"], {"GeneratedAt": generated_at, "Items": items})
    write_dashboard(config["DashboardPath"], items, generated_at)
    save_json(config["StatePath"], state)


if __name__ == "__main__":
    main()
