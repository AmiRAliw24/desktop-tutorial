#!/usr/bin/env bash
# Server monitoring installer - single self-contained file.
# Installs Docker (if missing), then deploys the monitoring panel + Prometheus + Alertmanager +
# node_exporter + cAdvisor + Blackbox exporter under /opt/server-monitoring.
#
# Usage (as root):
#   curl -fsSL https://raw.githubusercontent.com/AmiRAliw24/desktop-tutorial/HEAD/install.sh | sudo bash          # one-liner, interactive
#   curl -fsSL https://raw.githubusercontent.com/AmiRAliw24/desktop-tutorial/HEAD/install.sh | sudo bash -s -- -y # one-liner, no questions (uses env vars)
#   bash install.sh                 # interactive
#   bash install.sh -y              # non-interactive, uses env vars / defaults
#   bash install.sh --no-start      # write files only, don't start containers
#   bash install.sh --uninstall     # stop and remove containers (keeps data volumes)
#   bash install.sh --purge         # also delete data volumes and the install dir
#
# Optional env vars: INSTALL_DIR, PANEL_USER, PANEL_PASSWORD, PANEL_BIND, PANEL_PORT,
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

# True if something is already listening on TCP port $1 (reads /proc, so no extra tools are needed).
port_in_use() {
  local hex f; hex=$(printf '%04X' "$1")
  for f in /proc/net/tcp /proc/net/tcp6; do if [ -r "$f" ]; then cat "$f"; fi; done |
    awk -v h=":$hex" '$4 == "0A" && substr($2, length($2) - 4) == h { found = 1 } END { exit !found }'
}

RESERVED=" "
# choose_port VAR service container_port default
# Picks a free host port for a service and saves it in .env. A port held by this stack's own
# running container is fine (compose keeps it); a port held by anything else is skipped.
choose_port() {
  local var=$1 svc=$2 cport=$3 want p cur=""
  set -a; . "$INSTALL_DIR/.env"; set +a
  want=${!var:-$4}
  if command -v docker >/dev/null 2>&1; then
    cur=$(compose port "$svc" "$cport" 2>/dev/null | head -1 | sed 's/.*://' || true)
  fi
  p=$want
  if [ "$cur" != "$want" ]; then
    while port_in_use "$p" || [[ $RESERVED == *" $p "* ]]; do p=$((p + 1)); done
  fi
  RESERVED+="$p "
  if [ "$p" != "$want" ]; then warn "Port $want is already in use by another program - using $p for $svc instead."; fi
  if grep -q "^$var=" "$INSTALL_DIR/.env"; then sed -i "s/^$var=.*/$var='$p'/" "$INSTALL_DIR/.env"
  else echo "$var='$p'" >> "$INSTALL_DIR/.env"; fi
}

# Older installs kept the login under GRAFANA_* names and also ran Grafana, which is gone now.
# Copy the values to the PANEL_* names, move an old default panel port, drop the stale keys.
migrate_env() {
  local env="$INSTALL_DIR/.env"
  set -a; . "$env"; set +a
  add_key() { grep -q "^$1=" "$env" || echo "$1='$2'" >> "$env"; }
  if ! grep -q '^PANEL_PASSWORD=' "$env"; then
    [ -n "${GRAFANA_ADMIN_PASSWORD:-}" ] || die "No password found in $env - set PANEL_PASSWORD there and re-run."
    add_key PANEL_PASSWORD "$GRAFANA_ADMIN_PASSWORD"
  fi
  add_key PANEL_USER "${GRAFANA_ADMIN_USER:-admin}"
  add_key PANEL_BIND "${GRAFANA_BIND:-0.0.0.0}"
  if grep -q "^PANEL_PORT='8080'" "$env"; then sed -i "s/^PANEL_PORT=.*/PANEL_PORT='3000'/" "$env"; fi
  sed -i '/^GRAFANA_/d' "$env"
}

# Grafana was removed from the stack: drop its old container so its port is released.
remove_legacy_grafana() {
  local ids
  ids=$(docker ps -aq --filter "label=com.docker.compose.project=server-monitoring" --filter "label=com.docker.compose.service=grafana" 2>/dev/null || true)
  [ -z "$ids" ] && return 0
  log "Removing the old Grafana container (the panel replaces it)"
  docker rm -f $ids >/dev/null
}

# set_env_key KEY VALUE - add or update a single-quoted value in .env
set_env_key() {
  if grep -q "^$1=" "$INSTALL_DIR/.env"; then sed -i "s|^$1=.*|$1='$2'|" "$INSTALL_DIR/.env"
  else echo "$1='$2'" >> "$INSTALL_DIR/.env"; fi
}

# ---------------------------------------------------------------- main
FRESH=1; [ -f "$INSTALL_DIR/.env" ] && FRESH=0

if [ "$FRESH" = 1 ]; then
  log "New installation in $INSTALL_DIR"
  # Older docs used GRAFANA_* names for these; accept them as fallbacks.
  PANEL_USER=${PANEL_USER:-${GRAFANA_ADMIN_USER:-}}
  PANEL_PASSWORD=${PANEL_PASSWORD:-${GRAFANA_ADMIN_PASSWORD:-}}
  PANEL_BIND=${PANEL_BIND:-${GRAFANA_BIND:-}}
  ask PANEL_USER "Panel username" admin
  ask PANEL_PASSWORD "Panel password (empty = generate random)" ""
  if [ -z "$PANEL_PASSWORD" ]; then
    PANEL_PASSWORD=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 20)
    GENERATED_PW=1
  fi
  ask PANEL_BIND "Panel listen address (0.0.0.0 = reachable from any network, 127.0.0.1 = local only)" 0.0.0.0
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
  for v in PANEL_USER PANEL_PASSWORD PANEL_BIND PANEL_PORT TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID SITES; do
    case "${!v:-}" in *\'*|*$'\n'*) die "$v must not contain single quotes or newlines." ;; esac
  done
  [[ ${PANEL_PORT:-3000} =~ ^[0-9]{2,5}$ ]] || die "PANEL_PORT must be a number."
  umask 077
  cat > "$INSTALL_DIR/.env" <<ENV
PANEL_USER='$PANEL_USER'
PANEL_PASSWORD='$PANEL_PASSWORD'
PANEL_BIND='$PANEL_BIND'
PANEL_PORT='${PANEL_PORT:-3000}'
PROMETHEUS_RETENTION='${PROMETHEUS_RETENTION:-30d}'
TELEGRAM_BOT_TOKEN='${TELEGRAM_BOT_TOKEN:-}'
TELEGRAM_CHAT_ID='${TELEGRAM_CHAT_ID:-}'
ENV
  umask 022
  mkdir -p "$INSTALL_DIR/prometheus/targets"
  if [ -n "$SITES" ]; then
    first=1
    {
      printf '['
      IFS=',' read -ra urls <<< "$SITES"
      for u in "${urls[@]}"; do
        u=${u//[[:space:]]/}; [ -n "$u" ] || continue
        [[ $u =~ ^https?://[^[:space:]\"\'\`\<\>\\]+$ ]] || die "Not a valid website address: $u (use https://example.com)"
        [ "$first" = 1 ] || printf ','
        first=0
        printf '{"targets": ["%s"], "labels": {}}' "$u"
      done
      printf ']\n'
    } > "$INSTALL_DIR/prometheus/targets/http.json"
  fi
fi

if [ "$FRESH" = 0 ]; then migrate_env; fi
"$INSTALL_DIR/scripts/render-config.sh"

if [ "$NO_START" = 1 ]; then
  choose_port PANEL_PORT panel 8080 3000
  log "Files written to $INSTALL_DIR (--no-start given, containers not started)."
  exit 0
fi

ensure_docker
# The panel needs this group to use the Docker socket (container management).
docker_gid=$(stat -c %g /var/run/docker.sock 2>/dev/null || true)
[ -n "$docker_gid" ] && set_env_key DOCKER_GID "$docker_gid"
log "Pulling images and starting the stack"
compose pull --quiet < /dev/null
remove_legacy_grafana
choose_port PANEL_PORT panel 8080 3000
compose up -d --remove-orphans < /dev/null
# Config files are bind-mounted, so running containers need a nudge to re-read them.
compose kill -s SIGHUP prometheus alertmanager blackbox < /dev/null >/dev/null 2>&1 || true
# The panel's Python code is loaded once at start, so an updated server.py needs a restart.
compose restart panel < /dev/null >/dev/null 2>&1 || true

set -a; . "$INSTALL_DIR/.env"; set +a
log "Waiting for the panel to become healthy"
healthy=0
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${PANEL_PORT:-3000}/healthz" >/dev/null 2>&1; then healthy=1; break; fi
  sleep 2
done
[ "$healthy" = 1 ] || warn "The panel did not respond in 2 minutes. Check: docker compose --project-directory $INSTALL_DIR logs panel"

ip=$(hostname -I 2>/dev/null | awk '{print $1}'); ip=${ip:-<server-ip>}
echo
log "Done."
PANEL_PORT=${PANEL_PORT:-3000}
if [ "${PANEL_BIND:-0.0.0.0}" = 127.0.0.1 ]; then
  echo "  The panel is local-only. From your computer run:  ssh -L $PANEL_PORT:127.0.0.1:$PANEL_PORT root@$ip"
  echo "  then open http://localhost:$PANEL_PORT"
else
  echo "  Panel:    http://$ip:$PANEL_PORT   (open TCP port $PANEL_PORT in your firewall; put HTTPS in front for production)"
fi
echo "  Login:    $PANEL_USER / ${GENERATED_PW:+$PANEL_PASSWORD}${GENERATED_PW:-(the password you chose)}"
[ -n "${GENERATED_PW:-}" ] && echo "  (saved in $INSTALL_DIR/.env)"
if docker volume inspect server-monitoring_grafana_data >/dev/null 2>&1; then
  echo "  Old Grafana data is still on disk; remove it with: docker volume rm server-monitoring_grafana_data"
fi
echo "  Everything else - websites, ports, servers, Telegram, alert rules, Docker containers - is managed inside the panel."
echo "  Manage:   docker compose --project-directory $INSTALL_DIR ps | logs | restart"
exit 0
}

main "$@"
