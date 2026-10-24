#!/usr/bin/env bash
# Server monitoring installer - single self-contained file.
# Installs Docker (if missing), then deploys Prometheus + Grafana + Alertmanager +
# node_exporter + cAdvisor + Blackbox exporter under /opt/server-monitoring.
#
# Usage (as root):
#   bash install.sh                 # interactive
#   bash install.sh -y              # non-interactive, uses env vars / defaults
#   bash install.sh --no-start      # write files only, don't start containers
#   bash install.sh --uninstall     # stop and remove containers (keeps data volumes)
#   bash install.sh --purge         # also delete data volumes and the install dir
#
# Optional env vars: INSTALL_DIR, GRAFANA_ADMIN_USER, GRAFANA_ADMIN_PASSWORD, GRAFANA_BIND,
#   TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, SITES (comma-separated URLs), PROMETHEUS_RETENTION
set -euo pipefail

INSTALL_DIR=${INSTALL_DIR:-/opt/server-monitoring}
ASSUME_YES=0; NO_START=0; ACTION=install
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    --no-start) NO_START=1 ;;
    --uninstall) ACTION=uninstall ;;
    --purge) ACTION=purge ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
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
  if [ "$ASSUME_YES" = 1 ] || [ ! -r /dev/tty ]; then printf -v "$var" '%s' "$default"; return; fi
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
      - "${GRAFANA_BIND:-127.0.0.1}:3000:3000"
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

# 127.0.0.1 = Grafana reachable only from the server itself (use an SSH tunnel or reverse proxy)
# 0.0.0.0   = reachable from the internet on port 3000
GRAFANA_BIND=127.0.0.1
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
| **Grafana** | داشبورد (Server Overview به‌صورت خودکار نصب می‌شود) |
| **Alertmanager** | ارسال هشدار به تلگرام |
| **node_exporter** | متریک‌های سیستم: CPU، رم، دیسک، شبکه، load |
| **cAdvisor** | متریک کانتینرهای Docker |
| **Blackbox exporter** | چک آپتایم سایت‌ها، پورت‌ها و انقضای SSL |

## نصب روی سرور لینوکسی (تک‌فایل)

فقط فایل `install.sh` را روی سرور کپی کنید (مثلاً `scp install.sh root@SERVER:`) و اجرا کنید:

```bash
sudo bash install.sh
```

نصب‌کننده خودش Docker را (اگر نباشد) نصب می‌کند، همه فایل‌ها را در `/opt/server-monitoring` می‌سازد و استک را بالا می‌آورد. چند سؤال می‌پرسد: رمز Grafana (خالی = رمز تصادفی)، آدرس listen، توکن تلگرام (اختیاری) و لیست سایت‌ها (اختیاری).

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

اگر Grafana روی `127.0.0.1` باشد (پیش‌فرض)، از کامپیوتر خودتان با `ssh -L 3000:127.0.0.1:3000 root@SERVER` وصل شوید. اگر `0.0.0.0` انتخاب کنید پورت 3000 باید در فایروال باز باشد، و برای محیط واقعی حتماً HTTPS جلویش بگذارید.

> `install.sh` از روی فایل‌های همین ریپو ساخته می‌شود. بعد از تغییر هر فایل، `./scripts/build-installer.sh` را اجرا کنید.

## راه‌اندازی دستی (بدون نصب‌کننده)

```bash
cp .env.example .env        # رمز Grafana و توکن/چت‌آیدی تلگرام را بنویسید
./scripts/render-config.sh  # ساخت alertmanager/alertmanager.yml از روی .env
docker compose up -d
```

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
  ask GRAFANA_BIND "Grafana listen address (127.0.0.1 = local only, 0.0.0.0 = public)" 127.0.0.1
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
  for v in GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD GRAFANA_BIND TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID SITES; do
    case "${!v:-}" in *\'*|*$'\n'*) die "$v must not contain single quotes or newlines." ;; esac
  done
  umask 077
  cat > "$INSTALL_DIR/.env" <<ENV
GRAFANA_ADMIN_USER='$GRAFANA_ADMIN_USER'
GRAFANA_ADMIN_PASSWORD='$GRAFANA_ADMIN_PASSWORD'
GRAFANA_BIND='$GRAFANA_BIND'
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
compose pull --quiet
compose up -d --remove-orphans

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
if [ "$GRAFANA_BIND" = 127.0.0.1 ]; then
  echo "  Grafana is local-only. From your computer run:  ssh -L 3000:127.0.0.1:3000 root@$ip"
  echo "  then open http://localhost:3000"
else
  echo "  Grafana:  http://$ip:3000   (open port 3000 in your firewall; put HTTPS in front for production)"
fi
echo "  Login:    $GRAFANA_ADMIN_USER / ${GENERATED_PW:+$GRAFANA_ADMIN_PASSWORD}${GENERATED_PW:-(the password you chose)}"
[ -n "${GENERATED_PW:-}" ] && echo "  (saved in $INSTALL_DIR/.env)"
echo "  Websites: edit $INSTALL_DIR/prometheus/targets/http.yml (no restart needed)"
echo "  Manage:   docker compose --project-directory $INSTALL_DIR ps | logs | restart"
[ -z "${TELEGRAM_BOT_TOKEN:-}" ] && echo "  Alerts:   Telegram not configured - fill TELEGRAM_* in $INSTALL_DIR/.env, then run $INSTALL_DIR/scripts/render-config.sh && docker compose --project-directory $INSTALL_DIR restart alertmanager"
exit 0
