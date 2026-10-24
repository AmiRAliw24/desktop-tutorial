#!/usr/bin/env bash
# Builds the single-file installer (install.sh) by embedding the project files into
# scripts/installer.tmpl.sh. Re-run after changing any embedded file.
set -euo pipefail
cd "$(dirname "$0")/.."

# path:mode
FILES=(
  docker-compose.yml:644
  .env.example:644
  .gitignore:644
  README.md:644
  prometheus/prometheus.yml:644
  prometheus/rules/alerts.yml:644
  alertmanager/alertmanager.yml.tmpl:644
  blackbox/blackbox.yml:644
  grafana/provisioning/datasources/prometheus.yml:644
  grafana/provisioning/dashboards/dashboards.yml:644
  grafana/dashboards/server-overview.json:644
  scripts/render-config.sh:755
  panel/server.py:644
  panel/static/index.html:644
  panel/static/login.html:644
  panel/static/app.js:644
  panel/static/login.js:644
  panel/static/style.css:644
  panel/static/favicon.svg:644
)
# Targets are only written on first install so user edits survive re-runs.
FIRST_ONLY=(prometheus/targets/http.yml:644 prometheus/targets/tcp.yml:644)

# cat that guarantees a trailing newline, so the heredoc delimiter always starts its own line.
cat_nl() { cat "$1"; [ -z "$(tail -c1 "$1")" ] || echo; }

emit() {  # emit <path:mode> <guard>
  local path=${1%%:*} mode=${1##*:} delim=__MONITORING_EOF__
  grep -qx "$delim" "$path" && { echo "$path contains the heredoc delimiter" >&2; exit 1; }
  if [ "${2:-}" = first ]; then
    printf '  if [ ! -e "$INSTALL_DIR/%s" ]; then\n' "$path"
    printf '  write_file %q %s <<'"'%s'"'\n' "$path" "$mode" "$delim"
    cat_nl "$path"; printf '%s\n  fi\n' "$delim"
  else
    printf '  write_file %q %s <<'"'%s'"'\n' "$path" "$mode" "$delim"
    cat_nl "$path"; printf '%s\n' "$delim"
  fi
}

body=$(for f in "${FILES[@]}"; do emit "$f"; done; for f in "${FIRST_ONLY[@]}"; do emit "$f" first; done)

python3 - "$body" > install.sh <<'PY'
import sys
t = open("scripts/installer.tmpl.sh").read()
sys.stdout.write(t.replace("@@EMBEDDED@@", sys.argv[1].rstrip("\n")))
PY
chmod +x install.sh
bash -n install.sh
echo "Built install.sh ($(wc -c < install.sh) bytes)"
