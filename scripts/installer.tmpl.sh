#!/usr/bin/env bash
# Server monitoring installer - single self-contained file.
# Installs Docker (if missing), then deploys Prometheus + Grafana + Alertmanager +
# node_exporter + cAdvisor + Blackbox exporter under /opt/server-monitoring.
#
# Usage (as root):
#   curl -fsSL <URL>/install.sh | sudo bash          # one-liner, interactive
#   curl -fsSL <URL>/install.sh | sudo bash -s -- -y # one-liner, no questions (uses env vars)
#   bash install.sh                 # interactive
#   bash install.sh -y              # non-interactive, uses env vars / defaults
#   bash install.sh --no-start      # write files only, don't start containers
#   bash install.sh --uninstall     # stop and remove containers (keeps data volumes)
#   bash install.sh --purge         # also delete data volumes and the install dir
#
# Optional env vars: INSTALL_DIR, GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD, GRAFANA_BIND, PANEL_PORT,
#   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, SITES (comma-separated URLs), PROMETHEUS_RETENTION
set -euo pipefail

# Everything lives in main() so bash parses the whole script before running anything.
# This keeps `curl ... | bash` safe: no command can swallow the rest of the script from stdin.
main() {

INSTALL_DIR=${INSTALL_DIR:-/opt/server-monitoring}
ASSUME_YES=0; NO_START=0; ACTION=install
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    --no-start) NO_START=1 ;;
    --uninstall) ACTION=uninstall ;;
    --purge) ACTION=purge ;;
    -h|--help) sed -n '2,19p' "$0" 2>/dev/null || echo 'See the header of install.sh for usage.'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ask VAR "Prompt" "default"  - uses the env var if already set, otherwise prompts (tty only).
ask() {
  local var=$1 prompt=$2 default=${3:-} reply
  if [ -n "${!var:-}" ]; then return; fi
  if [ "$ASSUME_YES" = 1 ] || ! { : < /dev/tty; } 2>/dev/null; then printf -v "$var" '%s' "$default"; return; fi
  read -r -p "$prompt${default:+ [$default]}: " reply < /dev/tty || true
  printf -v "$var" '%s' "${reply:-$default}"
}

write_file() {  # write_file <relative path> [mode]  (content on stdin)
  local path="$INSTALL_DIR/$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  chmod "${2:-644}" "$path"
}

compose() { docker compose --project-directory "$INSTALL_DIR" "$@"; }

[ "$(uname -s)" = Linux ] || die "This installer supports Linux only."
if [ "$NO_START" = 0 ] || [ "$ACTION" != install ]; then
  [ "$(id -u)" = 0 ] || die "Run as root (e.g. sudo bash $0)."
fi

if [ "$ACTION" != install ]; then
  [ -f "$INSTALL_DIR/docker-compose.yml" ] || die "No installation found in $INSTALL_DIR."
  if [ "$ACTION" = purge ]; then
    compose down -v --remove-orphans
    rm -rf "$INSTALL_DIR"
    log "Removed containers, data volumes and $INSTALL_DIR."
  else
    compose down --remove-orphans
    log "Containers stopped and removed. Data volumes and $INSTALL_DIR are kept (use --purge to delete)."
  fi
  exit 0
fi

# ---------------------------------------------------------------- embedded files
extract_files() {
@@EMBEDDED@@
}

# ---------------------------------------------------------------- docker
ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Docker not found - installing via get.docker.com"
    command -v curl >/dev/null 2>&1 || die "curl is required to install Docker."
    curl -fsSL https://get.docker.com | sh
  fi
  command -v systemctl >/dev/null 2>&1 && systemctl enable --now docker >/dev/null 2>&1 || true
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is missing. Install 'docker-compose-plugin' and re-run."
  docker info >/dev/null 2>&1 || die "Docker daemon is not running."
}

# ---------------------------------------------------------------- main
FRESH=1; [ -f "$INSTALL_DIR/.env" ] && FRESH=0

if [ "$FRESH" = 1 ]; then
  log "New installation in $INSTALL_DIR"
  ask GRAFANA_ADMIN_USER "Grafana admin username" admin
  ask GRAFANA_ADMIN_PASSWORD "Grafana admin password (empty = generate random)" ""
  if [ -z "$GRAFANA_ADMIN_PASSWORD" ]; then
    GRAFANA_ADMIN_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
    GENERATED_PW=1
  fi
  ask GRAFANA_BIND "Panel and Grafana listen address (0.0.0.0 = reachable from any network, 127.0.0.1 = local only)" 0.0.0.0
  ask TELEGRAM_BOT_TOKEN "Telegram bot token for alerts (empty = skip)" ""
  TELEGRAM_CHAT_ID=${TELEGRAM_CHAT_ID:-}
  [ -n "$TELEGRAM_BOT_TOKEN" ] && ask TELEGRAM_CHAT_ID "Telegram chat id" ""
  ask SITES "Websites to monitor, comma-separated (empty = none)" ""
else
  log "Existing installation found - updating files, keeping your .env and targets"
fi

mkdir -p "$INSTALL_DIR"
extract_files

if [ "$FRESH" = 1 ]; then
  # Values are single-quoted: .env is read by both bash and Docker Compose, and single quotes
  # keep characters like $ and spaces literal in both.
  for v in GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD GRAFANA_BIND PANEL_PORT TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID SITES; do
    case "${!v:-}" in *\'*|*$'\n'*) die "$v must not contain single quotes or newlines." ;; esac
  done
  [[ ${PANEL_PORT:-8080} =~ ^[0-9]{2,5}$ ]] || die "PANEL_PORT must be a number."
  umask 077
  cat > "$INSTALL_DIR/.env" <<ENV
GRAFANA_ADMIN_USER='$GRAFANA_ADMIN_USER'
GRAFANA_ADMIN_PASSWORD='$GRAFANA_ADMIN_PASSWORD'
GRAFANA_BIND='$GRAFANA_BIND'
PANEL_BIND='$GRAFANA_BIND'
PANEL_PORT='${PANEL_PORT:-8080}'
PROMETHEUS_RETENTION='${PROMETHEUS_RETENTION:-30d}'
TELEGRAM_BOT_TOKEN='${TELEGRAM_BOT_TOKEN:-}'
TELEGRAM_CHAT_ID='${TELEGRAM_CHAT_ID:-}'
ENV
  umask 022
  if [ -n "$SITES" ]; then
    {
      echo "# Websites to monitor. Picked up automatically on save."
      echo "- targets:"
      IFS=',' read -ra urls <<< "$SITES"
      for u in "${urls[@]}"; do u=${u//[[:space:]]/}; [ -n "$u" ] && echo "    - $u"; done
    } > "$INSTALL_DIR/prometheus/targets/http.yml"
  else
    printf '%s\n' '# Websites to monitor. Picked up automatically on save.' '[]' > "$INSTALL_DIR/prometheus/targets/http.yml"
  fi
fi

"$INSTALL_DIR/scripts/render-config.sh"

if [ "$NO_START" = 1 ]; then
  log "Files written to $INSTALL_DIR (--no-start given, containers not started)."
  exit 0
fi

ensure_docker
log "Pulling images and starting the stack"
compose pull --quiet < /dev/null
compose up -d --remove-orphans < /dev/null

log "Waiting for Grafana to become healthy"
healthy=0
for _ in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:3000/api/health >/dev/null 2>&1; then healthy=1; break; fi
  sleep 2
done
[ "$healthy" = 1 ] || warn "Grafana did not respond in 2 minutes. Check: docker compose --project-directory $INSTALL_DIR logs grafana"

set -a; . "$INSTALL_DIR/.env"; set +a
ip=$(hostname -I 2>/dev/null | awk '{print $1}'); ip=${ip:-<server-ip>}
echo
log "Done."
PANEL_PORT=${PANEL_PORT:-8080}
if [ "$GRAFANA_BIND" = 127.0.0.1 ]; then
  echo "  Services are local-only. From your computer run:"
  echo "    ssh -L $PANEL_PORT:127.0.0.1:$PANEL_PORT -L 3000:127.0.0.1:3000 root@$ip"
  echo "  then open http://localhost:$PANEL_PORT (panel) and http://localhost:3000 (Grafana)"
else
  echo "  Panel:    http://$ip:$PANEL_PORT"
  echo "  Grafana:  http://$ip:3000"
  echo "  (open TCP ports $PANEL_PORT and 3000 in your firewall; put HTTPS in front for production)"
fi
echo "  Login:    $GRAFANA_ADMIN_USER / ${GENERATED_PW:+$GRAFANA_ADMIN_PASSWORD}${GENERATED_PW:-(the password you chose)}   (same for panel and Grafana)"
[ -n "${GENERATED_PW:-}" ] && echo "  (saved in $INSTALL_DIR/.env)"
echo "  Websites: edit $INSTALL_DIR/prometheus/targets/http.yml (no restart needed)"
echo "  Manage:   docker compose --project-directory $INSTALL_DIR ps | logs | restart"
[ -z "${TELEGRAM_BOT_TOKEN:-}" ] && echo "  Alerts:   Telegram not configured - fill TELEGRAM_* in $INSTALL_DIR/.env, then run $INSTALL_DIR/scripts/render-config.sh && docker compose --project-directory $INSTALL_DIR restart alertmanager"
exit 0
}

main "$@"
