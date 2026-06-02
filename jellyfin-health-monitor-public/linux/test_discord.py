import json
import pathlib
import urllib.request


config = json.loads(pathlib.Path("config.json").read_text())
webhook = config.get("DiscordWebhookUrl", "").strip()
if not webhook:
    raise SystemExit("DiscordWebhookUrl is blank in config.json")

payload = json.dumps({"content": "Jellyfin Health Monitor Discord test succeeded."}).encode()
request = urllib.request.Request(webhook, data=payload, headers={"Content-Type": "application/json"}, method="POST")
urllib.request.urlopen(request, timeout=15).read()
print("Sent Discord test alert.")
