#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/jellyfin-health-monitor"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "Run this installer with sudo." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR/linux"
cp -R "$SCRIPT_DIR"/. "$INSTALL_DIR/linux/"

if [[ ! -f "$INSTALL_DIR/linux/config.json" ]]; then
  cp "$INSTALL_DIR/linux/config.example.json" "$INSTALL_DIR/linux/config.json"
  echo "Created $INSTALL_DIR/linux/config.json. Edit it before enabling restarts."
fi

cp "$INSTALL_DIR/linux/jellyfin-health-monitor.service" /etc/systemd/system/
cp "$INSTALL_DIR/linux/jellyfin-health-monitor.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now jellyfin-health-monitor.timer
echo "Installed jellyfin-health-monitor.timer."
