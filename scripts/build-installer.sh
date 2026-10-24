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
  blackbox/blackbox.yml:644
  scripts/render-config.sh:755
  panel/server.py:644
  panel/store.py:644
  panel/auth.py:644
  panel/dockerapi.py:644
  panel/monitor.py:644
  panel/icons.py:644
  panel/static/index.html:644
  panel/static/login.html:644
  panel/static/app.js:644
  panel/static/login.js:644
  panel/static/style.css:644
  panel/static/favicon.svg:644
)

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

# The embedded files together exceed the 128 KB limit for a single command-line argument,
# so the body goes through a temporary file instead of argv.
body_file=$(mktemp)
trap 'rm -f "$body_file"' EXIT
for f in "${FILES[@]}"; do emit "$f"; done > "$body_file"

python3 - "$body_file" > install.sh <<'PY'
import sys
t = open("scripts/installer.tmpl.sh").read()
body = open(sys.argv[1]).read().rstrip("\n")
sys.stdout.write(t.replace("@@EMBEDDED@@", body))
PY
chmod +x install.sh
bash -n install.sh
echo "Built install.sh ($(wc -c < install.sh) bytes)"
