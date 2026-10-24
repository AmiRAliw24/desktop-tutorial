#!/usr/bin/env bash
# Renders alertmanager/alertmanager.yml from the template using values in .env.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "Missing .env - copy .env.example to .env and fill it in." >&2; exit 1; }
set -a; . ./.env; set +a
: "${TELEGRAM_BOT_TOKEN:?}" "${TELEGRAM_CHAT_ID:?}"

# Replace only our two placeholders so Alertmanager's {{ }} templates stay untouched.
tmpl=$(<alertmanager/alertmanager.yml.tmpl)
tmpl=${tmpl//'${TELEGRAM_BOT_TOKEN}'/$TELEGRAM_BOT_TOKEN}
tmpl=${tmpl//'${TELEGRAM_CHAT_ID}'/$TELEGRAM_CHAT_ID}
printf '%s\n' "$tmpl" > alertmanager/alertmanager.yml
echo "Wrote alertmanager/alertmanager.yml"
