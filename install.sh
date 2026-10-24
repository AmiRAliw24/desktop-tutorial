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
  write_file docker-compose.yml 644 <<'__MONITORING_EOF__'
name: server-monitoring

services:
  prometheus:
    image: prom/prometheus:v2.55.1
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=${PROMETHEUS_RETENTION:-30d}
      - --web.enable-lifecycle
    volumes:
      - ./prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./prometheus/rules:/etc/prometheus/rules:ro
      - ./prometheus/targets:/etc/prometheus/targets:ro
      - prometheus_data:/prometheus
    ports:
      - "127.0.0.1:9090:9090"
    networks: [monitoring]

  alertmanager:
    image: prom/alertmanager:v0.27.0
    restart: unless-stopped
    command:
      - --config.file=/etc/alertmanager/alertmanager.yml
      - --storage.path=/alertmanager
    volumes:
      - ./alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - alertmanager_data:/alertmanager
    ports:
      - "127.0.0.1:9093:9093"
    networks: [monitoring]

  node-exporter:
    image: prom/node-exporter:v1.8.2
    restart: unless-stopped
    pid: host
    command:
      - --path.rootfs=/host
      - --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)
    volumes:
      - /:/host:ro,rslave
    networks: [monitoring]

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/kmsg
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
    networks: [monitoring]

  blackbox:
    image: prom/blackbox-exporter:v0.25.0
    restart: unless-stopped
    command: --config.file=/etc/blackbox/blackbox.yml
    volumes:
      - ./blackbox/blackbox.yml:/etc/blackbox/blackbox.yml:ro
    networks: [monitoring]

  panel:
    image: python:3.12-alpine
    restart: unless-stopped
    command: ["python", "-u", "/app/server.py"]
    user: "65534:65534"
    read_only: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    environment:
      PYTHONDONTWRITEBYTECODE: "1"
      PROMETHEUS_URL: http://prometheus:9090
      PANEL_USER: ${GRAFANA_ADMIN_USER:-admin}
      PANEL_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD in .env}
      PANEL_LISTEN_PORT: "8080"
    volumes:
      - ./panel:/app:ro
    ports:
      - "${PANEL_BIND:-0.0.0.0}:${PANEL_PORT:-8080}:8080"
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/healthz', timeout=3)"]
      interval: 30s
      timeout: 5s
      retries: 3
    depends_on: [prometheus]
    networks: [monitoring]

  grafana:
    image: grafana/grafana:11.3.0
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_USER: ${GRAFANA_ADMIN_USER:-admin}
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_ADMIN_PASSWORD:?set GRAFANA_ADMIN_PASSWORD in .env}
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
      - ./grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana_data:/var/lib/grafana
    ports:
      - "${GRAFANA_BIND:-0.0.0.0}:3000:3000"
    depends_on: [prometheus]
    networks: [monitoring]

volumes:
  prometheus_data:
  alertmanager_data:
  grafana_data:

networks:
  monitoring:
__MONITORING_EOF__
  write_file .env.example 644 <<'__MONITORING_EOF__'
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=change-me
PROMETHEUS_RETENTION=30d

# Telegram alerts: create a bot with @BotFather, then get your chat id from @userinfobot
TELEGRAM_BOT_TOKEN=123456:ABC-your-token
TELEGRAM_CHAT_ID=123456789

# 0.0.0.0   = Grafana reachable from any network on port 3000 (open the port in your firewall)
# 127.0.0.1 = local only (use an SSH tunnel or reverse proxy)
GRAFANA_BIND=0.0.0.0

# Web panel (the main dashboard). Login = the Grafana admin user/password above.
PANEL_BIND=0.0.0.0
PANEL_PORT=8080
__MONITORING_EOF__
  write_file .gitignore 644 <<'__MONITORING_EOF__'
.env
alertmanager/alertmanager.yml
__MONITORING_EOF__
  write_file README.md 644 <<'__MONITORING_EOF__'
# مانیتورینگ کامل سرور

استک آماده‌ی مانیتورینگ با Docker Compose:

| سرویس | کار |
|---|---|
| **Prometheus** | جمع‌آوری و ذخیره متریک‌ها (۳۰ روز) |
| **پنل وب** | داشبورد اصلی و سبک با ظاهر اختصاصی (پورت 8080) |
| **Grafana** | نمودارهای پیشرفته (Server Overview به‌صورت خودکار نصب می‌شود) |
| **Alertmanager** | ارسال هشدار به تلگرام |
| **node_exporter** | متریک‌های سیستم: CPU، رم، دیسک، شبکه، load |
| **cAdvisor** | متریک کانتینرهای Docker |
| **Blackbox exporter** | چک آپتایم سایت‌ها، پورت‌ها و انقضای SSL |

## پنل وب (داشبورد اصلی)

علاوه بر Grafana، یک پنل وب اختصاصی نصب می‌شود (پوشه `panel/`): تم تیره/روشن، فارسی و انگلیسی (با راست‌به‌چپ)، کارت‌های آماری زنده، و بخش‌های نمای کلی، کانتینرها، سایت‌ها، دیسک‌ها، شبکه، تارگت‌ها و هشدارها.

- آدرس: `http://IP-SERVER:8080` (پورت با `PANEL_PORT` در `.env` عوض می‌شود)
- ورود: همان نام کاربری و رمز Grafana (`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`)
- داده‌ها را فقط‌خواندنی از Prometheus می‌گیرد؛ کوئیری دلخواه از بیرون پذیرفته نمی‌شود.
- ورود اشتباه با تأخیر یک‌ثانیه‌ای رد می‌شود، کوکی نشست `HttpOnly` است و با عوض شدن رمز همه‌ی نشست‌ها باطل می‌شوند.
- پورت پنل (8080) و Grafana (3000) باید در فایروال سرور و پنل هاستینگ باز باشند.
- برای HTTPS یک reverse proxy (مثلاً Caddy) جلوی پورت 8080 بگذارید.

## نصب یک‌خطی

روی سرور (به‌عنوان root یا با sudo):

```bash
curl -fsSL https://raw.githubusercontent.com/AmiRAliw24/desktop-tutorial/main/install.sh | sudo bash
```

بدون سؤال، با متغیرهای محیطی (به `-E` یا `env` دقت کنید تا متغیرها به sudo برسند):

```bash
curl -fsSL https://raw.githubusercontent.com/AmiRAliw24/desktop-tutorial/main/install.sh | sudo env GRAFANA_ADMIN_PASSWORD='...' SITES='https://a.com' bash -s -- -y
```

این آدرس فقط وقتی کار می‌کند که ریپو public باشد و `install.sh` روی برنچ `main` قرار گرفته باشد. اگر ریپو private است، فایل را با `scp` کپی کنید (روش بعدی).

## نصب روی سرور لینوکسی (تک‌فایل)

فقط فایل `install.sh` را روی سرور کپی کنید (مثلاً `scp install.sh root@SERVER:`) و اجرا کنید:

```bash
sudo bash install.sh
```

نصب‌کننده خودش Docker را (اگر نباشد) نصب می‌کند، همه فایل‌ها را در `/opt/server-monitoring` می‌سازد و استک را بالا می‌آورد. چند سؤال می‌پرسد: رمز Grafana (خالی = رمز تصادفی)، آدرس listen (پیش‌فرض `0.0.0.0`، یعنی از هر شبکه‌ای)، توکن تلگرام (اختیاری) و لیست سایت‌ها (اختیاری).

بدون سؤال (برای اسکریپت و اتوماسیون):

```bash
sudo GRAFANA_ADMIN_PASSWORD='...' GRAFANA_BIND=0.0.0.0 \
     TELEGRAM_BOT_TOKEN='...' TELEGRAM_CHAT_ID='...' \
     SITES='https://a.com,https://b.org' bash install.sh -y
```

| گزینه | کار |
|---|---|
| `-y` | بدون سؤال، با متغیرهای محیطی و پیش‌فرض‌ها |
| `--no-start` | فقط فایل‌ها را بنویس، کانتینری بالا نیاور |
| `--uninstall` | کانتینرها را حذف کن (داده‌ها می‌مانند) |
| `--purge` | کانتینرها، داده‌ها و پوشه نصب را کامل حذف کن |

اجرای دوباره `install.sh` امن است: فایل‌ها آپدیت می‌شوند ولی `.env` و لیست سایت‌های شما دست نمی‌خورد.

اگر Grafana را روی `127.0.0.1` بگذارید، از کامپیوتر خودتان با `ssh -L 3000:127.0.0.1:3000 root@SERVER` وصل شوید. با `0.0.0.0` (پیش‌فرض) پورت 3000 باید در فایروال سرور و پنل هاستینگ باز باشد، و برای محیط واقعی حتماً HTTPS جلویش بگذارید.

> `install.sh` از روی فایل‌های همین ریپو ساخته می‌شود. بعد از تغییر هر فایل، `./scripts/build-installer.sh` را اجرا کنید.

## راه‌اندازی دستی (بدون نصب‌کننده)

```bash
cp .env.example .env        # رمز Grafana و توکن/چت‌آیدی تلگرام را بنویسید
./scripts/render-config.sh  # ساخت alertmanager/alertmanager.yml از روی .env
docker compose up -d
```

- پنل وب: http://localhost:8080
- Grafana: http://localhost:3000
- Prometheus: http://localhost:9090
- Alertmanager: http://localhost:9093

## تنظیمات

- **سایت‌ها و پورت‌ها:** فایل `prometheus/targets/http.yml` (سایت‌ها) و `prometheus/targets/tcp.yml` (پورت‌ها) را ویرایش کنید؛ بعد از ذخیره خودکار اعمال می‌شود و ری‌استارت لازم نیست.
- **سرور اضافه:** `node_exporter` را روی سرور دیگر نصب کنید و `IP:9100` را به job به نام `node` در `prometheus/prometheus.yml` اضافه کنید (ایمن‌تر: پورت 9100 را فقط برای IP سرور مانیتورینگ در فایروال باز کنید).
- **هشدارها:** `prometheus/rules/alerts.yml` شامل ۱۲ قانون است: خاموشی هدف، CPU/رم/دیسک بالا، پر شدن دیسک تا ۲۴ ساعت آینده، load، ری‌استارت سرور، مصرف کانتینر، قطعی سایت، کندی پاسخ و انقضای SSL (کمتر از ۱۴ روز).
- **ایمیل یا Slack:** در `alertmanager/alertmanager.yml.tmpl` یک receiver جدید اضافه کنید.

## تست هشدار

```bash
curl -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","severity":"warning"},"annotations":{"summary":"تست هشدار"}}]'
```
__MONITORING_EOF__
  write_file prometheus/prometheus.yml 644 <<'__MONITORING_EOF__'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: [alertmanager:9093]

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: [localhost:9090]

  - job_name: node
    static_configs:
      - targets: [node-exporter:9100]
        labels:
          instance_name: this-server
    # Add more servers by running node_exporter on them and listing them here.

  - job_name: cadvisor
    static_configs:
      - targets: [cadvisor:8080]

  # Uptime / SSL checks. Targets live in prometheus/targets/http.yml (reloaded automatically).
  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_2xx]
    file_sd_configs:
      - files: [/etc/prometheus/targets/http.yml]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115

  # TCP port checks (e.g. SSH, database). Targets live in prometheus/targets/tcp.yml.
  - job_name: blackbox-tcp
    metrics_path: /probe
    params:
      module: [tcp_connect]
    file_sd_configs:
      - files: [/etc/prometheus/targets/tcp.yml]
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
__MONITORING_EOF__
  write_file prometheus/rules/alerts.yml 644 <<'__MONITORING_EOF__'
groups:
  - name: host
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 2m
        labels: {severity: critical}
        annotations:
          summary: "{{ $labels.job }} target {{ $labels.instance }} is down"

      - alert: HighCpuUsage
        expr: 100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 85
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "CPU usage on {{ $labels.instance }} is {{ $value | printf \"%.0f\" }}%"

      - alert: HighMemoryUsage
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 90
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "Memory usage on {{ $labels.instance }} is {{ $value | printf \"%.0f\" }}%"

      - alert: DiskSpaceLow
        expr: |
          (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"}
             / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs"}) * 100 > 85
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "Disk {{ $labels.mountpoint }} on {{ $labels.instance }} is {{ $value | printf \"%.0f\" }}% full"

      - alert: DiskWillFillIn24h
        expr: |
          predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"}[6h], 24 * 3600) < 0
        for: 30m
        labels: {severity: critical}
        annotations:
          summary: "Disk {{ $labels.mountpoint }} on {{ $labels.instance }} is predicted to fill within 24h"

      - alert: HighLoad
        expr: node_load5 / count by (instance) (node_cpu_seconds_total{mode="idle"}) > 2
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "Load average on {{ $labels.instance }} is high ({{ $value | printf \"%.1f\" }}x cores)"

      - alert: HostRebooted
        expr: time() - node_boot_time_seconds < 300
        labels: {severity: info}
        annotations:
          summary: "{{ $labels.instance }} was rebooted in the last 5 minutes"

  - name: containers
    rules:
      - alert: ContainerHighCpu
        expr: sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[5m])) * 100 > 90
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "Container {{ $labels.name }} CPU is {{ $value | printf \"%.0f\" }}%"

      - alert: ContainerHighMemory
        expr: |
          container_memory_working_set_bytes{name!=""}
            / (container_spec_memory_limit_bytes{name!=""} > 0) * 100 > 90
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "Container {{ $labels.name }} memory is {{ $value | printf \"%.0f\" }}% of its limit"

  - name: endpoints
    rules:
      - alert: EndpointDown
        expr: probe_success == 0
        for: 2m
        labels: {severity: critical}
        annotations:
          summary: "{{ $labels.instance }} is unreachable"

      - alert: SslCertExpiringSoon
        expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 14
        for: 1h
        labels: {severity: warning}
        annotations:
          summary: "SSL certificate for {{ $labels.instance }} expires in {{ $value | printf \"%.0f\" }} days"

      - alert: SlowEndpoint
        expr: probe_duration_seconds > 3
        for: 10m
        labels: {severity: warning}
        annotations:
          summary: "{{ $labels.instance }} responds slowly ({{ $value | printf \"%.1f\" }}s)"
__MONITORING_EOF__
  write_file alertmanager/alertmanager.yml.tmpl 644 <<'__MONITORING_EOF__'
# Rendered to alertmanager.yml by scripts/render-config.sh (values come from .env).
route:
  receiver: telegram
  group_by: [alertname, instance]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers: [severity="critical"]
      receiver: telegram
      repeat_interval: 1h

receivers:
  - name: telegram
    telegram_configs:
      - bot_token: "${TELEGRAM_BOT_TOKEN}"
        chat_id: ${TELEGRAM_CHAT_ID}
        parse_mode: ""
        send_resolved: true
        message: |
          {{ range .Alerts }}{{ if eq .Status "firing" }}🔥{{ else }}✅{{ end }} [{{ .Labels.severity }}] {{ .Annotations.summary }}
          {{ end }}

inhibit_rules:
  - source_matchers: [severity="critical"]
    target_matchers: [severity="warning"]
    equal: [alertname, instance]
__MONITORING_EOF__
  write_file blackbox/blackbox.yml 644 <<'__MONITORING_EOF__'
modules:
  http_2xx:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true
  tcp_connect:
    prober: tcp
    timeout: 5s
__MONITORING_EOF__
  write_file grafana/provisioning/datasources/prometheus.yml 644 <<'__MONITORING_EOF__'
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
__MONITORING_EOF__
  write_file grafana/provisioning/dashboards/dashboards.yml 644 <<'__MONITORING_EOF__'
apiVersion: 1
providers:
  - name: default
    type: file
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
__MONITORING_EOF__
  write_file grafana/dashboards/server-overview.json 644 <<'__MONITORING_EOF__'
{
  "uid": "server-overview",
  "title": "Server Overview",
  "tags": [
    "monitoring"
  ],
  "timezone": "browser",
  "refresh": "30s",
  "schemaVersion": 39,
  "version": 1,
  "time": {
    "from": "now-6h",
    "to": "now"
  },
  "panels": [
    {
      "id": 1,
      "type": "stat",
      "title": "CPU usage",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 0,
        "w": 4,
        "h": 4
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "yellow",
                "value": 70
              },
              {
                "color": "red",
                "value": 90
              }
            ]
          },
          "color": {
            "mode": "thresholds"
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "100 - avg(rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100",
          "legendFormat": ""
        }
      ],
      "options": {
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ]
        },
        "colorMode": "background"
      }
    },
    {
      "id": 2,
      "type": "stat",
      "title": "Memory usage",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 4,
        "y": 0,
        "w": 4,
        "h": 4
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "yellow",
                "value": 70
              },
              {
                "color": "red",
                "value": 90
              }
            ]
          },
          "color": {
            "mode": "thresholds"
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100",
          "legendFormat": ""
        }
      ],
      "options": {
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ]
        },
        "colorMode": "background"
      }
    },
    {
      "id": 3,
      "type": "stat",
      "title": "Root disk usage",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 8,
        "y": 0,
        "w": 4,
        "h": 4
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "yellow",
                "value": 70
              },
              {
                "color": "red",
                "value": 90
              }
            ]
          },
          "color": {
            "mode": "thresholds"
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "(1 - node_filesystem_avail_bytes{mountpoint=\"/\"} / node_filesystem_size_bytes{mountpoint=\"/\"}) * 100",
          "legendFormat": ""
        }
      ],
      "options": {
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ]
        },
        "colorMode": "background"
      }
    },
    {
      "id": 4,
      "type": "stat",
      "title": "Uptime",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 12,
        "y": 0,
        "w": 4,
        "h": 4
      },
      "fieldConfig": {
        "defaults": {
          "unit": "s"
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "time() - node_boot_time_seconds",
          "legendFormat": ""
        }
      ],
      "options": {
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ]
        },
        "colorMode": "background"
      }
    },
    {
      "id": 5,
      "type": "stat",
      "title": "Targets up",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 16,
        "y": 0,
        "w": 4,
        "h": 4
      },
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "sum(up)",
          "legendFormat": "up"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "B",
          "expr": "count(up)",
          "legendFormat": "total"
        }
      ],
      "options": {
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ]
        },
        "colorMode": "background"
      }
    },
    {
      "id": 6,
      "type": "stat",
      "title": "Firing alerts",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 20,
        "y": 0,
        "w": 4,
        "h": 4
      },
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {
                "color": "green",
                "value": null
              },
              {
                "color": "red",
                "value": 1
              }
            ]
          },
          "color": {
            "mode": "thresholds"
          }
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "count(ALERTS{alertstate=\"firing\"}) or vector(0)",
          "legendFormat": ""
        }
      ],
      "options": {
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ]
        },
        "colorMode": "background"
      }
    },
    {
      "id": 7,
      "type": "timeseries",
      "title": "CPU by mode",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 4,
        "w": 12,
        "h": 8
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent"
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "sum by (mode) (rate(node_cpu_seconds_total{mode!=\"idle\"}[5m])) * 100",
          "legendFormat": "{{mode}}"
        }
      ]
    },
    {
      "id": 8,
      "type": "timeseries",
      "title": "Memory",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 12,
        "y": 4,
        "w": 12,
        "h": 8
      },
      "fieldConfig": {
        "defaults": {
          "unit": "bytes"
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes",
          "legendFormat": "used"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "B",
          "expr": "node_memory_MemTotal_bytes",
          "legendFormat": "total"
        }
      ]
    },
    {
      "id": 9,
      "type": "timeseries",
      "title": "Load average",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 12,
        "w": 12,
        "h": 8
      },
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "node_load1",
          "legendFormat": "1m"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "B",
          "expr": "node_load5",
          "legendFormat": "5m"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "C",
          "expr": "node_load15",
          "legendFormat": "15m"
        }
      ]
    },
    {
      "id": 10,
      "type": "timeseries",
      "title": "Network traffic",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 12,
        "y": 12,
        "w": 12,
        "h": 8
      },
      "fieldConfig": {
        "defaults": {
          "unit": "Bps"
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "sum(rate(node_network_receive_bytes_total{device!~\"lo|veth.*|docker.*|br-.*\"}[5m]))",
          "legendFormat": "rx"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "B",
          "expr": "-sum(rate(node_network_transmit_bytes_total{device!~\"lo|veth.*|docker.*|br-.*\"}[5m]))",
          "legendFormat": "tx"
        }
      ]
    },
    {
      "id": 11,
      "type": "timeseries",
      "title": "Disk usage by mountpoint",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 20,
        "w": 12,
        "h": 8
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "(1 - node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay|squashfs\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay|squashfs\"}) * 100",
          "legendFormat": "{{mountpoint}}"
        }
      ]
    },
    {
      "id": 12,
      "type": "timeseries",
      "title": "Disk I/O",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 12,
        "y": 20,
        "w": 12,
        "h": 8
      },
      "fieldConfig": {
        "defaults": {
          "unit": "Bps"
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "sum(rate(node_disk_read_bytes_total[5m]))",
          "legendFormat": "read"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "B",
          "expr": "sum(rate(node_disk_written_bytes_total[5m]))",
          "legendFormat": "write"
        }
      ]
    },
    {
      "id": 13,
      "type": "timeseries",
      "title": "Container CPU",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 28,
        "w": 12,
        "h": 8
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent"
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "sum by (name) (rate(container_cpu_usage_seconds_total{name!=\"\"}[5m])) * 100",
          "legendFormat": "{{name}}"
        }
      ]
    },
    {
      "id": 14,
      "type": "timeseries",
      "title": "Container memory",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 12,
        "y": 28,
        "w": 12,
        "h": 8
      },
      "fieldConfig": {
        "defaults": {
          "unit": "bytes"
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "sum by (name) (container_memory_working_set_bytes{name!=\"\"})",
          "legendFormat": "{{name}}"
        }
      ]
    },
    {
      "id": 15,
      "type": "table",
      "title": "Endpoint checks",
      "datasource": {
        "type": "prometheus",
        "uid": "prometheus"
      },
      "gridPos": {
        "x": 0,
        "y": 36,
        "w": 24,
        "h": 8
      },
      "fieldConfig": {
        "defaults": {
          "unit": "short"
        },
        "overrides": []
      },
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "A",
          "expr": "probe_success",
          "legendFormat": "up"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "B",
          "expr": "probe_duration_seconds",
          "legendFormat": "response s"
        },
        {
          "datasource": {
            "type": "prometheus",
            "uid": "prometheus"
          },
          "refId": "C",
          "expr": "(probe_ssl_earliest_cert_expiry - time()) / 86400",
          "legendFormat": "ssl days left"
        }
      ]
    }
  ]
}
__MONITORING_EOF__
  write_file scripts/render-config.sh 755 <<'__MONITORING_EOF__'
#!/usr/bin/env bash
# Renders alertmanager/alertmanager.yml from the template using values in .env.
# Without Telegram credentials, alerts are still evaluated and visible in Grafana/Prometheus
# but are not delivered anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] || { echo "Missing .env - copy .env.example to .env and fill it in." >&2; exit 1; }
set -a; . ./.env; set +a

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ] || [ -z "${TELEGRAM_CHAT_ID:-}" ]; then
  cat > alertmanager/alertmanager.yml <<'YAML'
route:
  receiver: none
receivers:
  - name: none
YAML
  echo "Wrote alertmanager/alertmanager.yml (no Telegram configured, notifications disabled)"
  exit 0
fi

# Replace only our two placeholders so Alertmanager's {{ }} templates stay untouched.
tmpl=$(<alertmanager/alertmanager.yml.tmpl)
tmpl=${tmpl//'${TELEGRAM_BOT_TOKEN}'/$TELEGRAM_BOT_TOKEN}
tmpl=${tmpl//'${TELEGRAM_CHAT_ID}'/$TELEGRAM_CHAT_ID}
printf '%s\n' "$tmpl" > alertmanager/alertmanager.yml
echo "Wrote alertmanager/alertmanager.yml"
__MONITORING_EOF__
  write_file panel/server.py 644 <<'__MONITORING_EOF__'
#!/usr/bin/env python3
"""Monitoring panel backend: login, static files and a small read-only JSON API over Prometheus.

Only fixed queries are exposed (no arbitrary PromQL). Standard library only.
"""
import hashlib
import hmac
import json
import math
import os
import re
import sys
import threading
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlparse
from urllib.request import urlopen

PROM = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090").rstrip("/")
USER = os.environ.get("PANEL_USER", "admin")
PASSWORD = os.environ.get("PANEL_PASSWORD", "")
PORT = int(os.environ.get("PANEL_LISTEN_PORT", "8080"))
STATIC = Path(__file__).parent / "static"
SESSION_TTL = 7 * 24 * 3600
COOKIE = "panel_session"

if not PASSWORD:
    sys.exit("PANEL_PASSWORD must be set")

# Sessions are signed with a key derived from the credentials: changing the password logs everyone out.
SECRET = hashlib.sha256(f"panel-session:{USER}:{PASSWORD}".encode()).digest()

PUBLIC_FILES = {
    "/login": ("login.html", "text/html; charset=utf-8"),
    "/login.js": ("login.js", "text/javascript; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
    "/favicon.svg": ("favicon.svg", "image/svg+xml"),
}
PRIVATE_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
}

CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
       "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")

# Failed logins are serialised and delayed, which caps brute-forcing at ~1 guess/second overall
# without letting an attacker lock the real user out (Docker hides client IPs behind its proxy).
_fail_lock = threading.Lock()

# ------------------------------------------------------------------ sessions

def make_token():
    payload = f"{USER}|{int(time.time()) + SESSION_TTL}"
    sig = hmac.new(SECRET, payload.encode(), hashlib.sha256).hexdigest()
    return f"{payload}.{sig}"


def valid_token(token):
    try:
        payload, sig = token.rsplit(".", 1)
        expected = hmac.new(SECRET, payload.encode(), hashlib.sha256).hexdigest()
        user, exp = payload.split("|")
        return hmac.compare_digest(sig, expected) and user == USER and int(exp) > time.time()
    except (ValueError, AttributeError):
        return False

# ------------------------------------------------------------------ prometheus

def prom_get(path, params=None):
    url = f"{PROM}{path}" + (f"?{urlencode(params)}" if params else "")
    with urlopen(url, timeout=8) as resp:
        body = json.load(resp)
    if body.get("status") != "success":
        raise RuntimeError(body.get("error", "query failed"))
    return body["data"]


def num(v):
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return v if math.isfinite(v) else None


def vector(expr):
    data = prom_get("/api/v1/query", {"query": expr})
    return [(s["metric"], num(s["value"][1])) for s in data["result"]]


def scalar(expr):
    rows = vector(expr)
    return rows[0][1] if rows else None


def by_label(expr, label):
    return {m.get(label, ""): v for m, v in vector(expr)}


INSTANCE_RE = re.compile(r"^[A-Za-z0-9_.:\-\[\]]{1,128}$")
VIRTUAL_NICS = 'device!~"lo|veth.*|docker.*|br-.*|cali.*|flannel.*"'
REAL_FS = 'fstype!~"tmpfs|overlay|squashfs|devtmpfs|ramfs|fuse.*|nsfs|proc|sysfs|cgroup.*"'


def node_instances():
    return sorted({m.get("instance", "") for m, _ in vector('up{job="node"}')} - {""})


def node_selector(instance):
    if not instance:
        found = node_instances()
        instance = found[0] if found else ""
    if instance and not INSTANCE_RE.match(instance):
        raise ValueError("bad instance")
    return f'job="node",instance="{instance}"' if instance else 'job="node"'

# ------------------------------------------------------------------ api handlers

def api_instances(_q):
    return {"instances": node_instances()}


def api_overview(q):
    n = node_selector(q.get("instance"))
    info = (vector(f"node_uname_info{{{n}}}") or [({}, None)])[0][0]
    osinfo = (vector(f"node_os_info{{{n}}}") or [({}, None)])[0][0]
    cpuinfo = (vector(f"node_cpu_info{{{n}}}") or [({}, None)])[0][0]
    mem_total = scalar(f"node_memory_MemTotal_bytes{{{n}}}")
    mem_avail = scalar(f"node_memory_MemAvailable_bytes{{{n}}}")
    swap_total = scalar(f"node_memory_SwapTotal_bytes{{{n}}}")
    swap_free = scalar(f"node_memory_SwapFree_bytes{{{n}}}")
    disks = disk_rows(n)
    root = next((d for d in disks if d["mount"] == "/"), disks[0] if disks else None)
    alerts = prom_get("/api/v1/alerts")["alerts"]
    ssl_days = scalar("min((probe_ssl_earliest_cert_expiry > 0) - time()) / 86400")
    return {
        "host": {
            "name": info.get("nodename", ""),
            "os": osinfo.get("pretty_name", ""),
            "kernel": info.get("release", ""),
            "cpu_model": cpuinfo.get("model_name", ""),
            "cores": scalar(f"count(count by (cpu) (node_cpu_seconds_total{{{n}}}))"),
        },
        "cpu": scalar(f'100 - avg(rate(node_cpu_seconds_total{{{n},mode="idle"}}[2m])) * 100'),
        "mem": {"total": mem_total, "used": None if mem_total is None or mem_avail is None else mem_total - mem_avail},
        "swap": {"total": swap_total, "used": None if swap_total is None or swap_free is None else swap_total - swap_free},
        "disk": root,
        "uptime": scalar(f"time() - node_boot_time_seconds{{{n}}}"),
        "load": [scalar(f"node_load{p}{{{n}}}") for p in (1, 5, 15)],
        "net": {
            "rx": scalar(f"sum(rate(node_network_receive_bytes_total{{{n},{VIRTUAL_NICS}}}[2m]))"),
            "tx": scalar(f"sum(rate(node_network_transmit_bytes_total{{{n},{VIRTUAL_NICS}}}[2m]))"),
        },
        "containers": scalar('count(count by (name) (container_memory_working_set_bytes{name!=""}))') or 0,
        "targets": {"up": scalar("sum(up)") or 0, "total": scalar("count(up)") or 0},
        "checks": {
            "up": scalar('sum(probe_success{job=~"blackbox.*"})') or 0,
            "total": scalar('count(probe_success{job=~"blackbox.*"})') or 0,
            "min_ssl_days": ssl_days,
        },
        "alerts": {
            "firing": sum(1 for a in alerts if a["state"] == "firing"),
            "pending": sum(1 for a in alerts if a["state"] == "pending"),
        },
    }


def disk_rows(n):
    size = {(m["mountpoint"], m.get("device", ""), m.get("fstype", "")): v
            for m, v in vector(f"node_filesystem_size_bytes{{{n},{REAL_FS}}}") if v}
    avail = {m["mountpoint"]: v for m, v in vector(f"node_filesystem_avail_bytes{{{n},{REAL_FS}}}")}
    rows, seen = [], set()
    for (mount, device, fstype), total in sorted(size.items()):
        if mount in seen or mount not in avail:
            continue
        seen.add(mount)
        used = total - avail[mount]
        rows.append({"mount": mount, "device": device, "fstype": fstype, "total": total, "used": used,
                     "pct": used / total * 100})
    return rows


def api_disks(q):
    return {"rows": disk_rows(node_selector(q.get("instance")))}


def api_network(q):
    n = node_selector(q.get("instance"))
    rx = by_label(f"rate(node_network_receive_bytes_total{{{n},{VIRTUAL_NICS}}}[2m])", "device")
    tx = by_label(f"rate(node_network_transmit_bytes_total{{{n},{VIRTUAL_NICS}}}[2m])", "device")
    rx_total = by_label(f"node_network_receive_bytes_total{{{n},{VIRTUAL_NICS}}}", "device")
    tx_total = by_label(f"node_network_transmit_bytes_total{{{n},{VIRTUAL_NICS}}}", "device")
    up = by_label(f'node_network_up{{{n},{VIRTUAL_NICS}}}', "device")
    return {"rows": [{"device": d, "up": up.get(d) == 1, "rx": rx.get(d), "tx": tx.get(d),
                      "rx_total": rx_total.get(d), "tx_total": tx_total.get(d)} for d in sorted(rx)]}


def api_containers(_q):
    cpu = by_label('sum by (name) (rate(container_cpu_usage_seconds_total{name!=""}[2m])) * 100', "name")
    mem = by_label('sum by (name) (container_memory_working_set_bytes{name!=""})', "name")
    started = by_label('max by (name) (container_start_time_seconds{name!=""})', "name")
    now = time.time()
    return {"rows": [{"name": name, "cpu": cpu.get(name), "mem": mem[name],
                      "uptime": (now - started[name]) if started.get(name) else None}
                     for name in sorted(mem)]}


def api_websites(_q):
    def per(expr):
        return {(m.get("job", ""), m.get("instance", "")): v for m, v in vector(expr)}
    ok = per('probe_success{job=~"blackbox.*"}')
    dur = per('probe_duration_seconds{job=~"blackbox.*"}')
    code = per('probe_http_status_code{job=~"blackbox.*"}')
    ssl = per('(probe_ssl_earliest_cert_expiry{job=~"blackbox.*"} > 0) - time()')
    return {"rows": [{"job": j.replace("blackbox-", ""), "target": i, "up": ok[(j, i)] == 1,
                      "duration": dur.get((j, i)), "http": code.get((j, i)),
                      "ssl_days": None if ssl.get((j, i)) is None else ssl[(j, i)] / 86400}
                     for j, i in sorted(ok)]}


def api_targets(_q):
    rows = []
    for t in prom_get("/api/v1/targets", {"state": "active"})["activeTargets"]:
        rows.append({"job": t["labels"].get("job", ""), "instance": t["labels"].get("instance", ""),
                     "up": t["health"] == "up", "duration": num(t.get("lastScrapeDuration")),
                     "error": t.get("lastError", "")})
    return {"rows": sorted(rows, key=lambda r: (r["job"], r["instance"]))}


def api_alerts(_q):
    rows = []
    for a in prom_get("/api/v1/alerts")["alerts"]:
        labels = a.get("labels", {})
        rows.append({"name": labels.get("alertname", ""), "severity": labels.get("severity", ""),
                     "instance": labels.get("instance", ""),
                     "summary": a.get("annotations", {}).get("summary", ""),
                     "state": a["state"], "since": a.get("activeAt")})
    order = {"firing": 0, "pending": 1}
    return {"rows": sorted(rows, key=lambda r: (order.get(r["state"], 2), r["name"]))}


RANGES = {"1h": 3600, "6h": 6 * 3600, "24h": 24 * 3600, "7d": 7 * 24 * 3600}


def api_history(q):
    n = node_selector(q.get("instance"))
    span = RANGES.get(q.get("range", "1h"), 3600)
    queries = {
        "cpu": [("CPU", f'100 - avg(rate(node_cpu_seconds_total{{{n},mode="idle"}}[2m])) * 100')],
        "mem": [("Memory", f"(1 - node_memory_MemAvailable_bytes{{{n}}} / node_memory_MemTotal_bytes{{{n}}}) * 100")],
        "load": [(f"{p}m", f"node_load{p}{{{n}}}") for p in (1, 5, 15)],
        "net": [("rx", f"sum(rate(node_network_receive_bytes_total{{{n},{VIRTUAL_NICS}}}[2m]))"),
                ("tx", f"sum(rate(node_network_transmit_bytes_total{{{n},{VIRTUAL_NICS}}}[2m]))")],
    }.get(q.get("metric", ""))
    if not queries:
        raise ValueError("unknown metric")
    end = int(time.time())
    series = []
    for name, expr in queries:
        data = prom_get("/api/v1/query_range", {"query": expr, "start": end - span, "end": end,
                                                "step": max(15, span // 120)})
        pts = [[int(t), num(v)] for t, v in data["result"][0]["values"]] if data["result"] else []
        series.append({"name": name, "points": pts})
    return {"series": series}


API = {"/api/instances": api_instances, "/api/overview": api_overview, "/api/disks": api_disks,
       "/api/network": api_network, "/api/containers": api_containers, "/api/websites": api_websites,
       "/api/targets": api_targets, "/api/alerts": api_alerts, "/api/history": api_history}

# ------------------------------------------------------------------ http

class Handler(BaseHTTPRequestHandler):
    server_version = "panel"
    sys_version = ""

    def log_message(self, fmt, *args):  # one line per request on stderr
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # -- helpers
    def _headers(self, status, ctype, length, extra=()):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", CSP)
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()

    def _json(self, status, obj, extra=()):
        body = json.dumps(obj).encode()
        self._headers(status, "application/json", len(body), extra)
        self.wfile.write(body)

    def _file(self, name, ctype):
        body = (STATIC / name).read_bytes()
        self._headers(200, ctype, len(body))
        self.wfile.write(body)

    def _redirect(self, location):
        self._headers(302, "text/plain", 0, [("Location", location)])

    def _authed(self):
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        return COOKIE in cookie and valid_token(cookie[COOKIE].value)

    # -- routes
    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path == "/healthz":
            return self._json(200, {"ok": True})
        if path in PUBLIC_FILES:
            if path == "/login" and self._authed():
                return self._redirect("/")
            return self._file(*PUBLIC_FILES[path])
        if not self._authed():
            if path.startswith("/api/"):
                return self._json(401, {"error": "unauthorized"})
            return self._redirect("/login")
        if path in PRIVATE_FILES:
            return self._file(*PRIVATE_FILES[path])
        if path in API:
            params = {k: v[0] for k, v in parse_qs(url.query).items()}
            try:
                return self._json(200, API[path](params))
            except ValueError as e:
                return self._json(400, {"error": str(e)})
            except Exception as e:  # prometheus unreachable, bad response, ...
                return self._json(502, {"error": f"prometheus: {e}"})
        self._json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/logout":
            return self._json(200, {"ok": True}, [("Set-Cookie", f"{COOKIE}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict")])
        if path != "/login":
            return self._json(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", 0))
            data = json.loads(self.rfile.read(min(length, 4096)) or b"{}")
            user, password = str(data.get("user", "")), str(data.get("password", ""))
        except (ValueError, AttributeError):
            return self._json(400, {"error": "bad request"})
        good = hmac.compare_digest(user.encode(), USER.encode()) & hmac.compare_digest(password.encode(), PASSWORD.encode())
        if not good:
            with _fail_lock:
                time.sleep(1)
            return self._json(401, {"error": "invalid credentials"})
        cookie = f"{COOKIE}={make_token()}; Path=/; Max-Age={SESSION_TTL}; HttpOnly; SameSite=Strict"
        self._json(200, {"ok": True}, [("Set-Cookie", cookie)])


if __name__ == "__main__":
    print(f"panel listening on :{PORT}, prometheus at {PROM}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
__MONITORING_EOF__
  write_file panel/static/index.html 644 <<'__MONITORING_EOF__'
<!doctype html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Server Monitor</title>
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/style.css">
  <script src="/app.js" defer></script>
</head>
<body>
  <div class="wrap">
    <header class="card topbar">
      <div class="brand">
        <div class="logo" id="logo"></div>
        <div>
          <h1 data-i18n="title">Server Monitor</h1>
          <small id="hostline">&nbsp;</small>
        </div>
      </div>
      <div class="actions">
        <button class="btn icon" id="theme" type="button" aria-label="Theme"></button>
        <button class="btn" id="lang" type="button"></button>
        <button class="btn" id="refresh" type="button"></button>
        <a class="btn primary" id="grafana" href="#" target="_blank" rel="noopener"></a>
        <button class="btn danger" id="logout" type="button"></button>
      </div>
    </header>

    <div id="banner"></div>
    <section class="stats" id="stats" aria-live="polite"></section>

    <div class="layout">
      <aside class="card side">
        <h2 data-i18n="monitors">Monitors</h2>
        <nav class="nav" id="nav"></nav>
      </aside>
      <main class="card panel" id="panel"></main>
    </div>
    <div class="foot" id="foot"></div>
  </div>
</body>
</html>
__MONITORING_EOF__
  write_file panel/static/login.html 644 <<'__MONITORING_EOF__'
<!doctype html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Sign in - Server Monitor</title>
  <link rel="icon" href="/favicon.svg" type="image/svg+xml">
  <link rel="stylesheet" href="/style.css">
  <script src="/login.js" defer></script>
</head>
<body>
  <div class="login-page">
    <form class="card login-card" id="form" autocomplete="on">
      <div class="brand">
        <div class="logo">
          <svg class="ico" viewBox="0 0 24 24"><path d="M12 3l8 3v6c0 4.6-3.2 7.9-8 9.8C7.2 19.9 4 16.6 4 12V6l8-3z"/><path d="M8 12h2.5l1.5-3 2 6 1.5-3H17"/></svg>
        </div>
        <div>
          <h1 data-i18n="title">Server Monitor</h1>
          <small data-i18n="signin_sub">Sign in to continue</small>
        </div>
      </div>
      <div class="field">
        <label for="user" data-i18n="user">Username</label>
        <input id="user" name="username" autocomplete="username" required autofocus>
      </div>
      <div class="field">
        <label for="password" data-i18n="password">Password</label>
        <input id="password" name="password" type="password" autocomplete="current-password" required>
      </div>
      <div class="form-error" id="error" role="alert"></div>
      <button class="btn primary" type="submit" id="submit" data-i18n="signin">Sign in</button>
    </form>
  </div>
</body>
</html>
__MONITORING_EOF__
  write_file panel/static/app.js 644 <<'__MONITORING_EOF__'
(() => {
  "use strict";

  // ---------------------------------------------------------------- i18n
  const T = {
    en: {
      title: "Server Monitor", monitors: "Monitors", refresh: "Refresh", grafana: "Grafana", logout: "Logout",
      lang_switch: "فارسی", host: "Host",
      cpu: "CPU", memory: "Memory", disk: "Disk", uptime: "Uptime", load: "Load average",
      net_down: "Network in", net_up: "Network out", containers: "Containers", targets: "Targets up",
      websites: "Checks up", ssl: "SSL expires in", alerts: "Firing alerts", cores: "cores", of: "of", days: "days", running: "running",
      overview: "Overview", containers_nav: "Containers", websites_nav: "Websites", disks: "Disks", network: "Network",
      targets_nav: "Targets", alerts_nav: "Alerts",
      d_overview: "Live resource usage of the selected server. Charts update automatically.",
      d_containers: "Docker containers running on this server, with their current CPU and memory use.",
      d_websites: "Uptime, response time and SSL certificate checks. Edit prometheus/targets/http.yml to add sites.",
      d_disks: "Mounted filesystems and how full they are.",
      d_network: "Traffic on the physical network interfaces (virtual and Docker interfaces are hidden).",
      d_targets: "Everything Prometheus scrapes. A target that is down means its metrics are missing.",
      d_alerts: "Alerts that are firing or about to fire. Rules live in prometheus/rules/alerts.yml.",
      server: "Server", range: "Range", r1h: "Last hour", r6h: "Last 6 hours", r24h: "Last 24 hours", r7d: "Last 7 days",
      c_cpu: "CPU usage", c_mem: "Memory usage", c_net: "Network traffic", c_load: "Load average",
      rx: "in", tx: "out", no_data: "No data yet", empty: "Nothing to show yet.",
      name: "Name", cpu_h: "CPU", mem_h: "Memory", uptime_h: "Uptime", status: "Status", target: "Target", type: "Type",
      response: "Response", http: "HTTP", ssl_h: "SSL days left", mount: "Mount", device: "Device", fs: "Filesystem",
      usage: "Usage", used_total: "Used / Total", iface: "Interface", rate_in: "In", rate_out: "Out", total_in: "Total in", total_out: "Total out",
      job: "Job", instance: "Instance", scrape: "Scrape time", error: "Error", severity: "Severity", alert: "Alert", summary: "Summary", state: "State", since: "Since",
      s_running: "Running", s_up: "Up", s_down: "Down", s_firing: "Firing", s_pending: "Pending",
      no_alerts: "No active alerts. Everything looks healthy.", host_online: "Host online",
      err_api: "Cannot load data", last_update: "Last update", auto: "auto-refresh every 10s", ago: "ago",
      t_dark: "Switch to light theme", t_light: "Switch to dark theme",
    },
    fa: {
      title: "مانیتورینگ سرور", monitors: "مانیتورها", refresh: "بروزرسانی", grafana: "گرافانا", logout: "خروج",
      lang_switch: "English", host: "سرور",
      cpu: "پردازنده", memory: "حافظه (رم)", disk: "دیسک", uptime: "مدت روشن بودن", load: "میانگین بار",
      net_down: "دریافت شبکه", net_up: "ارسال شبکه", containers: "کانتینرها", targets: "تارگت‌های فعال",
      websites: "چک‌های سالم", ssl: "انقضای SSL", alerts: "هشدارهای فعال", cores: "هسته", of: "از", days: "روز", running: "در حال اجرا",
      overview: "نمای کلی", containers_nav: "کانتینرها", websites_nav: "سایت‌ها", disks: "دیسک‌ها", network: "شبکه",
      targets_nav: "تارگت‌ها", alerts_nav: "هشدارها",
      d_overview: "مصرف زنده‌ی منابع سرور انتخاب‌شده. نمودارها خودکار بروز می‌شوند.",
      d_containers: "کانتینرهای داکر در حال اجرا روی این سرور، با مصرف فعلی پردازنده و رم.",
      d_websites: "چک آپتایم، زمان پاسخ و گواهی SSL. برای افزودن سایت، فایل prometheus/targets/http.yml را ویرایش کنید.",
      d_disks: "فایل‌سیستم‌های مونت‌شده و میزان پر بودن هرکدام.",
      d_network: "ترافیک کارت‌شبکه‌های واقعی (کارت‌های مجازی و داکر پنهان هستند).",
      d_targets: "همه‌ی چیزهایی که Prometheus از آن‌ها متریک می‌گیرد. تارگت قطع یعنی متریکش را نداریم.",
      d_alerts: "هشدارهایی که فعال هستند یا در شرف فعال شدن‌اند. قوانین در prometheus/rules/alerts.yml هستند.",
      server: "سرور", range: "بازه", r1h: "یک ساعت اخیر", r6h: "۶ ساعت اخیر", r24h: "۲۴ ساعت اخیر", r7d: "۷ روز اخیر",
      c_cpu: "مصرف پردازنده", c_mem: "مصرف حافظه", c_net: "ترافیک شبکه", c_load: "میانگین بار",
      rx: "دریافت", tx: "ارسال", no_data: "هنوز داده‌ای نیست", empty: "هنوز چیزی برای نمایش نیست.",
      name: "نام", cpu_h: "پردازنده", mem_h: "حافظه", uptime_h: "مدت اجرا", status: "وضعیت", target: "مقصد", type: "نوع",
      response: "پاسخ", http: "HTTP", ssl_h: "روز تا انقضای SSL", mount: "مسیر", device: "دستگاه", fs: "فایل‌سیستم",
      usage: "مصرف", used_total: "مصرف / کل", iface: "کارت شبکه", rate_in: "دریافت", rate_out: "ارسال", total_in: "کل دریافت", total_out: "کل ارسال",
      job: "گروه", instance: "نمونه", scrape: "زمان جمع‌آوری", error: "خطا", severity: "شدت", alert: "هشدار", summary: "خلاصه", state: "حالت", since: "از",
      s_running: "در حال اجرا", s_up: "فعال", s_down: "قطع", s_firing: "فعال", s_pending: "در انتظار",
      no_alerts: "هشدار فعالی وجود ندارد. همه چیز سالم است.", host_online: "سرور آنلاین است",
      err_api: "داده‌ها بارگذاری نشد", last_update: "آخرین بروزرسانی", auto: "بروزرسانی خودکار هر ۱۰ ثانیه", ago: "پیش",
      t_dark: "تم روشن", t_light: "تم تیره",
    },
  };

  // ---------------------------------------------------------------- state
  const store = {
    get(k, d) { try { return localStorage.getItem(k) || d; } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* storage blocked */ } },
  };
  const state = {
    lang: T[store.get("lang", "en")] ? store.get("lang", "en") : "en",
    theme: store.get("theme", "dark"),
    range: store.get("range", "1h"),
    instance: store.get("instance", ""),
    instances: [],
    view: "overview",
    overview: null,
    renderId: 0,
  };
  const t = (k) => T[state.lang][k] ?? k;

  // ---------------------------------------------------------------- helpers
  const $ = (id) => document.getElementById(id);
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  const nf = (n, d = 1) => (n == null ? "–" : Number(n).toLocaleString("en-US", { maximumFractionDigits: d, minimumFractionDigits: 0 }));
  const num = (html) => `<span class="num">${html}</span>`;

  function fmtBytes(n) {
    if (n == null) return "–";
    const u = ["B", "KB", "MB", "GB", "TB", "PB"];
    let i = 0;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return `${nf(n, n >= 100 || i === 0 ? 0 : 1)} ${u[i]}`;
  }
  const fmtRate = (n) => (n == null ? "–" : `${fmtBytes(n)}/s`);
  function fmtDur(s) {
    if (s == null) return "–";
    s = Math.floor(s);
    const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60);
    if (d) return `${d}d ${h}h`;
    if (h) return `${h}h ${m}m`;
    return `${m}m ${s % 60}s`;
  }
  const fmtMs = (s) => (s == null ? "–" : s < 1 ? `${nf(s * 1000, 0)} ms` : `${nf(s, 2)} s`);
  const level = (pct) => (pct >= 90 ? "bad" : pct >= 75 ? "warn" : "");
  function ago(unixOrIso) {
    const ts = typeof unixOrIso === "number" ? unixOrIso : Date.parse(unixOrIso) / 1000;
    if (!ts) return "–";
    return `${fmtDur(Date.now() / 1000 - ts)} ${t("ago")}`;
  }

  const P = {
    logo: '<path d="M12 3l8 3v6c0 4.6-3.2 7.9-8 9.8C7.2 19.9 4 16.6 4 12V6l8-3z"/><path d="M8 12h2.5l1.5-3 2 6 1.5-3H17"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
    moon: '<path d="M21 13.5A8.5 8.5 0 1110.5 3a6.5 6.5 0 0010.5 10.5z"/>',
    globe: '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c3 3.3 3 14.7 0 18M12 3c-3 3.3-3 14.7 0 18"/>',
    refresh: '<path d="M20 11a8 8 0 10-2.3 5.7M20 4v7h-7"/>',
    chart: '<path d="M4 4v16h16"/><path d="M8 15l3-4 3 2 5-6"/>',
    logout: '<path d="M9 4H5a1 1 0 00-1 1v14a1 1 0 001 1h4M16 8l4 4-4 4M20 12H9"/>',
    cpu: '<rect x="5" y="5" width="14" height="14" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/>',
    memory: '<rect x="2" y="7" width="20" height="10" rx="2"/><path d="M6 11v2M10 11v2M14 11v2M18 11v2M6 17v2M10 17v2M14 17v2M18 17v2"/>',
    disk: '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    activity: '<path d="M3 12h4l3-8 4 16 3-8h4"/>',
    down: '<path d="M12 4v12M6 11l6 6 6-6M5 21h14"/>',
    up: '<path d="M12 20V8M6 13l6-6 6 6M5 3h14"/>',
    box: '<path d="M21 8l-9-5-9 5v8l9 5 9-5V8z"/><path d="M3 8l9 5 9-5M12 13v8"/>',
    check: '<circle cx="12" cy="12" r="9"/><path d="M8 12.5l2.7 2.7L16 9.5"/>',
    lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 018 0v3"/>',
    bell: '<path d="M18 16v-5a6 6 0 10-12 0v5l-2 2h16l-2-2zM10 21h4"/>',
    server: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
    network: '<circle cx="12" cy="5" r="2.2"/><circle cx="5" cy="19" r="2.2"/><circle cx="19" cy="19" r="2.2"/><path d="M12 7.2v4M12 11.2L5.5 16.8M12 11.2l6.5 5.6"/>',
    grid: '<rect x="3" y="3" width="8" height="8" rx="2"/><rect x="13" y="3" width="8" height="5" rx="2"/><rect x="13" y="10" width="8" height="11" rx="2"/><rect x="3" y="13" width="8" height="8" rx="2"/>',
    ext: '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 01-1 1H5a1 1 0 01-1-1V7a1 1 0 011-1h5"/>',
    okmark: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
  };
  const icon = (name) => `<svg class="ico" viewBox="0 0 24 24" aria-hidden="true">${P[name]}</svg>`;

  async function api(path, params = {}) {
    const qs = new URLSearchParams(params).toString();
    const r = await fetch(path + (qs ? `?${qs}` : ""), { credentials: "same-origin", cache: "no-store" });
    if (r.status === 401) { location.replace("/login"); throw new Error("unauthorized"); }
    const body = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(body.error || `HTTP ${r.status}`);
    return body;
  }
  const withInstance = (extra = {}) => (state.instance ? { instance: state.instance, ...extra } : extra);

  // ---------------------------------------------------------------- chrome (header, nav)
  const VIEWS = [
    { id: "overview", icon: "grid", label: "overview", desc: "d_overview" },
    { id: "containers", icon: "box", label: "containers_nav", desc: "d_containers" },
    { id: "websites", icon: "globe", label: "websites_nav", desc: "d_websites" },
    { id: "disks", icon: "disk", label: "disks", desc: "d_disks" },
    { id: "network", icon: "network", label: "network", desc: "d_network" },
    { id: "targets", icon: "check", label: "targets_nav", desc: "d_targets" },
    { id: "alerts", icon: "bell", label: "alerts_nav", desc: "d_alerts" },
  ];

  function applyLocale() {
    document.documentElement.lang = state.lang;
    document.documentElement.dir = state.lang === "fa" ? "rtl" : "ltr";
    document.documentElement.dataset.theme = state.theme;
    document.title = t("title");
    document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
    $("logo").innerHTML = icon("logo");
    $("theme").innerHTML = icon(state.theme === "dark" ? "sun" : "moon");
    $("theme").setAttribute("aria-label", state.theme === "dark" ? t("t_dark") : t("t_light"));
    $("theme").title = $("theme").getAttribute("aria-label");
    $("lang").innerHTML = `${icon("globe")}<span class="txt">${esc(t("lang_switch"))}</span>`;
    $("refresh").innerHTML = `${icon("refresh")}<span class="txt">${esc(t("refresh"))}</span>`;
    $("grafana").innerHTML = `${icon("chart")}<span class="txt">${esc(t("grafana"))}</span>`;
    $("grafana").href = `${location.protocol}//${location.hostname}:3000/d/server-overview`;
    $("logout").innerHTML = `${icon("logout")}<span class="txt">${esc(t("logout"))}</span>`;
    renderNav();
  }

  function badgeFor(id) {
    const o = state.overview;
    if (!o) return "";
    if (id === "containers") return `<span class="badge">${o.containers}</span>`;
    if (id === "websites") return o.checks.total ? `<span class="badge${o.checks.up < o.checks.total ? " bad" : ""}">${o.checks.up}/${o.checks.total}</span>` : "";
    if (id === "targets") return `<span class="badge${o.targets.up < o.targets.total ? " bad" : ""}">${o.targets.up}/${o.targets.total}</span>`;
    if (id === "alerts") return o.alerts.firing ? `<span class="badge bad">${o.alerts.firing}</span>` : "";
    return "";
  }
  function renderNav() {
    $("nav").innerHTML = VIEWS.map((v) =>
      `<a href="#${v.id}" class="${v.id === state.view ? "active" : ""}" ${v.id === state.view ? 'aria-current="page"' : ""}>${icon(v.icon)}<span class="name">${esc(t(v.label))}</span>${badgeFor(v.id)}</a>`).join("");
  }

  // ---------------------------------------------------------------- stat cards
  function card({ label, ic, value, sub = "", pct = null, big = false, cls = "", tight = false }) {
    const bar = pct == null ? "" : `<div class="bar ${level(pct)}"><i style="width:${Math.min(100, Math.max(0, pct))}%"></i></div>`;
    return `<div class="card stat ${big ? "big" : ""} ${cls}"><div class="label">${icon(ic)}${esc(label)}</div><div class="value${tight ? " tight" : ""}">${value}</div>${bar}${sub ? `<div class="sub">${sub}</div>` : ""}</div>`;
  }

  function renderStats() {
    const o = state.overview;
    if (!o) return;
    const memPct = o.mem.total ? (o.mem.used / o.mem.total) * 100 : null;
    const d = o.disk;
    const cpuSub = [o.host.cores != null ? `${num(nf(o.host.cores, 0))} ${esc(t("cores"))}` : "", o.host.cpu_model ? num(esc(o.host.cpu_model)) : ""].filter(Boolean).join("<br>");
    $("stats").innerHTML = [
      card({ big: true, label: t("cpu"), ic: "cpu", value: num(`${nf(o.cpu)}%`), pct: o.cpu, sub: cpuSub }),
      card({ big: true, label: t("memory"), ic: "memory", value: num(`${nf(memPct, 0)}%`), pct: memPct,
        sub: `${num(fmtBytes(o.mem.used))} ${esc(t("of"))} ${num(fmtBytes(o.mem.total))}` }),
      card({ big: true, label: t("disk"), ic: "disk", value: d ? num(`${nf(d.pct, 0)}%`) : "–", pct: d ? d.pct : null,
        sub: d ? `${num(esc(d.mount))} · ${num(fmtBytes(d.used))} ${esc(t("of"))} ${num(fmtBytes(d.total))}` : "" }),
      card({ big: true, label: t("uptime"), ic: "clock", value: num(fmtDur(o.uptime)), sub: [o.host.name, o.host.os, o.host.kernel].filter(Boolean).map((x) => num(esc(x))).join("<br>") }),
      card({ label: t("load"), ic: "activity", tight: true, value: num(o.load.map((x) => nf(x, 2)).join(" / ")) }),
      card({ label: t("net_down"), ic: "down", value: num(fmtRate(o.net.rx)) }),
      card({ label: t("net_up"), ic: "up", value: num(fmtRate(o.net.tx)) }),
      card({ label: t("containers"), ic: "box", value: num(o.containers), sub: esc(t("running")) }),
      card({ label: t("targets"), ic: "check", value: num(`${o.targets.up} / ${o.targets.total}`) }),
      card({ label: t("websites"), ic: "globe", value: num(`${o.checks.up} / ${o.checks.total}`) }),
      card({ label: t("ssl"), ic: "lock", value: o.checks.min_ssl_days == null ? "–" : num(`${nf(o.checks.min_ssl_days, 0)} <small>${t("days")}</small>`) }),
      card({ label: t("alerts"), ic: "bell", cls: o.alerts.firing ? "alert-on" : "", value: o.alerts.firing ? num(o.alerts.firing) : `<span class="ok-mark">${icon("okmark")}</span>` }),
    ].join("");
    $("hostline").textContent = [o.host.name, o.host.os].filter(Boolean).join(" · ") || " ";
    renderNav();
  }

  // ---------------------------------------------------------------- tables
  function table(cols, rows) {
    if (!rows.length) return `<div class="table-wrap"><div class="empty">${esc(t("empty"))}</div></div>`;
    const head = cols.map((c) => `<th>${esc(t(c.h))}</th>`).join("");
    const body = rows.map((r) => `<tr>${cols.map((c) => `<td class="${c.cls || ""}">${c.cell(r)}</td>`).join("")}</tr>`).join("");
    return `<div class="table-wrap"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
  }
  const pill = (kind, text, dot = true) => `<span class="pill ${kind}${dot ? " dot" : ""}">${esc(text)}</span>`;
  const miniBar = (pct) => `<div class="mini-bar"><div class="bar ${level(pct)}"><i style="width:${Math.min(100, pct)}%"></i></div>${num(`${nf(pct, 0)}%`)}</div>`;

  const BUILDERS = {
    async containers() {
      const { rows } = await api("/api/containers");
      return table([
        { h: "name", cls: "strong", cell: (r) => esc(r.name) },
        { h: "cpu_h", cell: (r) => num(r.cpu == null ? "–" : `${nf(r.cpu)}%`) },
        { h: "mem_h", cell: (r) => num(fmtBytes(r.mem)) },
        { h: "uptime_h", cell: (r) => num(fmtDur(r.uptime)) },
        { h: "status", cell: () => pill("ok", t("s_running")) },
      ], rows);
    },
    async websites() {
      const { rows } = await api("/api/websites");
      return table([
        { h: "target", cls: "strong", cell: (r) => num(esc(r.target)) },
        { h: "type", cell: (r) => pill("info", r.job.toUpperCase(), false) },
        { h: "status", cell: (r) => (r.up ? pill("ok", t("s_up")) : pill("bad", t("s_down"))) },
        { h: "response", cell: (r) => num(fmtMs(r.duration)) },
        { h: "http", cell: (r) => num(r.http || "–") },
        { h: "ssl_h", cell: (r) => (r.ssl_days == null ? "–" : pill(r.ssl_days < 7 ? "bad" : r.ssl_days < 14 ? "warn" : "ok", nf(r.ssl_days, 0), false)) },
      ], rows);
    },
    async disks() {
      const { rows } = await api("/api/disks", withInstance());
      return table([
        { h: "mount", cls: "strong", cell: (r) => num(esc(r.mount)) },
        { h: "device", cls: "muted", cell: (r) => num(esc(r.device)) },
        { h: "fs", cell: (r) => esc(r.fstype) },
        { h: "usage", cell: (r) => miniBar(r.pct) },
        { h: "used_total", cell: (r) => num(`${fmtBytes(r.used)} / ${fmtBytes(r.total)}`) },
      ], rows);
    },
    async network() {
      const { rows } = await api("/api/network", withInstance());
      return table([
        { h: "iface", cls: "strong", cell: (r) => num(esc(r.device)) },
        { h: "status", cell: (r) => (r.up ? pill("ok", t("s_up")) : pill("bad", t("s_down"))) },
        { h: "rate_in", cell: (r) => num(fmtRate(r.rx)) },
        { h: "rate_out", cell: (r) => num(fmtRate(r.tx)) },
        { h: "total_in", cell: (r) => num(fmtBytes(r.rx_total)) },
        { h: "total_out", cell: (r) => num(fmtBytes(r.tx_total)) },
      ], rows);
    },
    async targets() {
      const { rows } = await api("/api/targets");
      return table([
        { h: "job", cls: "strong", cell: (r) => esc(r.job) },
        { h: "instance", cell: (r) => num(esc(r.instance)) },
        { h: "status", cell: (r) => (r.up ? pill("ok", t("s_up")) : pill("bad", t("s_down"))) },
        { h: "scrape", cell: (r) => num(fmtMs(r.duration)) },
        { h: "error", cls: "wrap-cell", cell: (r) => (r.error ? `<span style="color:var(--red)">${esc(r.error)}</span>` : "") },
      ], rows);
    },
    async alerts() {
      const { rows } = await api("/api/alerts");
      const sev = { critical: "bad", warning: "warn", info: "info" };
      const note = rows.length ? "" : `<div class="notice ok">${icon("okmark")}<span>${esc(t("no_alerts"))}</span></div>`;
      return note + (rows.length ? table([
        { h: "severity", cell: (r) => pill(sev[r.severity] || "", r.severity || "–", false) },
        { h: "alert", cls: "strong", cell: (r) => esc(r.name) },
        { h: "instance", cell: (r) => num(esc(r.instance || "–")) },
        { h: "summary", cls: "wrap-cell", cell: (r) => esc(r.summary) },
        { h: "state", cell: (r) => (r.state === "firing" ? pill("bad", t("s_firing")) : pill("warn", t("s_pending"))) },
        { h: "since", cell: (r) => num(ago(r.since)) },
      ], rows) : "");
    },
  };

  // ---------------------------------------------------------------- charts
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  const CHARTS = [
    { m: "cpu", title: "c_cpu", fmt: (v) => `${nf(v)}%`, max: 100, colors: ["--accent"], now: true },
    { m: "mem", title: "c_mem", fmt: (v) => `${nf(v)}%`, max: 100, colors: ["--blue"], now: true },
    { m: "net", title: "c_net", fmt: fmtRate, colors: ["--accent", "--yellow"], names: ["rx", "tx"] },
    { m: "load", title: "c_load", fmt: (v) => nf(v, 2), colors: ["--accent", "--blue", "--yellow"] },
  ];
  const niceMax = (v) => {
    if (!(v > 0)) return 1;
    const p = 10 ** Math.floor(Math.log10(v));
    return [1, 2, 2.5, 5, 10].map((x) => x * p).find((x) => x >= v);
  };

  function drawChart(box, cfg, series, uid) {
    const all = series.flatMap((s) => s.points.filter((p) => p[1] != null));
    if (!all.length) { box.innerHTML = `<div class="empty">${esc(t("no_data"))}</div>`; return; }
    const W = Math.max(260, Math.round(box.clientWidth) || 600), H = 190, L = 50, R = 8, TOP = 10, B = 24;
    const x0 = Math.min(...all.map((p) => p[0])), x1 = Math.max(...all.map((p) => p[0])) || x0 + 1;
    const ymax = cfg.max || niceMax(Math.max(...all.map((p) => p[1])) * 1.1);
    const X = (ts) => L + ((ts - x0) / Math.max(1, x1 - x0)) * (W - L - R);
    const Y = (v) => TOP + (1 - v / ymax) * (H - TOP - B);
    const colors = cfg.colors.map(css);

    let grid = "";
    for (let i = 0; i <= 4; i++) {
      const v = (ymax * i) / 4, y = Y(v);
      grid += `<line x1="${L}" x2="${W - R}" y1="${y}" y2="${y}"/><text x="${L - 8}" y="${y + 4}" text-anchor="end">${esc(cfg.fmt(v).replace(/\.0+(?=\D|$)/, ""))}</text>`;
    }
    const span = x1 - x0;
    for (let i = 0; i <= 4; i++) {
      const ts = x0 + (span * i) / 4, d = new Date(ts * 1000);
      const label = span > 2 * 86400 ? `${d.getMonth() + 1}/${d.getDate()}` : `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
      grid += `<text x="${X(ts)}" y="${H - 6}" text-anchor="${i === 0 ? "start" : i === 4 ? "end" : "middle"}">${label}</text>`;
    }
    let paths = "", defs = "";
    series.forEach((s, i) => {
      let d = "", pen = false, first = null, last = null;
      s.points.forEach(([ts, v]) => {
        if (v == null) { pen = false; return; }
        d += `${pen ? "L" : "M"}${X(ts).toFixed(1)},${Y(v).toFixed(1)}`;
        if (first == null) first = ts;
        last = ts;
        pen = true;
      });
      if (!d) return;
      if (i === 0 || series.length <= 2) {
        defs += `<linearGradient id="g${uid}${i}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${colors[i]}" stop-opacity=".22"/><stop offset="1" stop-color="${colors[i]}" stop-opacity="0"/></linearGradient>`;
        paths += `<path d="${d}L${X(last).toFixed(1)},${Y(0)}L${X(first).toFixed(1)},${Y(0)}Z" fill="url(#g${uid}${i})" stroke="none"/>`;
      }
      paths += `<path d="${d}" fill="none" stroke="${colors[i]}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>`;
    });
    box.innerHTML = `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img"><defs>${defs}</defs><g class="grid">${grid}</g>${paths}<line class="cross" y1="${TOP}" y2="${H - B}" stroke="${css("--muted")}" stroke-dasharray="3 3" opacity="0"/><rect class="hit" x="${L}" y="0" width="${W - L - R}" height="${H}" fill="transparent"/></svg><div class="tip" hidden></div>`;

    const svg = box.querySelector("svg"), tip = box.querySelector(".tip"), cross = box.querySelector(".cross");
    const ref = series.reduce((a, b) => (b.points.length > a.points.length ? b : a), series[0]).points;
    svg.addEventListener("mousemove", (e) => {
      const rect = svg.getBoundingClientRect();
      const ts = x0 + (((e.clientX - rect.left) / rect.width) * W - L) / (W - L - R) * (x1 - x0);
      let best = 0;
      ref.forEach((p, i) => { if (Math.abs(p[0] - ts) < Math.abs(ref[best][0] - ts)) best = i; });
      const at = ref[best][0], cx = X(at);
      cross.setAttribute("x1", cx); cross.setAttribute("x2", cx); cross.setAttribute("opacity", "1");
      const rows = series.map((s, i) => {
        const p = s.points.find((q) => q[0] === at);
        return `<div><span style="color:${colors[i]}">●</span> ${esc(cfg.names ? t(cfg.names[i]) : s.name)}: <b>${esc(p && p[1] != null ? cfg.fmt(p[1]) : "–")}</b></div>`;
      }).join("");
      const dt = new Date(at * 1000);
      tip.innerHTML = `<div class="muted">${esc(dt.toLocaleString())}</div>${rows}`;
      tip.hidden = false;
      tip.style.left = `${Math.min(Math.max((cx / W) * rect.width, 70), rect.width - 70)}px`;
      tip.style.top = "6px";
      tip.style.transform = "translate(-50%, 0)";
    });
    svg.addEventListener("mouseleave", () => { tip.hidden = true; cross.setAttribute("opacity", "0"); });
  }

  async function buildOverview(root, id, rebuild) {
    const o = state.overview;
    const hostNote = o ? `<div class="notice ok">${icon("okmark")}<span><b>${esc(t("host_online"))}</b> — ${num(esc([o.host.name, o.host.os, o.host.kernel].filter(Boolean).join(" · ")))}</span></div>` : "";
    if (rebuild) root.querySelector("#body").innerHTML = hostNote + `<div class="charts">${CHARTS.map((c, i) =>
      `<div class="chart"><header><h3>${esc(t(c.title))}</h3><span class="now" id="now-${i}"></span></header><div class="plot" id="plot-${i}"><div class="skeleton"></div></div>${c.names || c.colors.length > 1 ? `<div class="legend">${(c.names ? c.names.map(t) : ["1m", "5m", "15m"]).map((n, k) => `<span><i style="background:var(${c.colors[k]})"></i>${esc(n)}</span>`).join("")}</div>` : ""}</div>`).join("")}</div>`;
    await Promise.all(CHARTS.map(async (c, i) => {
      try {
        const { series } = await api("/api/history", withInstance({ metric: c.m, range: state.range }));
        if (id !== state.renderId) return;
        drawChart(root.querySelector(`#plot-${i}`), c, series, i);
        if (c.now) {
          const last = [...series[0].points].reverse().find((p) => p[1] != null);
          root.querySelector(`#now-${i}`).innerHTML = last ? num(esc(c.fmt(last[1]))) : "";
        }
      } catch (e) {
        if (id === state.renderId) root.querySelector(`#plot-${i}`).innerHTML = `<div class="empty">${esc(e.message)}</div>`;
      }
    }));
  }

  // ---------------------------------------------------------------- view rendering
  function tools() {
    if (state.view !== "overview") return "";
    const inst = state.instances.length > 1
      ? `<label class="muted" for="sel-inst">${esc(t("server"))}</label><select id="sel-inst">${state.instances.map((i) => `<option ${i === state.instance ? "selected" : ""} value="${esc(i)}">${esc(i)}</option>`).join("")}</select>` : "";
    const range = `<label class="muted" for="sel-range">${esc(t("range"))}</label><select id="sel-range">${["1h", "6h", "24h", "7d"].map((r) => `<option ${r === state.range ? "selected" : ""} value="${r}">${esc(t("r" + r))}</option>`).join("")}</select>`;
    return inst + range;
  }

  async function renderView(first) {
    const id = ++state.renderId;
    const v = VIEWS.find((x) => x.id === state.view) || VIEWS[0];
    const root = $("panel");
    const hadShell = root.dataset.view === v.id && root.dataset.lang === state.lang;
    if (!hadShell || first) {
      root.dataset.view = v.id;
      root.dataset.lang = state.lang;
      root.innerHTML = `<div class="panel-head"><h2>${icon(v.icon)}${esc(t(v.label))}</h2><div class="tools" id="tools">${tools()}</div></div><p class="desc">${esc(t(v.desc))}</p><hr><div id="body"><div class="skeleton"></div></div>`;
      const si = $("sel-inst"), sr = $("sel-range");
      if (si) si.onchange = () => { state.instance = si.value; store.set("instance", si.value); tick(true); };
      if (sr) sr.onchange = () => { state.range = sr.value; store.set("range", sr.value); renderView(true); };
    }
    try {
      if (v.id === "overview") { await buildOverview(root, id, !hadShell || first); }
      else {
        const html = await BUILDERS[v.id]();
        if (id !== state.renderId) return;
        root.querySelector("#body").innerHTML = html;
      }
    } catch (e) {
      if (id === state.renderId && e.message !== "unauthorized") root.querySelector("#body").innerHTML = `<div class="notice bad">${esc(t("err_api"))}: ${esc(e.message)}</div>`;
    }
  }

  async function loadStats() {
    try {
      if (!state.instances.length) {
        state.instances = (await api("/api/instances")).instances;
        if (!state.instances.includes(state.instance)) state.instance = state.instances[0] || "";
      }
      state.overview = await api("/api/overview", withInstance());
      $("banner").innerHTML = "";
      renderStats();
    } catch (e) {
      if (e.message !== "unauthorized") $("banner").innerHTML = `<div class="notice bad">${esc(t("err_api"))}: ${esc(e.message)}</div>`;
    }
    const now = new Date();
    $("foot").textContent = `${t("last_update")}: ${now.toLocaleTimeString([], { hour12: false })} · ${t("auto")}`;
  }

  let ticking = false;
  async function tick(full) {
    if (ticking) return;
    ticking = true;
    try {
      await loadStats();
      await renderView(full === true);
    } finally { ticking = false; }
  }

  function route() {
    const id = location.hash.slice(1);
    state.view = VIEWS.some((v) => v.id === id) ? id : "overview";
    renderNav();
    renderView(true);
  }

  // ---------------------------------------------------------------- boot
  $("theme").onclick = () => { state.theme = state.theme === "dark" ? "light" : "dark"; store.set("theme", state.theme); applyLocale(); renderStats(); renderView(true); };
  $("lang").onclick = () => { state.lang = state.lang === "en" ? "fa" : "en"; store.set("lang", state.lang); applyLocale(); renderStats(); renderView(true); };
  $("refresh").onclick = () => tick(true);
  $("logout").onclick = async () => { try { await fetch("/logout", { method: "POST" }); } catch (e) { /* ignore */ } location.replace("/login"); };
  window.addEventListener("hashchange", route);
  let resizeTimer;
  window.addEventListener("resize", () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(() => { if (state.view === "overview") renderView(false); }, 300); });

  applyLocale();
  state.view = VIEWS.some((v) => v.id === location.hash.slice(1)) ? location.hash.slice(1) : "overview";
  renderNav();
  tick(true);
  setInterval(() => { if (!document.hidden) tick(false); }, 10000);
})();
__MONITORING_EOF__
  write_file panel/static/login.js 644 <<'__MONITORING_EOF__'
(() => {
  const T = {
    en: { title: "Server Monitor", signin_sub: "Sign in to continue", user: "Username", password: "Password", signin: "Sign in", bad: "Wrong username or password", net: "Could not reach the server" },
    fa: { title: "مانیتورینگ سرور", signin_sub: "برای ادامه وارد شوید", user: "نام کاربری", password: "رمز عبور", signin: "ورود", bad: "نام کاربری یا رمز عبور اشتباه است", net: "ارتباط با سرور برقرار نشد" },
  };
  let lang = "en", theme = "dark";
  try { lang = localStorage.getItem("lang") || lang; theme = localStorage.getItem("theme") || theme; } catch (e) { /* storage blocked */ }
  if (!T[lang]) lang = "en";
  document.documentElement.dataset.theme = theme;
  document.documentElement.lang = lang;
  document.documentElement.dir = lang === "fa" ? "rtl" : "ltr";
  document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = T[lang][el.dataset.i18n]; });
  document.title = T[lang].signin + " - " + T[lang].title;

  const form = document.getElementById("form"), err = document.getElementById("error"), btn = document.getElementById("submit");
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    err.textContent = "";
    btn.disabled = true;
    try {
      const r = await fetch("/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ user: form.user.value, password: form.password.value }),
      });
      if (r.ok) { location.replace("/"); return; }
      err.textContent = T[lang].bad;
    } catch (x) {
      err.textContent = T[lang].net;
    }
    btn.disabled = false;
    form.password.select();
  });
})();
__MONITORING_EOF__
  write_file panel/static/style.css 644 <<'__MONITORING_EOF__'
:root {
  --bg: #0a0f16;
  --card: #0e1520;
  --card-2: #121b28;
  --border: #1a2433;
  --border-2: #243246;
  --text: #e8eef5;
  --muted: #8494a8;
  --accent: #2ee6a6;
  --accent-ink: #04281d;
  --accent-soft: rgba(46, 230, 166, .12);
  --blue: #6ea8fe;
  --blue-soft: rgba(110, 168, 254, .14);
  --yellow: #f5b83d;
  --yellow-soft: rgba(245, 184, 61, .12);
  --red: #f87171;
  --red-soft: rgba(248, 113, 113, .12);
  --shadow: 0 1px 0 rgba(255, 255, 255, .02) inset;
  --radius: 14px;
}
:root[data-theme="light"] {
  --bg: #f1f5f9;
  --card: #ffffff;
  --card-2: #f6f9fc;
  --border: #dde5ee;
  --border-2: #c9d5e2;
  --text: #0f1b2a;
  --muted: #5b6e84;
  --accent: #0fb57f;
  --accent-ink: #ffffff;
  --accent-soft: rgba(15, 181, 127, .12);
  --blue: #2563eb;
  --blue-soft: rgba(37, 99, 235, .10);
  --yellow: #b7791f;
  --yellow-soft: rgba(183, 121, 31, .12);
  --red: #dc2626;
  --red-soft: rgba(220, 38, 38, .09);
  --shadow: 0 1px 2px rgba(15, 27, 42, .04);
}

* { box-sizing: border-box; }
html, body { margin: 0; }
body {
  background: var(--bg);
  color: var(--text);
  font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Tahoma, "Helvetica Neue", Arial, sans-serif;
  -webkit-font-smoothing: antialiased;
}
button, input, select { font: inherit; color: inherit; }
svg { display: block; flex: none; }
.ico { width: 16px; height: 16px; stroke: currentColor; fill: none; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.num { direction: ltr; unicode-bidi: isolate; display: inline-block; }

.wrap { max-width: 1630px; margin: 0 auto; padding: 22px 24px 40px; display: grid; grid-template-columns: minmax(0, 1fr); gap: 18px; }

.card { background: var(--card); border: 1px solid var(--border); border-radius: var(--radius); box-shadow: var(--shadow); }

/* ---------- header */
.topbar { display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 18px 22px; flex-wrap: wrap; }
.brand { display: flex; align-items: center; gap: 14px; }
.brand .logo { width: 38px; height: 38px; border-radius: 11px; display: grid; place-items: center; background: var(--accent-soft); color: var(--accent); }
.brand .logo .ico { width: 22px; height: 22px; }
.brand h1 { margin: 0; font-size: 19px; letter-spacing: .04em; text-transform: uppercase; font-weight: 750; }
.brand small { color: var(--muted); font-size: 12.5px; }
.actions { display: flex; gap: 10px; flex-wrap: wrap; align-items: center; }

.btn {
  display: inline-flex; align-items: center; gap: 8px; height: 38px; padding: 0 15px; border-radius: 10px;
  background: var(--card-2); border: 1px solid var(--border-2); cursor: pointer; font-weight: 600; font-size: 13.5px;
  text-decoration: none; white-space: nowrap; transition: border-color .15s, background .15s, transform .05s;
}
.btn:hover { border-color: var(--muted); }
.btn:active { transform: translateY(1px); }
.btn.icon { width: 38px; padding: 0; justify-content: center; }
.btn.primary { background: var(--accent); border-color: var(--accent); color: var(--accent-ink); }
.btn.primary:hover { filter: brightness(1.07); }
.btn.danger { color: var(--red); border-color: color-mix(in srgb, var(--red) 45%, transparent); background: transparent; }
.btn.danger:hover { background: var(--red-soft); }
.btn.small { height: 32px; padding: 0 12px; font-size: 12.5px; border-radius: 9px; }
.btn:focus-visible, select:focus-visible, input:focus-visible, .nav a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }

/* ---------- stat cards */
.stats { display: grid; gap: 14px; grid-template-columns: repeat(auto-fill, minmax(214px, 1fr)); }
.stat { padding: 16px 18px 15px; min-height: 92px; }
.stat.big { min-height: 150px; }
.stat .label { display: flex; align-items: center; gap: 8px; color: var(--muted); font-size: 13px; font-weight: 500; }
.stat .value { margin-top: 7px; font-size: 26px; font-weight: 750; letter-spacing: -.01em; line-height: 1.2; }
.stat .value.tight { font-size: 21px; line-height: 31px; white-space: nowrap; }
.stat .value small { font-size: 14px; font-weight: 600; color: var(--muted); }
.stat .sub { margin-top: 9px; color: var(--muted); font-size: 12px; line-height: 1.55; overflow-wrap: anywhere; }
.bar { height: 4px; border-radius: 4px; background: var(--border); margin-top: 11px; overflow: hidden; }
.bar > i { display: block; height: 100%; width: 0; border-radius: 4px; background: var(--accent); transition: width .5s; }
.bar.warn > i { background: var(--yellow); }
.bar.bad > i { background: var(--red); }
.stat.alert-on .value { color: var(--red); }
.stat .ok-mark { color: var(--accent); }

/* ---------- layout: sidebar + main */
.layout { display: grid; grid-template-columns: 252px minmax(0, 1fr); gap: 18px; align-items: start; }
.side { padding: 18px 12px 12px; position: sticky; top: 16px; }
.side h2 { margin: 0 8px 12px; font-size: 11.5px; letter-spacing: .12em; color: var(--muted); font-weight: 650; text-transform: uppercase; }
.nav { display: grid; gap: 4px; }
.nav a {
  display: flex; align-items: center; gap: 12px; height: 44px; padding: 0 12px; border-radius: 10px; text-decoration: none; color: var(--muted);
  font-weight: 550; border: 1px solid transparent; cursor: pointer;
}
.nav a:hover { color: var(--text); background: var(--card-2); }
.nav a.active { color: var(--accent); background: var(--accent-soft); border-color: color-mix(in srgb, var(--accent) 35%, transparent); }
.nav a .name { flex: 1; }
.badge { font-size: 11.5px; font-weight: 700; padding: 2px 8px; border-radius: 8px; background: var(--card-2); color: var(--muted); }
.nav a.active .badge { background: color-mix(in srgb, var(--accent) 22%, transparent); color: var(--accent); }
.badge.bad { background: var(--red-soft); color: var(--red); }

.panel { padding: 24px 26px 26px; min-width: 0; }
.panel-head { display: flex; align-items: center; justify-content: space-between; gap: 14px; flex-wrap: wrap; }
.panel-head h2 { margin: 0; display: flex; align-items: center; gap: 12px; font-size: 21px; font-weight: 750; }
.panel-head h2 .ico { width: 22px; height: 22px; color: var(--accent); }
.tools { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.panel .desc { color: var(--muted); margin: 10px 0 18px; max-width: 820px; }
.panel hr { border: 0; border-top: 1px solid var(--border); margin: 0 0 18px; width: 70%; }

select {
  height: 32px; border-radius: 9px; background: var(--card-2); border: 1px solid var(--border-2); padding: 0 10px; cursor: pointer; font-size: 12.5px; font-weight: 600;
}

.notice {
  display: flex; align-items: center; gap: 12px; padding: 13px 16px; border-radius: 10px; margin-bottom: 16px;
  background: var(--blue-soft); border: 1px solid color-mix(in srgb, var(--blue) 35%, transparent); border-inline-start: 3px solid var(--blue);
}
.notice.bad { background: var(--red-soft); border-color: color-mix(in srgb, var(--red) 40%, transparent); border-inline-start-color: var(--red); }
.notice.ok { background: var(--accent-soft); border-color: color-mix(in srgb, var(--accent) 35%, transparent); border-inline-start-color: var(--accent); }

/* ---------- table */
.table-wrap { overflow-x: auto; border: 1px solid var(--border); border-radius: 12px; }
table { width: 100%; border-collapse: collapse; min-width: 640px; }
th, td { text-align: start; padding: 14px 16px; white-space: nowrap; }
th { font-size: 12.5px; color: var(--muted); font-weight: 600; background: color-mix(in srgb, var(--card-2) 60%, transparent); border-bottom: 1px solid var(--border); }
td { border-bottom: 1px solid var(--border); }
tr:last-child td { border-bottom: 0; }
tbody tr:hover td { background: color-mix(in srgb, var(--card-2) 55%, transparent); }
td.strong { font-weight: 700; }
td.wrap-cell { white-space: normal; min-width: 240px; }
td.muted, .muted { color: var(--muted); }
.empty { padding: 34px 16px; text-align: center; color: var(--muted); }
.mini-bar { display: flex; align-items: center; gap: 10px; min-width: 190px; }
.mini-bar .bar { flex: 1; margin: 0; height: 6px; }

.pill {
  display: inline-flex; align-items: center; gap: 6px; padding: 3px 11px; border-radius: 999px; font-size: 12.5px; font-weight: 600;
  background: var(--card-2); color: var(--muted); border: 1px solid var(--border);
}
.pill.ok { background: var(--accent-soft); color: var(--accent); border-color: color-mix(in srgb, var(--accent) 35%, transparent); }
.pill.info { background: var(--blue-soft); color: var(--blue); border-color: color-mix(in srgb, var(--blue) 35%, transparent); }
.pill.warn { background: var(--yellow-soft); color: var(--yellow); border-color: color-mix(in srgb, var(--yellow) 40%, transparent); }
.pill.bad { background: var(--red-soft); color: var(--red); border-color: color-mix(in srgb, var(--red) 40%, transparent); }
.pill.dot::before { content: ""; width: 7px; height: 7px; border-radius: 50%; background: currentColor; }

/* ---------- charts */
.charts { display: grid; gap: 14px; grid-template-columns: repeat(2, minmax(0, 1fr)); }
.chart { border: 1px solid var(--border); border-radius: 12px; padding: 16px 18px 12px; background: var(--card-2); position: relative; min-width: 0; }
.chart header { display: flex; align-items: baseline; justify-content: space-between; gap: 10px; margin-bottom: 8px; }
.chart h3 { margin: 0; font-size: 14px; font-weight: 650; }
.chart .now { font-size: 20px; font-weight: 750; }
.chart .legend { display: flex; gap: 14px; color: var(--muted); font-size: 12px; margin-top: 4px; }
.chart .legend i { display: inline-block; width: 9px; height: 9px; border-radius: 3px; margin-inline-end: 6px; }
.plot { direction: ltr; position: relative; }
.plot svg { width: 100%; height: 190px; overflow: visible; max-width: 100%; }
.plot { min-height: 190px; }
.plot .grid line { stroke: var(--border); stroke-width: 1; }
.plot text { fill: var(--muted); font-size: 11px; }
.tip {
  position: absolute; pointer-events: none; transform: translate(-50%, -100%); background: var(--card); border: 1px solid var(--border-2);
  border-radius: 8px; padding: 6px 9px; font-size: 12px; white-space: nowrap; box-shadow: 0 6px 20px rgba(0, 0, 0, .35); z-index: 3;
}

.skeleton { height: 120px; border-radius: 12px; background: linear-gradient(90deg, var(--card-2), var(--border), var(--card-2)); background-size: 200% 100%; animation: sk 1.3s infinite; }
@keyframes sk { to { background-position: -200% 0; } }

.foot { text-align: center; color: var(--muted); font-size: 12px; }

/* ---------- login */
.login-page { min-height: 100vh; display: grid; place-items: center; padding: 24px; }
.login-card { width: 100%; max-width: 400px; padding: 32px 30px 28px; }
.login-card .brand { margin-bottom: 24px; }
.field { display: grid; gap: 7px; margin-bottom: 16px; }
.field label { font-size: 12.5px; color: var(--muted); font-weight: 600; }
.field input {
  height: 44px; border-radius: 10px; border: 1px solid var(--border-2); background: var(--card-2); padding: 0 14px; width: 100%;
}
.field input:focus { border-color: var(--accent); outline: none; }
.login-card .btn.primary { width: 100%; justify-content: center; height: 44px; }
.form-error { color: var(--red); font-size: 13px; min-height: 20px; margin-bottom: 8px; }

/* ---------- responsive */
@media (max-width: 1100px) {
  .layout { grid-template-columns: minmax(0, 1fr); }
  .side { position: static; padding: 14px 12px; }
  .nav { display: flex; overflow-x: auto; padding-bottom: 4px; }
  .nav a { flex: none; }
  .charts { grid-template-columns: 1fr; }
}
@media (max-width: 640px) {
  .wrap { padding: 12px 12px 28px; gap: 12px; }
  .topbar { padding: 14px; }
  .panel { padding: 18px 14px; }
  .stats { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
  .stat { padding: 13px 14px; }
  .stat .value { font-size: 22px; }
  .btn .txt { display: none; }
  .btn { padding: 0 11px; }
}
@media (prefers-reduced-motion: reduce) { * { animation: none !important; transition: none !important; } }
__MONITORING_EOF__
  write_file panel/static/favicon.svg 644 <<'__MONITORING_EOF__'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="8" fill="#0e1520"/><path d="M16 5l9 3.5v7c0 5.4-3.7 9.2-9 11.5-5.3-2.3-9-6.1-9-11.5v-7L16 5z" fill="none" stroke="#2ee6a6" stroke-width="2" stroke-linejoin="round"/><path d="M10.5 16h3l2-3.5 2.5 7 2-3.5h1.5" fill="none" stroke="#2ee6a6" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>
__MONITORING_EOF__
  if [ ! -e "$INSTALL_DIR/prometheus/targets/http.yml" ]; then
  write_file prometheus/targets/http.yml 644 <<'__MONITORING_EOF__'
# Websites to monitor (uptime, response time, SSL expiry). Picked up automatically on save.
- targets:
    - https://example.com
__MONITORING_EOF__
  fi
  if [ ! -e "$INSTALL_DIR/prometheus/targets/tcp.yml" ]; then
  write_file prometheus/targets/tcp.yml 644 <<'__MONITORING_EOF__'
# TCP ports to monitor, as host:port. Picked up automatically on save.
# - targets:
#     - 127.0.0.1:22
[]
__MONITORING_EOF__
  fi
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
