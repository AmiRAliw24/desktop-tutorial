#!/usr/bin/env bash
# Prepares what the stack needs before it starts:
#  - alertmanager/alertmanager.yml: a minimal valid config. The panel replaces it as soon as
#    Telegram is connected (Notifications page), so this file is never edited by hand.
#  - data/panel/settings.json: seeds Telegram from TELEGRAM_* in .env, only if the panel has no settings yet.
#  - ownership of the directories the panel writes to (it runs as uid 65534).
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p alertmanager data/panel prometheus/rules prometheus/targets

if [ ! -f alertmanager/alertmanager.yml ]; then
  printf '%s\n' 'route:' '  receiver: none' 'receivers:' '  - name: none' > alertmanager/alertmanager.yml
fi

if [ -f .env ] && [ ! -f data/panel/settings.json ]; then
  set -a; . ./.env; set +a
  token=${TELEGRAM_BOT_TOKEN:-}; chat=${TELEGRAM_CHAT_ID:-}
  if [[ $token =~ ^[0-9]{5,15}:[A-Za-z0-9_-]{25,80}$ && $chat =~ ^-?[0-9]{1,20}$ ]]; then
    umask 077
    printf '{"telegram": {"token": "%s", "chat_id": "%s"}}\n' "$token" "$chat" > data/panel/settings.json
  fi
fi

if [ "$(id -u)" = 0 ]; then
  chown -R 65534:65534 data/panel prometheus/targets prometheus/rules alertmanager
fi
echo "Prepared alertmanager config and panel data directories"
