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
      # The whole directory is mounted (not one file) so the panel can replace alertmanager.yml.
      - ./alertmanager:/etc/alertmanager:ro
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
      # Network stats come from node-net below: inside a container this collector would only
      # see the container's own virtual interface, not the server's real network cards.
      - --no-collector.netdev
      - --no-collector.netclass
      - --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)
    volumes:
      - /:/host:ro,rslave
    networks: [monitoring]

  # Reads the HOST's network namespace (via PID 1) so real NIC traffic is measured correctly.
  # Needs privileged: reading another namespace's /proc/1/net is blocked by the default
  # AppArmor/ptrace restrictions.
  node-net:
    image: prom/node-exporter:v1.8.2
    restart: unless-stopped
    pid: host
    privileged: true
    user: root
    command:
      - --path.procfs=/host/proc/1
      - --path.sysfs=/host/sys
      - --collector.disable-defaults
      - --collector.netdev
      # netlink would ask the kernel about the exporter's OWN namespace and ignore --path.procfs
      - --no-collector.netdev.netlink
      - --collector.netclass
      - --no-collector.netclass.netlink
      - --collector.netdev.device-exclude=^(lo|veth.*|docker.*|br-.*|virbr.*|cni.*|cali.*|flannel.*|ifb.*)$$
      - --collector.netclass.ignored-devices=^(lo|veth.*|docker.*|br-.*|virbr.*|cni.*|cali.*|flannel.*|ifb.*)$$
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
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
    # Group that owns /var/run/docker.sock (the installer sets DOCKER_GID); lets the panel manage containers.
    group_add: ["${DOCKER_GID:-65534}"]
    read_only: true
    tmpfs: [/tmp]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    environment:
      PYTHONDONTWRITEBYTECODE: "1"
      PROMETHEUS_URL: http://prometheus:9090
      ALERTMANAGER_URL: http://alertmanager:9093
      BLACKBOX_URL: http://blackbox:9115
      PANEL_USER: ${PANEL_USER:-admin}
      PANEL_PASSWORD: ${PANEL_PASSWORD:?set PANEL_PASSWORD in .env}
      PANEL_LISTEN_PORT: "8080"
      PANEL_DOCKER_CONTROL: ${PANEL_DOCKER_CONTROL:-1}
      CONFIG_DIR: /config
      DATA_DIR: /data
    volumes:
      - ./panel:/app:ro
      # Writable so the panel can add sites/servers, edit alert rules and connect Telegram.
      - ./prometheus/targets:/config/targets
      - ./prometheus/rules:/config/rules
      - ./alertmanager:/config/alertmanager
      - ./data/panel:/data
      # Docker control. Whoever can use this socket is root on the host: keep the panel password strong.
      # To switch it off set PANEL_DOCKER_CONTROL=0 in .env (and/or DOCKER_SOCKET=/dev/null).
      - ${DOCKER_SOCKET:-/var/run/docker.sock}:/var/run/docker.sock
    ports:
      - "${PANEL_BIND:-0.0.0.0}:${PANEL_PORT:-3000}:8080"
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request as u; u.urlopen('http://127.0.0.1:8080/healthz', timeout=3)"]
      interval: 30s
      timeout: 5s
      retries: 3
    depends_on: [prometheus, alertmanager, blackbox]
    networks: [monitoring]

volumes:
  prometheus_data:
  alertmanager_data:

networks:
  monitoring:
__MONITORING_EOF__
  write_file .env.example 644 <<'__MONITORING_EOF__'
# Login for the web panel
PANEL_USER=admin
PANEL_PASSWORD=change-me

# 0.0.0.0   = panel reachable from any network on PANEL_PORT (open the port in your firewall)
# 127.0.0.1 = local only (use an SSH tunnel or a reverse proxy)
PANEL_BIND=0.0.0.0
PANEL_PORT=3000

PROMETHEUS_RETENTION=30d

# Optional first-time Telegram setup. After install, manage it in the panel (Notifications page).
TELEGRAM_BOT_TOKEN=123456:ABC-your-token
TELEGRAM_CHAT_ID=123456789

# Docker control from the panel (start/stop/create containers).
# DOCKER_GID is the group that owns /var/run/docker.sock; the installer fills it in (check: stat -c %g /var/run/docker.sock).
DOCKER_GID=999
# Set to 0 to make the container list read-only.
PANEL_DOCKER_CONTROL=1
__MONITORING_EOF__
  write_file .gitignore 644 <<'__MONITORING_EOF__'
.env
alertmanager/alertmanager.yml
data/
__MONITORING_EOF__
  write_file README.md 644 <<'__MONITORING_EOF__'
# مانیتورینگ کامل سرور

استک آماده‌ی مانیتورینگ با Docker Compose و یک پنل وب اختصاصی که **همه‌ی کارها از خودش انجام می‌شود** (بدون نیاز به خط فرمان بعد از نصب):

| سرویس | کار |
|---|---|
| **پنل وب** | داشبورد و مدیریت کامل (پورت 3000) |
| **Prometheus** | جمع‌آوری و ذخیره متریک‌ها (۳۰ روز) |
| **Alertmanager** | ارسال هشدار (تلگرام) |
| **node_exporter** | متریک‌های سیستم: CPU، رم، دیسک، load |
| **node-net** | آمار واقعی کارت‌های شبکه‌ی سرور |
| **cAdvisor** | متریک کانتینرهای Docker |
| **Blackbox exporter** | چک آپتایم سایت‌ها، پورت‌ها و انقضای SSL |

## پنل وب

تم تیره/روشن، فارسی و انگلیسی (با راست‌به‌چپ)، کارت‌های آماری زنده و نمودار منابع. صفحه‌ها:

**مانیتورها:** نمای کلی، کانتینرها، سایت‌ها، دیسک‌ها، شبکه، تارگت‌ها، هشدارها.

**مدیریت (همه از پنل):**
- **سایت‌ها:** افزودن/حذف سایت (HTTP/HTTPS) و پورت TCP برای چک آپتایم، زمان پاسخ و انقضای SSL. دکمه‌ی ذره‌بین کنار هر ردیف چک را همان لحظه اجرا می‌کند و **دلیل ناموفق بودن** را به زبان ساده می‌گوید (قطع شدن handshake توسط سایت، پورت بسته، DNS، timeout، مشکل گواهی، کد خطای HTTP). برای سایتی که چک استاندارد را رد می‌کند، خودش حالت‌های دیگر (TLS قدیمی ۱.۰/۱.۱، نادیده گرفتن خطای گواهی، HTTP ساده، فقط اتصال TCP) را هم امتحان می‌کند و می‌گوید کدام کار می‌کند؛ با یک کلیک همان حالت برای مانیتور آن سایت فعال می‌شود (کنار آدرس برچسب حالت دیده می‌شود). اگر سایت فقط با HTTP ساده در دسترس باشد و HTTPS را برای این سرور رد کند، دکمه‌ی «مانیتور روی HTTP ساده» آدرس را (با حفظ نام) به `http://` تغییر می‌دهد.
- **سرورها:** افزودن/حذف سرورهای دیگر (با `node_exporter`)؛ دستور نصب روی سرور مقصد را همان‌جا می‌دهد.
- **کانتینرها:** شروع، توقف، ری‌استارت، دیدن لاگ، حذف و **ساخت کانتینر جدید** (ایمیج، پورت، متغیر محیطی، ولیوم، سیاست ری‌استارت).
- **اعلان‌ها:** اتصال ربات تلگرام (با دکمه‌ی «پیدا کردن Chat ID»)، پیام آزمایشی و هشدار آزمایشی.
- **قوانین هشدار:** روشن/خاموش کردن هر قانون و تغییر آستانه و مدت پایداری (مثلاً CPU بالای ۷۰٪ به‌جای ۸۵٪)، با دکمه‌ی بازگشت به پیش‌فرض.
- **تنظیمات:** تغییر نام کاربری و رمز، وضعیت کنترل داکر.

**آدرس و ورود:** `http://IP-SERVER:3000`، با `PANEL_USER` و `PANEL_PASSWORD` از `.env` (پس از تغییر رمز در پنل، رمز جدید معتبر است).

### امنیت

- کنترل داکر یعنی دسترسی به `/var/run/docker.sock` و **هر کسی که وارد پنل شود در عمل روی کل سرور مدیر (root) است.** رمز قوی بگذارید و جلوی پنل HTTPS (مثلاً Caddy یا Nginx) بگذارید؛ پنل روی HTTP ساده رمز را رمزنگاری نمی‌کند.
- برای فقط‌خواندنی کردن لیست کانتینرها در `.env` بنویسید `PANEL_DOCKER_CONTROL=0` و `docker compose up -d` را بزنید.
- ورود اشتباه با تأخیر یک‌ثانیه‌ای رد می‌شود، کوکی نشست `HttpOnly` و `SameSite=Strict` است، و همه‌ی عملیات تغییر (POST) هدر `X-Panel` و Origin درست می‌خواهند (محافظت CSRF).
- داده‌ها را فقط‌خواندنی از Prometheus می‌گیرد؛ کوئری دلخواه از بیرون پذیرفته نمی‌شود. ورودی‌های ساخت کانتینر (ایمیج، پورت، env، ولیوم) سخت‌گیرانه اعتبارسنجی می‌شوند و پنل نمی‌تواند کانتینر خودش را متوقف یا حذف کند.
- پورت پنل باید در فایروال سرور و پنل هاستینگ باز باشد. Prometheus و Alertmanager فقط روی `127.0.0.1` باز می‌شوند.
- **رمز را فراموش کردید؟** `rm /opt/server-monitoring/data/panel/auth.json && docker compose restart panel` رمز را به مقدار `.env` برمی‌گرداند.

## نصب یک‌خطی

روی سرور (به‌عنوان root یا با sudo):

```bash
curl -fsSL https://raw.githubusercontent.com/AmiRAliw24/desktop-tutorial/HEAD/install.sh | sudo bash
```

بدون سؤال، با متغیرهای محیطی (به `env` دقت کنید تا متغیرها به sudo برسند):

```bash
curl -fsSL https://raw.githubusercontent.com/AmiRAliw24/desktop-tutorial/HEAD/install.sh | sudo env PANEL_PASSWORD='...' SITES='https://a.com' bash -s -- -y
```

`HEAD` در آدرس همیشه به برنچ پیش‌فرض ریپو اشاره می‌کند، پس حتی اگر اسم برنچ عوض شود لینک کار می‌کند. ریپو باید public باشد؛ اگر private است، فایل را با `scp` کپی کنید (روش بعدی). گیت‌هاب فایل‌های raw را تا چند دقیقه کش می‌کند، پس بعد از هر آپدیت ممکن است چند دقیقه نسخه‌ی قبلی را بدهد.

## نصب روی سرور لینوکسی (تک‌فایل)

فقط فایل `install.sh` را روی سرور کپی کنید (مثلاً `scp install.sh root@SERVER:`) و اجرا کنید:

```bash
sudo bash install.sh
```

نصب‌کننده خودش Docker را (اگر نباشد) نصب می‌کند، همه فایل‌ها را در `/opt/server-monitoring` می‌سازد و استک را بالا می‌آورد. چند سؤال می‌پرسد: نام کاربری و رمز پنل (رمز خالی = رمز تصادفی)، آدرس listen (پیش‌فرض `0.0.0.0`)، توکن تلگرام (اختیاری) و لیست سایت‌ها (اختیاری). همه‌ی این‌ها را بعداً هم از پنل می‌توانید عوض کنید.

بدون سؤال (برای اسکریپت و اتوماسیون):

```bash
sudo env PANEL_PASSWORD='...' PANEL_BIND=0.0.0.0 \
     TELEGRAM_BOT_TOKEN='...' TELEGRAM_CHAT_ID='...' \
     SITES='https://a.com,https://b.org' bash install.sh -y
```

| گزینه | کار |
|---|---|
| `-y` | بدون سؤال، با متغیرهای محیطی و پیش‌فرض‌ها |
| `--no-start` | فقط فایل‌ها را بنویس، کانتینری بالا نیاور |
| `--uninstall` | کانتینرها را حذف کن (داده‌ها می‌مانند) |
| `--purge` | کانتینرها، داده‌ها و پوشه نصب را کامل حذف کن |

اجرای دوباره `install.sh` امن است: کد آپدیت می‌شود و پنل ری‌استارت می‌شود، ولی `.env` و هر چیزی که از پنل تنظیم کرده‌اید (سایت‌ها، سرورها، تلگرام، قوانین، رمز) دست نمی‌خورد.

اگر پنل را روی `127.0.0.1` بگذارید، از کامپیوتر خودتان با `ssh -L 3000:127.0.0.1:3000 root@SERVER` وصل شوید.

> `install.sh` از روی فایل‌های همین ریپو ساخته می‌شود. بعد از تغییر هر فایل، `./scripts/build-installer.sh` را اجرا کنید.

### ارتقا از نسخه‌ی قدیمی

با اجرای دوباره‌ی `install.sh`: لاگین قدیمی (`GRAFANA_ADMIN_*`) به `PANEL_*` منتقل می‌شود، کانتینر Grafana حذف می‌شود، و فایل‌های قدیمی سایت‌ها/سرورها (`prometheus/targets/*.yml`) خودکار به قالب جدید (`*.json`) مهاجرت می‌کنند (فایل قدیمی به `.migrated` تغییر نام می‌دهد). اگر قبلاً تلگرام را در `.env` گذاشته بودید، به پنل منتقل می‌شود. داده‌های قدیمی Grafana روی دیسک می‌مانند؛ اگر لازم ندارید: `docker volume rm server-monitoring_grafana_data`.

## راه‌اندازی دستی (بدون نصب‌کننده)

```bash
cp .env.example .env                 # رمز پنل را بنویسید
echo "DOCKER_GID=$(stat -c %g /var/run/docker.sock)" >> .env
./scripts/render-config.sh           # پوشه‌ها، تنظیم اولیه‌ی Alertmanager و مجوزها (با sudo اجرا کنید)
docker compose up -d
```

- پنل وب: http://localhost:3000
- Prometheus: http://localhost:9090
- Alertmanager: http://localhost:9093

## تنظیمات پیشرفته (فایل‌ها)

همه‌ی این‌ها از پنل مدیریت می‌شوند و فایل‌ها را خود پنل می‌نویسد؛ دستی فقط وقتی ویرایش کنید که پنل در دسترس نیست:

- `prometheus/targets/{http,tcp,nodes}.json`: سایت‌ها، پورت‌ها و سرورها (قالب `file_sd` پرومتئوس؛ بعد از ذخیره خودکار اعمال می‌شود).
- `prometheus/rules/alerts.yml` و `alertmanager/alertmanager.yml`: از روی تنظیمات پنل تولید می‌شوند و ویرایش دستی‌شان بازنویسی می‌شود.
- `data/panel/settings.json`: توکن تلگرام و تنظیمات قوانین (مجوز 0600).
- برای سرور اضافه: روی آن سرور `node_exporter` اجرا کنید و پورت 9100 را فقط برای IP سرور مانیتورینگ باز کنید؛ سپس آدرس را در صفحه‌ی **سرورها** اضافه کنید.

## آمار شبکه

`node_exporter` داخل کانتینر فقط شبکه‌ی خود کانتینر را می‌بیند، نه کارت‌های واقعی سرور. به همین دلیل سرویس جدا `node-net` (همان `node_exporter` با `privileged` و خواندن از `/proc/1`، یعنی namespace شبکه‌ی خود سرور) آمار واقعی کارت‌ها (مثل `eth0`) را می‌دهد و `node_exporter` اصلی آمار شبکه را نمی‌دهد تا دوبار شمرده نشود. اگر جدول Network خالی بود، پنل بالای جدول دلیلش را می‌نویسد؛ برای جزئیات:

```bash
docker compose logs --tail 20 node-net
```

## اگر پنل نتوانست تنظیمات را ذخیره کند

پنل با کاربر `65534` اجرا می‌شود و باید روی این پوشه‌ها بنویسد. نصب‌کننده خودش مجوزها را درست می‌کند؛ دستی:

```bash
cd /opt/server-monitoring
sudo chown -R 65534:65534 data prometheus/targets prometheus/rules alertmanager
docker compose restart panel
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

  # Servers to monitor. Targets live in prometheus/targets/nodes.json, managed from the panel (reloaded automatically).
  # Each remote server runs its own node_exporter (with all default collectors, incl. network).
  - job_name: node
    file_sd_configs:
      - files: [/etc/prometheus/targets/nodes.json]
        refresh_interval: 15s

  # Real network-card stats of THIS server (see node-net in docker-compose.yml). Reported under
  # the same instance name as the main exporter so the panel shows them as one server.
  - job_name: node-net
    static_configs:
      - targets: [node-net:9100]
    relabel_configs:
      - target_label: instance
        replacement: node-exporter:9100

  - job_name: cadvisor
    static_configs:
      - targets: [cadvisor:8080]

  # Uptime / SSL checks. Targets live in prometheus/targets/http.json, managed from the panel.
  - job_name: blackbox-http
    metrics_path: /probe
    file_sd_configs:
      - files: [/etc/prometheus/targets/http.json]
        refresh_interval: 15s
    relabel_configs:
      # Standard check, unless the site has a check_module label (set from the panel for sites that need
      # old TLS or must ignore certificate errors). A fixed `params: module` would override any label.
      - target_label: __param_module
        replacement: http_2xx
      - source_labels: [check_module]
        regex: (.+)
        target_label: __param_module
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115

  # TCP port checks (e.g. SSH, database). Targets live in prometheus/targets/tcp.json, managed from the panel.
  - job_name: blackbox-tcp
    metrics_path: /probe
    params:
      module: [tcp_connect]
    file_sd_configs:
      - files: [/etc/prometheus/targets/tcp.json]
        refresh_interval: 15s
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox:9115
__MONITORING_EOF__
  write_file blackbox/blackbox.yml 644 <<'__MONITORING_EOF__'
modules:
  http_2xx:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true

  # The variants below exist for sites that fail the normal check. The panel tries them for you
  # ("Test now / why?" on the Websites page) and can switch a single site to one of them.
  # Sites that only speak the outdated TLS 1.0 / 1.1:
  http_2xx_legacy:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true
      tls_config:
        min_version: TLS10

  # Sites whose certificate is expired, self-signed or for another name:
  http_2xx_insecure:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true
      tls_config:
        insecure_skip_verify: true

  http_2xx_legacy_insecure:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      follow_redirects: true
      tls_config:
        min_version: TLS10
        insecure_skip_verify: true

  tcp_connect:
    prober: tcp
    timeout: 5s
__MONITORING_EOF__
  write_file scripts/render-config.sh 755 <<'__MONITORING_EOF__'
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
__MONITORING_EOF__
  write_file panel/server.py 644 <<'__MONITORING_EOF__'
#!/usr/bin/env python3
"""Monitoring panel backend: login, static files, a read-only JSON API over Prometheus, and the
management API (sites, servers, alert rules, Telegram, Docker containers, password).

Standard library only. Anything that changes state needs the session cookie, a JSON body and the
X-Panel header (a cross-site page cannot send that header), and is checked against the Origin.
"""
import json
import os
import sys
import threading
import time
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

import dockerapi
import icons
import monitor
import store
from auth import SESSION_TTL, Auth

USER = os.environ.get("PANEL_USER", "admin")
PASSWORD = os.environ.get("PANEL_PASSWORD", "")
PORT = int(os.environ.get("PANEL_LISTEN_PORT", "8080"))
STATIC = Path(__file__).parent / "static"
COOKIE = "panel_session"
VERSION = "2.0"

if not PASSWORD:
    sys.exit("PANEL_PASSWORD must be set")

auth = Auth(USER, PASSWORD, store.DATA)

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
# Generated icons, served without a login so a browser tab can always show them.
ICONS = {
    "/favicon.ico": (icons.ico, "image/x-icon"),
    "/favicon-32.png": (lambda: icons.png(32), "image/png"),
    "/apple-touch-icon.png": (lambda: icons.png(180), "image/png"),
}

CSP = ("default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
       "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
WRITE_HINT = ("The panel cannot write its configuration files (permission denied). On the server run: "
              "chown -R 65534:65534 /opt/server-monitoring/data /opt/server-monitoring/prometheus/targets "
              "/opt/server-monitoring/prometheus/rules /opt/server-monitoring/alertmanager")

# Failed logins are serialised and delayed, which caps brute-forcing at ~1 guess/second overall
# without letting an attacker lock the real user out (Docker hides client IPs behind its proxy).
_fail_lock = threading.Lock()


class BadRequest(ValueError):
    pass


# ------------------------------------------------------------------ read API

def api_containers(_q):
    metrics = monitor.container_metrics()          # keyed by short container id
    by_name = {m["name"]: m for m in metrics.values() if m["name"]}
    now = time.time()
    if dockerapi.available():
        rows = []
        for c in dockerapi.list_containers():
            m = metrics.get(c["id"]) or by_name.get(c["name"]) or {}
            running = c["state"] == "running"
            rows.append({**c, "cpu": m.get("cpu") if running else None, "mem": m.get("mem") if running else None,
                         "uptime": (now - m["started"]) if running and m.get("started") else None})
        return {"docker": True, "rows": rows}
    return {"docker": False, "rows": [
        {"id": "", "name": m["name"] or cid, "image": "", "state": "running", "status": "", "ports": [], "stack": False,
         "self": False, "cpu": m["cpu"], "mem": m["mem"], "uptime": (now - m["started"]) if m.get("started") else None}
        for cid, m in sorted(metrics.items(), key=lambda kv: kv[1]["name"] or kv[0])]}


def api_checks(_q):
    return {k: store.list_targets(k) for k in store.KINDS}


def api_rules(_q):
    return {"rules": store.get_rules()}


def api_settings(_q):
    return {"user": auth.user, "version": VERSION,
            "docker": {"enabled": dockerapi.ENABLED, "available": dockerapi.available()},
            "telegram": store.telegram_status()}


def api_docker_logs(q):
    return dockerapi.logs(q.get("id", ""), q.get("tail", 200))


GET_API = {**monitor.READ_API, "/api/containers": api_containers, "/api/checks": api_checks, "/api/rules": api_rules,
           "/api/settings": api_settings, "/api/docker/logs": api_docker_logs}


# ------------------------------------------------------------------ management API (POST)

def post_checks_add(b, _h):
    store.add_target(b.get("kind"), b.get("target"), b.get("name", ""))
    return {"ok": True}


def post_checks_remove(b, _h):
    store.remove_target(b.get("kind"), b.get("target"))
    return {"ok": True}


def post_checks_probe(b, _h):
    return store.probe_debug(b.get("kind"), b.get("target"))


def post_checks_mode(b, _h):
    store.set_mode(b.get("kind"), b.get("target"), b.get("mode"))
    return {"ok": True}


def post_checks_replace(b, _h):
    store.replace_target(b.get("kind"), b.get("target"), b.get("new_target"))
    return {"ok": True}


def post_telegram_save(b, _h):
    return {"ok": True, **store.save_telegram(b.get("token", ""), b.get("chat_id", ""))}


def post_telegram_test(b, _h):
    store.telegram_test(b.get("token", ""), b.get("chat_id", ""))
    return {"ok": True}


def post_telegram_chats(b, _h):
    return {"chats": store.telegram_chats(b.get("token", ""))}


def post_telegram_remove(_b, _h):
    store.remove_telegram()
    return {"ok": True}


def post_alert_test(_b, _h):
    store.send_test_alert()
    return {"ok": True}


def post_rules_set(b, _h):
    store.set_rule(b.get("name"), b.get("enabled", True), b.get("value"), b.get("for", 0))
    return {"ok": True}


def post_rules_reset(_b, _h):
    store.reset_rules()
    return {"ok": True}


def post_docker_action(b, _h):
    return dockerapi.act(str(b.get("id", "")), str(b.get("action", "")))


def post_docker_run(b, _h):
    return dockerapi.run(b)


def post_password(b, h):
    auth.change(str(b.get("current", "")), str(b.get("new", "")), b.get("user"))
    # The session key changed with the credentials: hand the current browser a fresh cookie.
    h.new_cookie = f"{COOKIE}={auth.make_token()}; Path=/; Max-Age={SESSION_TTL}; HttpOnly; SameSite=Strict"
    return {"ok": True, "user": auth.user}


POST_API = {
    "/api/checks/add": post_checks_add, "/api/checks/remove": post_checks_remove, "/api/checks/probe": post_checks_probe, "/api/checks/mode": post_checks_mode, "/api/checks/replace": post_checks_replace,
    "/api/telegram/save": post_telegram_save, "/api/telegram/test": post_telegram_test,
    "/api/telegram/chats": post_telegram_chats, "/api/telegram/remove": post_telegram_remove,
    "/api/alerts/test": post_alert_test, "/api/rules/set": post_rules_set, "/api/rules/reset": post_rules_reset,
    "/api/docker/action": post_docker_action, "/api/docker/run": post_docker_run, "/api/password": post_password,
}

# ------------------------------------------------------------------ http

class Handler(BaseHTTPRequestHandler):
    server_version = "panel"
    sys_version = ""
    new_cookie = None

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

    def _bytes(self, body, ctype):
        self._headers(200, ctype, len(body))
        self.wfile.write(body)

    def _file(self, name, ctype):
        self._bytes((STATIC / name).read_bytes(), ctype)

    def _redirect(self, location):
        self._headers(302, "text/plain", 0, [("Location", location)])

    def _authed(self):
        cookie = SimpleCookie(self.headers.get("Cookie", ""))
        return COOKIE in cookie and auth.valid_token(cookie[COOKIE].value)

    def _run(self, fn, *args):
        """Call an API function and turn its exceptions into JSON error responses."""
        try:
            return self._json(200, fn(*args), [("Set-Cookie", self.new_cookie)] if self.new_cookie else ())
        except (ValueError, KeyError, TypeError) as e:  # ConfigError is a ValueError
            return self._json(400, {"error": str(e)})
        except store.ApplyError as e:
            return self._json(502, {"error": str(e), "saved": True})
        except dockerapi.DockerError as e:
            return self._json(502, {"error": str(e)})
        except PermissionError:
            return self._json(500, {"error": WRITE_HINT})
        except Exception as e:  # prometheus unreachable, bad response, ...
            return self._json(502, {"error": f"{type(e).__name__}: {e}"})

    # -- routes
    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path == "/healthz":
            return self._json(200, {"ok": True})
        if path in ICONS:
            make, ctype = ICONS[path]
            return self._bytes(make(), ctype)
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
        if path in GET_API:
            params = {k: v[0] for k, v in parse_qs(url.query).items()}
            return self._run(GET_API[path], params)
        self._json(404, {"error": "not found"})

    def _body(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length > 65536:
                raise BadRequest("request too large")
            data = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(data, dict):
                raise BadRequest("expected a JSON object")
            return data
        except (ValueError, TypeError) as e:
            raise BadRequest(str(e) or "bad request") from e

    def _same_origin(self):
        origin = self.headers.get("Origin")
        return origin is None or urlparse(origin).netloc == self.headers.get("Host")

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/logout":
            return self._json(200, {"ok": True}, [("Set-Cookie", f"{COOKIE}=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict")])
        if path == "/login":
            return self._login()
        if path not in POST_API:
            return self._json(404, {"error": "not found"})
        if not self._authed():
            return self._json(401, {"error": "unauthorized"})
        if self.headers.get("X-Panel") != "1" or not self._same_origin():
            return self._json(403, {"error": "forbidden"})
        try:
            body = self._body()
        except BadRequest as e:
            return self._json(400, {"error": str(e)})
        self._run(POST_API[path], body, self)

    def _login(self):
        try:
            data = self._body()
            user, password = str(data.get("user", "")), str(data.get("password", ""))
        except BadRequest:
            return self._json(400, {"error": "bad request"})
        if not auth.verify(user, password):
            with _fail_lock:
                time.sleep(1)
            return self._json(401, {"error": "invalid credentials"})
        cookie = f"{COOKIE}={auth.make_token()}; Path=/; Max-Age={SESSION_TTL}; HttpOnly; SameSite=Strict"
        self._json(200, {"ok": True}, [("Set-Cookie", cookie)])


def main():
    try:
        store.bootstrap()
    except OSError as e:
        print(f"WARNING: cannot prepare configuration files ({e}). {WRITE_HINT}", flush=True)
    print(f"panel {VERSION} listening on :{PORT}, prometheus at {monitor.PROM}, docker control "
          f"{'on' if dockerapi.ENABLED else 'off'}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
__MONITORING_EOF__
  write_file panel/store.py 644 <<'__MONITORING_EOF__'
"""Everything the panel can change: monitored sites/ports/servers, alert rules and Telegram.

State lives in plain files so the stack keeps working without the panel:
  CONFIG/targets/{http,tcp,nodes}.json   Prometheus file_sd targets (picked up automatically)
  CONFIG/rules/alerts.yml                generated from the rule settings below
  CONFIG/alertmanager/alertmanager.yml   generated from the Telegram settings
  DATA/settings.json                     panel settings (Telegram credentials, rule overrides)
Files are written atomically; Prometheus / Alertmanager are reloaded over HTTP afterwards.
"""
import json
import os
import re
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen

CONFIG = Path(os.environ.get("CONFIG_DIR", "/config"))
DATA = Path(os.environ.get("DATA_DIR", "/data"))
PROM_URL = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090").rstrip("/")
AM_URL = os.environ.get("ALERTMANAGER_URL", "http://alertmanager:9093").rstrip("/")
TELEGRAM_API = os.environ.get("TELEGRAM_API", "https://api.telegram.org").rstrip("/")
BLACKBOX_URL = os.environ.get("BLACKBOX_URL", "http://blackbox:9115").rstrip("/")
LOCAL_NODE = "node-exporter:9100"
LOCK = threading.RLock()


class ConfigError(ValueError):
    """The request was invalid (shown to the user as-is)."""


class ApplyError(Exception):
    """The change was saved, but Prometheus/Alertmanager could not be reloaded."""


# ------------------------------------------------------------------ files and reloads

def atomic_write(path, text, mode=0o644):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")  # not matched by the *.json / *.yml globs
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def _write_if_changed(path, text, mode=0o644):
    try:
        if Path(path).read_text(encoding="utf-8") == text:
            return False
    except OSError:
        pass
    atomic_write(path, text, mode)
    return True


def _post(url, what):
    try:
        with urlopen(Request(url, data=b"", method="POST"), timeout=10):
            return
    except HTTPError as e:
        detail = e.read(300).decode("utf-8", "replace").strip()
        raise ApplyError(f"{what} rejected the new configuration: {detail or e.code}") from e
    except (URLError, OSError) as e:
        raise ApplyError(f"{what} is not reachable: {getattr(e, 'reason', e)}") from e


def reload_prometheus():
    _post(f"{PROM_URL}/-/reload", "Prometheus")


def reload_alertmanager():
    _post(f"{AM_URL}/-/reload", "Alertmanager")


def load_settings():
    try:
        data = json.loads((DATA / "settings.json").read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_settings(settings):
    atomic_write(DATA / "settings.json", json.dumps(settings, indent=2), 0o600)


# ------------------------------------------------------------------ targets (sites, ports, servers)

KINDS = {"http": "http.json", "tcp": "tcp.json", "nodes": "nodes.json"}
# How an HTTP(S) site is checked. Each mode is a blackbox module (see blackbox/blackbox.yml); a site that
# needs a non-default one gets a check_module label, which prometheus.yml relabels into the probe's module.
HTTP_MODES = {"default": "http_2xx", "legacy_tls": "http_2xx_legacy", "no_verify": "http_2xx_insecure",
              "legacy_no_verify": "http_2xx_legacy_insecure"}
MODE_BY_MODULE = {v: k for k, v in HTTP_MODES.items()}
MAX_TARGETS = 200
URL_RE = re.compile(r"^https?://[^\s\"'`<>\\]{1,500}$")
HOST_PORT_RE = re.compile(r"^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?|\[[0-9A-Fa-f:.]+\]):(\d{1,5})$")
NAME_RE = re.compile(r"^[^\x00-\x1f\"'`<>\\]{0,60}$")


def _targets_file(kind):
    if kind not in KINDS:
        raise ConfigError("unknown kind")
    return CONFIG / "targets" / KINDS[kind]


def validate_target(kind, target):
    target = str(target or "").strip()
    if kind == "http":
        parsed = urlparse(target)
        try:
            port_ok = parsed.port is None or 1 <= parsed.port <= 65535
        except ValueError:
            port_ok = False
        if (not URL_RE.match(target) or not parsed.hostname or not port_ok or parsed.netloc.endswith(":")
                or not re.match(r"^[A-Za-z0-9._-]+$|^[0-9A-Fa-f:.]+$", parsed.hostname)):
            raise ConfigError("Enter a full address such as https://example.com")
    else:
        m = HOST_PORT_RE.match(target)
        if not m or not 1 <= int(m.group(1)) <= 65535:
            raise ConfigError("Enter an address in the form host:port, for example 203.0.113.10:22")
    return target


def _read_groups(kind):
    try:
        data = json.loads(_targets_file(kind).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [g for g in data if isinstance(g, dict) and isinstance(g.get("targets"), list)] if isinstance(data, list) else []


def list_targets(kind):
    rows = []
    for g in _read_groups(kind):
        labels = g.get("labels") or {}
        for t in g["targets"]:
            rows.append({"target": t, "name": labels.get("name") or labels.get("instance_name") or "",
                         "locked": kind == "nodes" and t == LOCAL_NODE,
                         "mode": MODE_BY_MODULE.get(labels.get("check_module", ""), "default") if kind == "http" else "default"})
    return rows


def _write_groups(kind, groups):
    atomic_write(_targets_file(kind), json.dumps(groups, indent=2, ensure_ascii=False))


def add_target(kind, target, name=""):
    target = validate_target(kind, target)
    name = str(name or "").strip()
    if not NAME_RE.match(name):
        raise ConfigError("The name contains characters that are not allowed")
    with LOCK:
        groups = _read_groups(kind)
        if any(target in g["targets"] for g in groups):
            raise ConfigError("This address is already being monitored")
        if sum(len(g["targets"]) for g in groups) >= MAX_TARGETS:
            raise ConfigError("Too many entries")
        label = "instance_name" if kind == "nodes" else "name"
        groups.append({"targets": [target], "labels": {label: name} if name else {}})
        _write_groups(kind, groups)


def remove_target(kind, target):
    target = str(target or "").strip()
    if kind == "nodes" and target == LOCAL_NODE:
        raise ConfigError("This is the server the monitoring stack runs on; it cannot be removed")
    with LOCK:
        groups = _read_groups(kind)
        kept = [{**g, "targets": [t for t in g["targets"] if t != target]} for g in groups]
        kept = [g for g in kept if g["targets"]]
        if sum(len(g["targets"]) for g in kept) == sum(len(g["targets"]) for g in groups):
            raise ConfigError("Not found")
        _write_groups(kind, kept)


def _blackbox(module, target):
    query = urlencode({"module": module, "target": target, "debug": "true"})
    try:
        with urlopen(f"{BLACKBOX_URL}/probe?{query}", timeout=25) as resp:
            text = resp.read(200_000).decode("utf-8", "replace")
    except HTTPError as e:
        text = e.read(200_000).decode("utf-8", "replace")
    except (URLError, OSError) as e:
        raise ApplyError(f"The blackbox checker is not reachable: {getattr(e, 'reason', e)}") from e
    ok = re.search(r"^probe_success\s+1\b", text, re.M) is not None
    status = re.search(r"^probe_http_status_code\s+(\d+)", text, re.M)
    http_status = int(status.group(1)) if status and int(status.group(1)) else None
    reason = ""
    for line in text.splitlines():                          # the first error carrying err="..." is the real cause
        m = re.search(r'level=error.*?err="((?:[^"\\]|\\.)*)"', line)
        if m:
            reason = m.group(1).replace('\\"', '"')
            break
    return {"ok": ok, "reason": reason, "kind": "" if ok else classify_failure(reason, http_status), "http_status": http_status,
            "log": "\n".join(l for l in text.splitlines() if not l.startswith("#"))[-20000:]}


def probe_debug(kind, target):
    """Run one check right now and say why it failed. For a failing website also try the other modes
    (old TLS, ignoring certificate errors, plain HTTP, bare TCP) so the user can see what would work."""
    if kind not in ("http", "tcp"):
        raise ConfigError("unknown kind")
    target = str(target or "").strip()
    row = next((r for r in list_targets(kind) if r["target"] == target), None)
    if row is None:
        raise ConfigError("Only monitored addresses can be tested")
    mode = row["mode"]
    result = _blackbox(HTTP_MODES[mode] if kind == "http" else "tcp_connect", target)
    result["mode"] = mode
    result["variants"], result["suggest"] = [], ""
    if result["ok"] or kind != "http":
        return result

    parsed = urlparse(target)
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    host = f"[{parsed.hostname}]" if ":" in (parsed.hostname or "") else parsed.hostname
    plan = [(m, HTTP_MODES[m], target) for m in HTTP_MODES if m != mode]
    if parsed.scheme == "https":
        plan.append(("plain_http", "http_2xx", "http://" + target[len("https://"):]))
    plan.append(("tcp", "tcp_connect", f"{host}:{port}"))
    with ThreadPoolExecutor(max_workers=len(plan)) as pool:
        outcomes = list(pool.map(lambda p: _blackbox(p[1], p[2]), plan))
    for (vid, _module, _target), out in zip(plan, outcomes):
        result["variants"].append({"id": vid, "ok": out["ok"], "reason": out["reason"], "kind": out["kind"], "http_status": out["http_status"]})
    result["suggest"] = next((v["id"] for v in result["variants"] if v["ok"] and v["id"] in HTTP_MODES), "")
    return result


def classify_failure(reason, http_status):
    """Map a blackbox error to a short code the UI turns into a plain-language explanation."""
    r = reason.lower()
    if "x509" in r or "certificate" in r:                  # checked first: these errors also contain "tls:"
        return "tls"
    if "handshake failure" in r or "protocol version" in r or "no cipher" in r or "remote error: tls" in r:
        return "handshake"
    if "connection reset" in r or "unexpected eof" in r or "eof" in r.split(":")[-1]:
        return "reset"
    if "connection refused" in r:
        return "refused"
    if "no such host" in r or "server misbehaving" in r or "lookup" in r:
        return "dns"
    if "timeout" in r or "deadline exceeded" in r:
        return "timeout"
    if "network is unreachable" in r or "no route" in r:
        return "unreachable"
    if http_status and not reason:
        return "status"
    return "status" if http_status else "other"


def replace_target(kind, old, new):
    """Swap one address for another, keeping its name (e.g. to monitor a site over http:// instead of https://)."""
    new = validate_target(kind, new)
    old = str(old or "").strip()
    with LOCK:
        groups = _read_groups(kind)
        match = next((g for g in groups if old in g["targets"]), None)
        if match is None:
            raise ConfigError("Not found")
        if old != new and any(new in g["targets"] for g in groups):
            raise ConfigError("This address is already being monitored")
        labels = {k: v for k, v in (match.get("labels") or {}).items() if k != "check_module"}   # new address: standard check
        rest = [{**g, "targets": [t for t in g["targets"] if t != old]} for g in groups]
        rest = [g for g in rest if g["targets"]]
        rest.append({"targets": [new], "labels": labels})
        _write_groups(kind, rest)


def set_mode(kind, target, mode):
    if kind != "http":
        raise ConfigError("Only websites have a check mode")
    if mode not in HTTP_MODES:
        raise ConfigError("Unknown mode")
    target = str(target or "").strip()
    with LOCK:
        groups = _read_groups("http")
        hit = False
        for g in groups:
            if target in g["targets"]:
                labels = dict(g.get("labels") or {})
                labels.pop("check_module", None)
                if mode != "default":
                    labels["check_module"] = HTTP_MODES[mode]
                if len(g["targets"]) > 1:      # keep other targets of a shared group untouched
                    g["targets"] = [t for t in g["targets"] if t != target]
                    groups.append({"targets": [target], "labels": labels})
                else:
                    g["labels"] = labels
                hit = True
                break
        if not hit:
            raise ConfigError("Not found")
        _write_groups("http", groups)


def _legacy_items(text):
    """Targets from the old hand-edited YAML files (simple lists, one item per line or inline)."""
    items = []
    for line in text.splitlines():
        line = line.split(" #")[0].rstrip()
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = re.match(r"^\s*-\s*targets:\s*\[(.*)\]\s*$", line)
        if m:
            items += [x.strip().strip("'\"") for x in m.group(1).split(",") if x.strip()]
            continue
        if re.match(r"^\s*-\s*targets:\s*$", line):
            continue
        m = re.match(r"^\s{2,}-\s+(\S.*)$", line)
        if m:
            items.append(m.group(1).strip().strip("'\""))
    return items


def migrate_legacy():
    """Create the JSON target files, importing anything from the old *.yml files first."""
    for kind, fname in KINDS.items():
        json_file = CONFIG / "targets" / fname
        yml_file = json_file.with_suffix(".yml")
        if not json_file.exists():
            groups = []
            if yml_file.exists():
                for t in _legacy_items(yml_file.read_text(encoding="utf-8")):
                    try:
                        validate_target(kind, t)
                    except ConfigError:
                        continue
                    if not any(t in g["targets"] for g in groups):
                        groups.append({"targets": [t], "labels": {}})
            if kind == "nodes":
                local = next((g for g in groups if LOCAL_NODE in g["targets"]), None)
                if local is None:
                    groups.insert(0, {"targets": [LOCAL_NODE], "labels": {"instance_name": "this-server"}})
                elif not local["labels"]:
                    local["labels"] = {"instance_name": "this-server"}
            _write_groups(kind, groups)
        if yml_file.exists():
            yml_file.rename(yml_file.with_suffix(".yml.migrated"))


# ------------------------------------------------------------------ alert rules

HOST_FS = 'fstype!~"tmpfs|overlay|squashfs"'
DOCKER_CG = r'id=~".*docker[-/][a-f0-9]{64}(\\.scope)?"'   # see monitor.CG_DOCKER: match containers by id
CONTAINER = "{{ if $labels.name }}{{ $labels.name }}{{ else }}{{ $labels.id }}{{ end }}"
RULES = [
    {"name": "InstanceDown", "group": "host", "severity": "critical", "for": 2, "expr": "up == 0",
     "summary": "{{ $labels.job }} target {{ $labels.instance }} is down"},
    {"name": "HighCpuUsage", "group": "host", "severity": "warning", "for": 10,
     "expr": '100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > {t}',
     "t": {"default": 85, "unit": "%", "min": 1, "max": 100},
     "summary": 'CPU usage on {{ $labels.instance }} is {{ $value | printf "%.0f" }}%'},
    {"name": "HighMemoryUsage", "group": "host", "severity": "warning", "for": 10,
     "expr": "(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > {t}",
     "t": {"default": 90, "unit": "%", "min": 1, "max": 100},
     "summary": 'Memory usage on {{ $labels.instance }} is {{ $value | printf "%.0f" }}%'},
    {"name": "DiskSpaceLow", "group": "host", "severity": "warning", "for": 10,
     "expr": f"(1 - node_filesystem_avail_bytes{{{HOST_FS}}} / node_filesystem_size_bytes{{{HOST_FS}}}) * 100 > {{t}}",
     "t": {"default": 85, "unit": "%", "min": 1, "max": 100},
     "summary": 'Disk {{ $labels.mountpoint }} on {{ $labels.instance }} is {{ $value | printf "%.0f" }}% full'},
    {"name": "DiskWillFillIn24h", "group": "host", "severity": "critical", "for": 30,
     "expr": f"predict_linear(node_filesystem_avail_bytes{{{HOST_FS}}}[6h], {{t}} * 3600) < 0",
     "t": {"default": 24, "unit": "h", "min": 1, "max": 168},
     "summary": "Disk {{ $labels.mountpoint }} on {{ $labels.instance }} is predicted to fill up soon"},
    {"name": "HighLoad", "group": "host", "severity": "warning", "for": 10,
     "expr": 'node_load5 / count by (instance) (node_cpu_seconds_total{mode="idle"}) > {t}',
     "t": {"default": 2, "unit": "x cores", "min": 0.1, "max": 50},
     "summary": 'Load average on {{ $labels.instance }} is high ({{ $value | printf "%.1f" }}x cores)'},
    {"name": "HostRebooted", "group": "host", "severity": "info", "for": 0,
     "expr": "time() - node_boot_time_seconds < {t}",
     "t": {"default": 300, "unit": "s", "min": 60, "max": 3600},
     "summary": "{{ $labels.instance }} was rebooted recently"},
    {"name": "ContainerHighCpu", "group": "containers", "severity": "warning", "for": 10,
     "expr": f"sum by (id, name) (rate(container_cpu_usage_seconds_total{{{DOCKER_CG}}}[5m])) * 100 > {{t}}",
     "t": {"default": 90, "unit": "%", "min": 1, "max": 1000},
     "summary": f'Container {CONTAINER} CPU is {{{{ $value | printf "%.0f" }}}}%'},
    {"name": "ContainerHighMemory", "group": "containers", "severity": "warning", "for": 10,
     "expr": f"container_memory_working_set_bytes{{{DOCKER_CG}}} / (container_spec_memory_limit_bytes{{{DOCKER_CG}}} > 0) * 100 > {{t}}",
     "t": {"default": 90, "unit": "%", "min": 1, "max": 100},
     "summary": f'Container {CONTAINER} memory is {{{{ $value | printf "%.0f" }}}}% of its limit'},
    {"name": "EndpointDown", "group": "endpoints", "severity": "critical", "for": 2, "expr": "probe_success == 0",
     "summary": "{{ $labels.instance }} is unreachable"},
    {"name": "SslCertExpiringSoon", "group": "endpoints", "severity": "warning", "for": 60,
     "expr": "(probe_ssl_earliest_cert_expiry - time()) / 86400 < {t}",
     "t": {"default": 14, "unit": "days", "min": 1, "max": 90},
     "summary": 'SSL certificate for {{ $labels.instance }} expires in {{ $value | printf "%.0f" }} days'},
    {"name": "SlowEndpoint", "group": "endpoints", "severity": "warning", "for": 10,
     "expr": "probe_duration_seconds > {t}",
     "t": {"default": 3, "unit": "s", "min": 0.1, "max": 60},
     "summary": 'The response of {{ $labels.instance }} is slow ({{ $value | printf "%.1f" }}s)'},
]
RULE_BY_NAME = {r["name"]: r for r in RULES}


def _num(v):
    return str(int(v)) if float(v) == int(v) else repr(float(v))


def get_rules():
    overrides = load_settings().get("rules", {})
    out = []
    for r in RULES:
        o = overrides.get(r["name"], {})
        t = r.get("t")
        out.append({
            "name": r["name"], "group": r["group"], "severity": r["severity"],
            "enabled": o.get("enabled", True),
            "has_threshold": t is not None,
            "unit": t["unit"] if t else "", "min": t["min"] if t else None, "max": t["max"] if t else None,
            "default": t["default"] if t else None, "value": o.get("value", t["default"]) if t else None,
            "for": o.get("for", r["for"]), "default_for": r["for"],
        })
    return out


def render_rules(settings=None):
    overrides = (settings if settings is not None else load_settings()).get("rules", {})
    groups = {}
    for r in RULES:
        o = overrides.get(r["name"], {})
        if not o.get("enabled", True):
            continue
        expr = r["expr"]
        if "t" in r:
            expr = expr.replace("{t}", _num(o.get("value", r["t"]["default"])))
        minutes = int(o.get("for", r["for"]))
        lines = [f"      - alert: {r['name']}", f"        expr: '{expr}'"]
        if minutes:
            lines.append(f"        for: {minutes}m")
        lines += [f"        labels: {{severity: {r['severity']}}}",
                  "        annotations:", f"          summary: '{r['summary']}'"]
        groups.setdefault(r["group"], []).append("\n".join(lines))
    body = "".join(f"  - name: {g}\n    rules:\n" + "\n".join(rules) + "\n" for g, rules in groups.items())
    return "# Managed by the web panel (Alert rules page). Manual edits are overwritten.\ngroups:\n" + (body or "  []\n")


def apply_rules():
    _write_if_changed(CONFIG / "rules" / "alerts.yml", render_rules())
    reload_prometheus()


def set_rule(name, enabled, value, minutes):
    r = RULE_BY_NAME.get(name)
    if not r:
        raise ConfigError("Unknown rule")
    entry = {"enabled": bool(enabled)}
    if "t" in r:
        try:
            v = float(value)
        except (TypeError, ValueError):
            raise ConfigError("The threshold must be a number") from None
        if not r["t"]["min"] <= v <= r["t"]["max"]:
            raise ConfigError(f"The threshold must be between {r['t']['min']} and {r['t']['max']} {r['t']['unit']}")
        entry["value"] = v
    try:
        m = int(minutes)
    except (TypeError, ValueError):
        raise ConfigError("The duration must be a whole number of minutes") from None
    if not 0 <= m <= 1440:
        raise ConfigError("The duration must be between 0 and 1440 minutes")
    entry["for"] = m
    with LOCK:
        s = load_settings()
        s.setdefault("rules", {})[name] = entry
        save_settings(s)
        apply_rules()


def reset_rules():
    with LOCK:
        s = load_settings()
        s.pop("rules", None)
        save_settings(s)
        apply_rules()


# ------------------------------------------------------------------ Telegram + Alertmanager

TOKEN_RE = re.compile(r"^\d{5,15}:[A-Za-z0-9_-]{25,80}$")
CHAT_RE = re.compile(r"^-?\d{1,20}$")

AM_MINIMAL = "# Managed by the web panel. No notification channel is configured.\nroute:\n  receiver: none\nreceivers:\n  - name: none\n"
AM_TELEGRAM = """# Managed by the web panel (Notifications page). Manual edits are overwritten.
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
      - bot_token: "@TOKEN@"
        chat_id: @CHAT@
        parse_mode: ""
        send_resolved: true
        message: |
          {{ range .Alerts }}{{ if eq .Status "firing" }}\U0001F525{{ else }}✅{{ end }} [{{ .Labels.severity }}] {{ .Annotations.summary }}
          {{ end }}

inhibit_rules:
  - source_matchers: [severity="critical"]
    target_matchers: [severity="warning"]
    equal: [alertname, instance]
"""


def mask_token(token):
    return f"{token.split(':')[0]}:••••{token[-4:]}" if token else ""


def telegram_status():
    t = load_settings().get("telegram") or {}
    return {"configured": bool(t.get("token") and t.get("chat_id")), "chat_id": t.get("chat_id", ""),
            "token_hint": mask_token(t.get("token", "")), "bot": t.get("bot", "")}


def render_alertmanager(settings=None):
    t = (settings if settings is not None else load_settings()).get("telegram") or {}
    if t.get("token") and t.get("chat_id") and TOKEN_RE.match(t["token"]) and CHAT_RE.match(str(t["chat_id"])):
        return AM_TELEGRAM.replace("@TOKEN@", t["token"]).replace("@CHAT@", str(t["chat_id"]))
    return AM_MINIMAL


def apply_alertmanager():
    # The directory is bind-mounted, so replacing the file (new inode) is visible to the container.
    _write_if_changed(CONFIG / "alertmanager" / "alertmanager.yml", render_alertmanager())
    reload_alertmanager()


def _telegram(token, method, params=None):
    url = f"{TELEGRAM_API}/bot{token}/{method}"
    try:
        with urlopen(Request(url, data=urlencode(params).encode() if params else None), timeout=15) as resp:
            body = json.load(resp)
    except HTTPError as e:
        try:
            body = json.load(e)
        except ValueError:
            body = {"ok": False, "description": f"HTTP {e.code}"}
    except (URLError, OSError) as e:
        raise ConfigError(f"Cannot reach Telegram: {getattr(e, 'reason', e)}".replace(token, "***")) from e
    if not body.get("ok"):
        raise ConfigError(f"Telegram says: {body.get('description', 'error')}".replace(token, "***"))
    return body["result"]


def _resolve_token(token):
    token = str(token or "").strip()
    if not token:
        token = (load_settings().get("telegram") or {}).get("token", "")
    if not TOKEN_RE.match(token):
        raise ConfigError("Enter the bot token you got from @BotFather (it looks like 123456789:AA...)")
    return token


def telegram_chats(token=""):
    """Chats that recently wrote to the bot, so the user can pick the chat id instead of typing it."""
    token = _resolve_token(token)
    chats = {}
    for u in _telegram(token, "getUpdates", {"limit": 100, "timeout": 0}):
        for key in ("message", "edited_message", "channel_post", "my_chat_member"):
            chat = (u.get(key) or {}).get("chat")
            if chat:
                title = chat.get("title") or chat.get("username") or " ".join(
                    x for x in (chat.get("first_name"), chat.get("last_name")) if x)
                chats[chat["id"]] = {"id": str(chat["id"]), "title": title or str(chat["id"]), "type": chat.get("type", "")}
    return list(chats.values())


def telegram_test(token="", chat_id=""):
    token = _resolve_token(token)
    chat_id = str(chat_id or (load_settings().get("telegram") or {}).get("chat_id", "")).strip()
    if not CHAT_RE.match(chat_id):
        raise ConfigError("Enter the chat id (a number, negative for groups)")
    _telegram(token, "sendMessage", {"chat_id": chat_id, "text": "✅ Server Monitor: this is a test message. Alerts will arrive here."})


def save_telegram(token, chat_id):
    token = _resolve_token(token)
    chat_id = str(chat_id or "").strip()
    if not CHAT_RE.match(chat_id):
        raise ConfigError("Enter the chat id (a number, negative for groups)")
    bot = _telegram(token, "getMe").get("username", "")  # proves the token works before saving it
    with LOCK:
        s = load_settings()
        s["telegram"] = {"token": token, "chat_id": chat_id, "bot": bot}
        save_settings(s)
        apply_alertmanager()
    return {"bot": bot}


def remove_telegram():
    with LOCK:
        s = load_settings()
        s.pop("telegram", None)
        save_settings(s)
        apply_alertmanager()


def send_test_alert():
    """Fire a synthetic alert through Alertmanager (delivered after its ~30s grouping delay)."""
    now = time.time()
    fmt = lambda ts: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(ts))  # noqa: E731
    body = json.dumps([{"labels": {"alertname": "PanelTestAlert", "severity": "info"},
                        "annotations": {"summary": "Test alert sent from the web panel"},
                        "startsAt": fmt(now), "endsAt": fmt(now + 300)}]).encode()
    try:
        with urlopen(Request(f"{AM_URL}/api/v2/alerts", data=body, headers={"Content-Type": "application/json"}), timeout=10):
            pass
    except (URLError, OSError) as e:
        raise ApplyError(f"Alertmanager is not reachable: {getattr(e, 'reason', e)}") from e


# ------------------------------------------------------------------ startup

def bootstrap():
    """Create/migrate files and make Prometheus and Alertmanager pick them up (retries while they start)."""
    for sub in ("targets", "rules", "alertmanager"):
        (CONFIG / sub).mkdir(parents=True, exist_ok=True)
    DATA.mkdir(parents=True, exist_ok=True)
    migrate_legacy()
    settings = load_settings()
    changed_rules = _write_if_changed(CONFIG / "rules" / "alerts.yml", render_rules(settings))
    changed_am = _write_if_changed(CONFIG / "alertmanager" / "alertmanager.yml", render_alertmanager(settings))

    def reload_later():
        for _ in range(30):
            try:
                if changed_rules:
                    reload_prometheus()
                if changed_am:
                    reload_alertmanager()
                return
            except ApplyError:
                time.sleep(5)

    if changed_rules or changed_am:
        threading.Thread(target=reload_later, daemon=True).start()
__MONITORING_EOF__
  write_file panel/auth.py 644 <<'__MONITORING_EOF__'
"""Panel login: credentials from the environment, optionally replaced by a password changed in the panel.

A changed password is stored as a salted PBKDF2 hash in DATA/auth.json (mode 0600). Session cookies are
HMAC-signed with a key derived from the current credentials, so changing the password logs out every
other session. Forgot it? Delete DATA/auth.json to fall back to PANEL_USER / PANEL_PASSWORD from .env.
"""
import hashlib
import hmac
import json
import os
import secrets
import threading
import time
from pathlib import Path

SESSION_TTL = 7 * 24 * 3600
ITERATIONS = 200_000


def _hash(password, salt, iterations=ITERATIONS):
    return hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations).hex()


class Auth:
    def __init__(self, env_user, env_password, data_dir):
        self.env_user, self.env_password = env_user, env_password
        self.file = Path(data_dir) / "auth.json"
        self.lock = threading.Lock()
        self._load()

    def _load(self):
        self.stored = None
        try:
            data = json.loads(self.file.read_text(encoding="utf-8"))
            if all(k in data for k in ("user", "salt", "hash", "iterations")):
                self.stored = data
        except (OSError, ValueError):
            pass
        if self.stored:
            self.user = self.stored["user"]
            material = self.stored["hash"]
        else:
            self.user = self.env_user
            material = self.env_password
        self.secret = hashlib.sha256(f"panel-session:{self.user}:{material}".encode()).digest()

    # -- credentials
    def verify(self, user, password):
        ok_user = hmac.compare_digest(user.encode(), self.user.encode())
        if self.stored:
            digest = _hash(password, bytes.fromhex(self.stored["salt"]), int(self.stored["iterations"]))
            ok_pass = hmac.compare_digest(digest, self.stored["hash"])
        else:
            ok_pass = hmac.compare_digest(password.encode(), self.env_password.encode())
        return ok_user & ok_pass

    def change(self, current, new, new_user=None):
        new_user = (new_user or self.user).strip()
        if not self.verify(self.user, current):
            raise ValueError("The current password is wrong")
        if not 8 <= len(new) <= 128:
            raise ValueError("The new password must be 8 to 128 characters")
        if new == current and new_user == self.user:
            raise ValueError("The new password must differ from the current one")
        if not 1 <= len(new_user) <= 64 or any(c in new_user for c in "\x00\r\n:|"):
            raise ValueError("Invalid username")
        salt = secrets.token_bytes(16)
        data = {"user": new_user, "salt": salt.hex(), "iterations": ITERATIONS, "hash": _hash(new, salt)}
        with self.lock:
            self.file.parent.mkdir(parents=True, exist_ok=True)
            tmp = self.file.with_name(f".{self.file.name}.tmp")
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                json.dump(data, f)
            os.replace(tmp, self.file)
            self._load()

    # -- sessions
    def make_token(self):
        payload = f"{self.user}|{int(time.time()) + SESSION_TTL}"
        sig = hmac.new(self.secret, payload.encode(), hashlib.sha256).hexdigest()
        return f"{payload}.{sig}"

    def valid_token(self, token):
        try:
            payload, sig = token.rsplit(".", 1)
            expected = hmac.new(self.secret, payload.encode(), hashlib.sha256).hexdigest()
            user, exp = payload.split("|")
            return hmac.compare_digest(sig, expected) and user == self.user and int(exp) > time.time()
        except (ValueError, AttributeError):
            return False
__MONITORING_EOF__
  write_file panel/dockerapi.py 644 <<'__MONITORING_EOF__'
"""Minimal Docker Engine API client over the unix socket (standard library only).

Mounting the Docker socket gives whoever controls it root on the host, so everything that reaches the
daemon is validated here: ids, names, image references, ports, env vars and volume paths.
"""
import http.client
import json
import os
import re
import socket
from urllib.parse import quote, urlencode

SOCKET = os.environ.get("DOCKER_SOCKET_PATH", "/var/run/docker.sock")
ENABLED = os.environ.get("PANEL_DOCKER_CONTROL", "1") != "0"
STACK_PROJECT = os.environ.get("COMPOSE_PROJECT_NAME", "server-monitoring")
SELF_ID = os.environ.get("PANEL_CONTAINER_ID") or socket.gethostname()  # a container's hostname is its short id by default

ID_RE = re.compile(r"^[a-f0-9]{12,64}$")
NAME_RE = re.compile(r"^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$")
IMAGE_RE = re.compile(r"^[a-z0-9][A-Za-z0-9._/:-]{0,200}(@sha256:[a-f0-9]{64})?$")
PORT_RE = re.compile(r"^(?:(\d{1,3}(?:\.\d{1,3}){3}):)?(\d{1,5}):(\d{1,5})(?:/(tcp|udp))?$")
ENV_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,127}=[^\x00\n\r]{0,4096}$")
VOLUME_RE = re.compile(r"^(/[A-Za-z0-9._@%+=,~/-]*|[A-Za-z0-9][A-Za-z0-9_.-]{0,63}):(/[A-Za-z0-9._@%+=,~/-]*)(:(ro|rw))?$")
RESTART = {"no", "unless-stopped", "always", "on-failure"}
ACTIONS = {"start", "stop", "restart", "remove"}


class DockerError(Exception):
    pass


def _require():
    if not ENABLED:
        raise DockerError("Docker control is switched off (PANEL_DOCKER_CONTROL=0)")


class _UnixConnection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self._path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(self._path)


def _request(method, path, body=None, timeout=30):
    conn = _UnixConnection(SOCKET, timeout)
    try:
        payload = json.dumps(body).encode() if body is not None else None
        headers = {"Content-Type": "application/json"} if payload is not None else {}
        conn.request(method, path, body=payload, headers=headers)
        resp = conn.getresponse()
        return resp.status, resp.read()
    except OSError as e:
        raise DockerError(f"cannot reach Docker: {e}") from e
    finally:
        conn.close()


def _json(status, data, ok=(200, 201, 204)):
    if status in ok:
        return json.loads(data) if data else {}
    try:
        message = json.loads(data).get("message", "")
    except ValueError:
        message = data.decode("utf-8", "replace")[:300]
    raise DockerError(message or f"Docker returned HTTP {status}")


def available():
    if not ENABLED:
        return False
    try:
        status, _ = _request("GET", "/_ping", timeout=3)
        return status == 200
    except DockerError:
        return False


def _port_list(c):
    ports = []
    for p in c.get("Ports", []):
        if p.get("PublicPort"):
            ports.append(f"{p.get('IP', '')}:{p['PublicPort']}->{p['PrivatePort']}/{p['Type']}".lstrip(":"))
        else:
            ports.append(f"{p['PrivatePort']}/{p['Type']}")
    return sorted(set(ports))


def list_containers():
    _require()
    rows = []
    for c in _json(*_request("GET", "/containers/json?all=1")):
        labels = c.get("Labels") or {}
        cid = c["Id"]
        rows.append({
            "id": cid[:12],
            "name": (c.get("Names") or ["/?"])[0].lstrip("/"),
            "image": c.get("Image", ""),
            "state": c.get("State", ""),
            "status": c.get("Status", ""),
            "created": c.get("Created"),
            "ports": _port_list(c),
            "stack": labels.get("com.docker.compose.project") == STACK_PROJECT,
            "self": cid.startswith(SELF_ID) or SELF_ID.startswith(cid[:12]),
        })
    return sorted(rows, key=lambda r: (not r["stack"], r["name"]))


def _find(cid):
    if not ID_RE.match(cid or ""):
        raise ValueError("bad container id")
    for row in list_containers():
        if row["id"].startswith(cid[:12]):
            return row
    raise DockerError("container not found")


def act(cid, action):
    _require()
    if action not in ACTIONS:
        raise ValueError("unknown action")
    row = _find(cid)
    if row["self"]:
        raise ValueError("the panel cannot control its own container")
    if action == "remove" and row["stack"]:
        raise ValueError("containers of the monitoring stack cannot be removed here")
    full = row["id"]
    if action == "remove":
        status, data = _request("DELETE", f"/containers/{full}?force=1", timeout=60)
    else:
        status, data = _request("POST", f"/containers/{full}/{action}" + ("?t=10" if action in ("stop", "restart") else ""), timeout=60)
    if status == 304:  # already in the requested state
        return {"ok": True, "unchanged": True}
    _json(status, data)
    return {"ok": True}


def _demux(data):
    """Docker multiplexes stdout/stderr into 8-byte-header frames unless the container has a TTY."""
    out, i = [], 0
    while i + 8 <= len(data) and data[i] in (0, 1, 2) and data[i + 1:i + 4] == b"\x00\x00\x00":
        size = int.from_bytes(data[i + 4:i + 8], "big")
        out.append(data[i + 8:i + 8 + size])
        i += 8 + size
    if i == 0:  # not framed (TTY container)
        return data.decode("utf-8", "replace")
    return b"".join(out).decode("utf-8", "replace")


def logs(cid, tail=200):
    _require()
    row = _find(cid)
    tail = max(1, min(int(tail), 2000))
    status, data = _request("GET", f"/containers/{row['id']}/logs?" + urlencode(
        {"stdout": 1, "stderr": 1, "tail": tail, "timestamps": 1}), timeout=30)
    if status != 200:
        _json(status, data)
    return {"name": row["name"], "text": _demux(data)[-200_000:]}


def _image_exists(image):
    status, _ = _request("GET", f"/images/{quote(image, safe='/:@')}/json", timeout=10)
    return status == 200


def pull(image):
    repo, tag = image, "latest"
    if "@" in image:
        repo, tag = image.split("@", 1)
    else:
        last = image.rsplit("/", 1)[-1]
        if ":" in last:
            repo, tag = image.rsplit(":", 1)
    status, data = _request("POST", "/images/create?" + urlencode({"fromImage": repo, "tag": tag}), timeout=900)
    if status != 200:
        _json(status, data)
    # The stream reports a failure as a JSON line with an "error" key and still returns HTTP 200.
    for line in data.decode("utf-8", "replace").splitlines():
        try:
            err = json.loads(line).get("error")
        except ValueError:
            continue
        if err:
            raise DockerError(err)


def run(spec):
    """Create and start a container. spec: image, name, ports[], env[], volumes[], restart."""
    _require()
    image = str(spec.get("image", "")).strip()
    name = str(spec.get("name", "")).strip()
    restart = str(spec.get("restart", "unless-stopped"))
    if not IMAGE_RE.match(image):
        raise ValueError("invalid image name")
    if name and not NAME_RE.match(name):
        raise ValueError("invalid container name (letters, digits, _ . - only)")
    if restart not in RESTART:
        raise ValueError("invalid restart policy")

    exposed, bindings = {}, {}
    for p in spec.get("ports") or []:
        m = PORT_RE.match(str(p).strip())
        if not m:
            raise ValueError(f"invalid port mapping: {p!r} (use HOST:CONTAINER, e.g. 8081:80)")
        ip, host, cont, proto = m.group(1), int(m.group(2)), int(m.group(3)), m.group(4) or "tcp"
        if not (1 <= host <= 65535 and 1 <= cont <= 65535):
            raise ValueError(f"port out of range: {p}")
        key = f"{cont}/{proto}"
        exposed[key] = {}
        bindings.setdefault(key, []).append({"HostIp": ip or "", "HostPort": str(host)})
    env = [str(e).strip() for e in spec.get("env") or [] if str(e).strip()]
    for e in env:
        if not ENV_RE.match(e):
            raise ValueError(f"invalid environment variable: {e.split('=')[0]!r} (use KEY=value)")
    binds = [str(v).strip() for v in spec.get("volumes") or [] if str(v).strip()]
    for v in binds:
        if not VOLUME_RE.match(v) or ".." in v:
            raise ValueError(f"invalid volume: {v!r} (use /host/path:/container/path[:ro])")
    if len(exposed) > 50 or len(env) > 100 or len(binds) > 50:
        raise ValueError("too many ports, variables or volumes")

    if not _image_exists(image):
        pull(image)
    body = {"Image": image, "Env": env, "ExposedPorts": exposed,
            "Labels": {"managed-by": "server-monitor-panel"},
            "HostConfig": {"PortBindings": bindings, "Binds": binds, "RestartPolicy": {"Name": restart}}}
    query = "?" + urlencode({"name": name}) if name else ""
    created = _json(*_request("POST", f"/containers/create{query}", body, timeout=60))
    cid = created["Id"]
    status, data = _request("POST", f"/containers/{cid}/start", timeout=60)
    if status not in (204, 304):
        _request("DELETE", f"/containers/{cid}?force=1")  # don't leave a dead container behind
        _json(status, data)
    return {"ok": True, "id": cid[:12]}
__MONITORING_EOF__
  write_file panel/monitor.py 644 <<'__MONITORING_EOF__'
"""Read-only Prometheus queries behind the panel's dashboard pages. Only fixed queries are exposed."""
import json
import math
import os
import re
import time
from urllib.parse import urlencode
from urllib.request import urlopen

PROM = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090").rstrip("/")


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
VIRTUAL_NICS = 'device!~"lo|veth.*|docker.*|br-.*|virbr.*|cni.*|cali.*|flannel.*|ifb.*"'
REAL_FS = 'fstype!~"tmpfs|overlay|squashfs|devtmpfs|ramfs|fuse.*|nsfs|proc|sysfs|cgroup.*"'


def node_instances():
    return sorted({m.get("instance", "") for m, _ in vector('up{job="node"}')} - {""})


def node_selector(instance, net=False):
    """Label selector for one server. net=True also matches the node-net job (real NIC stats)."""
    if not instance:
        found = node_instances()
        instance = found[0] if found else ""
    if instance and not INSTANCE_RE.match(instance):
        raise ValueError("bad instance")
    job = 'job=~"node|node-net"' if net else 'job="node"'
    return f'{job},instance="{instance}"' if instance else job

# ------------------------------------------------------------------ api handlers

def api_instances(_q):
    rows = vector('up{job="node"}')
    names = {m.get("instance", ""): m.get("instance_name", "") for m, _ in rows}
    return {"instances": sorted(set(names) - {""}), "names": {k: v for k, v in names.items() if k and v}}


def api_overview(q):
    n = node_selector(q.get("instance"))
    nn = node_selector(q.get("instance"), net=True)
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
        "load": [scalar(f"node_load{p}{{{n}}}") for p in (1, 5, 15)],
        "net": {
            "rx": scalar(f"sum(rate(node_network_receive_bytes_total{{{nn},{VIRTUAL_NICS}}}[2m]))"),
            "tx": scalar(f"sum(rate(node_network_transmit_bytes_total{{{nn},{VIRTUAL_NICS}}}[2m]))"),
        },
        "containers": scalar(f"count(container_memory_working_set_bytes{{{CG_DOCKER}}})") or 0,
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


def net_exporter_status():
    """State of the node-net scrape target, so the UI can explain an empty network table."""
    for t in prom_get("/api/v1/targets", {"state": "active"})["activeTargets"]:
        if t["labels"].get("job") == "node-net":
            return {"present": True, "up": t["health"] != "down", "error": t.get("lastError", "")}
    return {"present": False, "up": False, "error": ""}


def api_network(q):
    n = node_selector(q.get("instance"), net=True)
    # Rows come from the counters so cards show up immediately; rates need ~30s of samples.
    rx_total = by_label(f"node_network_receive_bytes_total{{{n},{VIRTUAL_NICS}}}", "device")
    tx_total = by_label(f"node_network_transmit_bytes_total{{{n},{VIRTUAL_NICS}}}", "device")
    up = by_label(f"node_network_up{{{n},{VIRTUAL_NICS}}}", "device")
    rx = by_label(f"rate(node_network_receive_bytes_total{{{n},{VIRTUAL_NICS}}}[2m])", "device")
    tx = by_label(f"rate(node_network_transmit_bytes_total{{{n},{VIRTUAL_NICS}}}[2m])", "device")
    speed = by_label(f"node_network_speed_bytes{{{n},{VIRTUAL_NICS}}}", "device")
    rows = [{"device": d, "up": up.get(d) == 1 if d in up else True, "rx": rx.get(d), "tx": tx.get(d),
             "rx_total": rx_total.get(d), "tx_total": tx_total.get(d),
             "speed": speed.get(d) if (speed.get(d) or 0) > 0 else None}
            for d in sorted(set(rx_total) | set(tx_total) | set(up))]
    out = {"rows": rows}
    if not rows:
        out["exporter"] = net_exporter_status()
    return out


# cAdvisor's `name` label is missing on many Docker setups (containerd image store, cgroup v2), but the
# `id` label always carries the 64-hex container id inside the cgroup path, so containers are matched by id.
CG_DOCKER = r'id=~".*docker[-/][a-f0-9]{64}(\\.scope)?"'
_CONTAINER_ID = re.compile(r"docker[-/]([a-f0-9]{64})")


def _per_container(expr):
    out = {}
    for m, v in vector(expr):
        hit = _CONTAINER_ID.search(m.get("id", ""))
        if hit:
            out[hit.group(1)[:12]] = (m.get("name", ""), v)
    return out


def container_metrics():
    """CPU / memory / start time per container, keyed by the short (12 char) container id."""
    cpu = _per_container(f"sum by (id, name) (rate(container_cpu_usage_seconds_total{{{CG_DOCKER}}}[2m])) * 100")
    mem = _per_container(f"sum by (id, name) (container_memory_working_set_bytes{{{CG_DOCKER}}})")
    started = _per_container(f"max by (id, name) (container_start_time_seconds{{{CG_DOCKER}}})")
    return {cid: {"name": name, "cpu": cpu.get(cid, ("", None))[1], "mem": value, "started": started.get(cid, ("", None))[1]}
            for cid, (name, value) in mem.items()}


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
    nn = node_selector(q.get("instance"), net=True)
    span = RANGES.get(q.get("range", "1h"), 3600)
    queries = {
        "cpu": [("CPU", f'100 - avg(rate(node_cpu_seconds_total{{{n},mode="idle"}}[2m])) * 100')],
        "mem": [("Memory", f"(1 - node_memory_MemAvailable_bytes{{{n}}} / node_memory_MemTotal_bytes{{{n}}}) * 100")],
        "load": [(f"{p}m", f"node_load{p}{{{n}}}") for p in (1, 5, 15)],
        "net": [("rx", f"sum(rate(node_network_receive_bytes_total{{{nn},{VIRTUAL_NICS}}}[2m]))"),
                ("tx", f"sum(rate(node_network_transmit_bytes_total{{{nn},{VIRTUAL_NICS}}}[2m]))")],
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


READ_API = {"/api/instances": api_instances, "/api/overview": api_overview, "/api/disks": api_disks,
            "/api/network": api_network, "/api/websites": api_websites,
            "/api/targets": api_targets, "/api/alerts": api_alerts, "/api/history": api_history}
__MONITORING_EOF__
  write_file panel/icons.py 644 <<'__MONITORING_EOF__'
"""Renders the panel icon (shield with a pulse line) as PNG / ICO using only the standard library.

Browsers differ in which icon format they pick up (SVG, /favicon.ico, PNG, Apple touch icon), so the
panel serves all of them, generated here once and cached.
"""
import math
import struct
import zlib

BG = (14, 21, 32)      # card colour
FG = (46, 230, 166)    # accent colour

# Shapes in unit coordinates (0..1).
SHIELD = [(0.5, 0.15), (0.80, 0.27), (0.80, 0.52), (0.5, 0.85), (0.20, 0.52), (0.20, 0.27), (0.5, 0.15)]
PULSE = [(0.29, 0.50), (0.42, 0.50), (0.50, 0.34), (0.58, 0.64), (0.66, 0.50), (0.71, 0.50)]
_cache = {}


def _dist_to_segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    length2 = dx * dx + dy * dy
    t = 0.0 if length2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length2))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(px - cx, py - cy)


def _in_rounded_square(x, y, size, radius):
    half = size / 2
    qx, qy = abs(x - half) - (half - radius), abs(y - half) - (half - radius)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) <= radius


def _png(size, rows):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def png(size):
    """RGBA PNG of the icon at size x size pixels."""
    if size in _cache:
        return _cache[size]
    ss = 4 if size <= 64 else 2                      # supersampling factor for smooth edges
    stroke = max(1.2, size * 0.075)
    pulse_stroke = max(1.0, size * 0.06)
    shield = [(x * size, y * size) for x, y in SHIELD]
    pulse = [(x * size, y * size) for x, y in PULSE]
    radius = size * 0.22
    rows = []
    for py in range(size):
        row = bytearray()
        for px in range(size):
            r = g = b = a = 0
            for sy in range(ss):
                for sx in range(ss):
                    x, y = px + (sx + 0.5) / ss, py + (sy + 0.5) / ss
                    if not _in_rounded_square(x, y, size, radius):
                        continue
                    on_shield = any(_dist_to_segment(x, y, *shield[i], *shield[i + 1]) <= stroke / 2 for i in range(len(shield) - 1))
                    on_pulse = any(_dist_to_segment(x, y, *pulse[i], *pulse[i + 1]) <= pulse_stroke / 2 for i in range(len(pulse) - 1))
                    colour = FG if (on_shield or on_pulse) else BG
                    r, g, b, a = r + colour[0], g + colour[1], b + colour[2], a + 1
            total = ss * ss
            if a:
                row += bytes((r // a, g // a, b // a, round(255 * a / total)))
            else:
                row += b"\x00\x00\x00\x00"
        rows.append(row)
    _cache[size] = _png(size, rows)
    return _cache[size]


def ico():
    """A .ico wrapping a 32x32 PNG (supported by every current browser)."""
    data = png(32)
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack("<BBBBHHII", 32, 32, 0, 0, 1, 32, len(data), 22)
    return header + entry + data
__MONITORING_EOF__
  write_file panel/static/index.html 644 <<'__MONITORING_EOF__'
<!doctype html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Server Monitor</title>
  <link rel="icon" href="data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%2032%2032%22%3E%3Crect%20width=%2232%22%20height=%2232%22%20rx=%228%22%20fill=%22%230e1520%22/%3E%3Cpath%20d=%22M16%205l9%203.5v7c0%205.4-3.7%209.2-9%2011.5-5.3-2.3-9-6.1-9-11.5v-7L16%205z%22%20fill=%22none%22%20stroke=%22%232ee6a6%22%20stroke-width=%222%22%20stroke-linejoin=%22round%22/%3E%3Cpath%20d=%22M10.5%2016h3l2-3.5%202.5%207%202-3.5h1.5%22%20fill=%22none%22%20stroke=%22%232ee6a6%22%20stroke-width=%221.8%22%20stroke-linecap=%22round%22%20stroke-linejoin=%22round%22/%3E%3C/svg%3E" type="image/svg+xml">
  <link rel="icon" href="/favicon-32.png" type="image/png" sizes="32x32">
  <link rel="shortcut icon" href="/favicon.ico">
  <link rel="apple-touch-icon" href="/apple-touch-icon.png">
  <meta name="theme-color" content="#0a0f16">
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
        <button class="btn danger" id="logout" type="button"></button>
      </div>
    </header>

    <div id="banner"></div>
    <section class="stats" id="stats" aria-live="polite"></section>

    <div class="layout">
      <aside class="card side">
        <h2 data-i18n="monitors">Monitors</h2>
        <nav class="nav" id="nav"></nav>
        <h2 class="second" data-i18n="manage">Manage</h2>
        <nav class="nav" id="nav-manage"></nav>
      </aside>
      <main class="card panel" id="panel"></main>
    </div>
    <div class="foot" id="foot"></div>
    <div class="toasts" id="toasts" aria-live="polite"></div>
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
  <link rel="icon" href="data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%2032%2032%22%3E%3Crect%20width=%2232%22%20height=%2232%22%20rx=%228%22%20fill=%22%230e1520%22/%3E%3Cpath%20d=%22M16%205l9%203.5v7c0%205.4-3.7%209.2-9%2011.5-5.3-2.3-9-6.1-9-11.5v-7L16%205z%22%20fill=%22none%22%20stroke=%22%232ee6a6%22%20stroke-width=%222%22%20stroke-linejoin=%22round%22/%3E%3Cpath%20d=%22M10.5%2016h3l2-3.5%202.5%207%202-3.5h1.5%22%20fill=%22none%22%20stroke=%22%232ee6a6%22%20stroke-width=%221.8%22%20stroke-linecap=%22round%22%20stroke-linejoin=%22round%22/%3E%3C/svg%3E" type="image/svg+xml">
  <link rel="icon" href="/favicon-32.png" type="image/png" sizes="32x32">
  <link rel="shortcut icon" href="/favicon.ico">
  <link rel="apple-touch-icon" href="/apple-touch-icon.png">
  <meta name="theme-color" content="#0a0f16">
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
      title: "Server Monitor", monitors: "Monitors", manage: "Manage", refresh: "Refresh", logout: "Logout",
      lang_switch: "فارسی", host: "Host",
      cpu: "CPU", memory: "Memory", disk: "Disk", load: "Load average",
      net_down: "Network in", net_up: "Network out", containers: "Containers", targets: "Targets up",
      websites: "Checks up", ssl: "SSL expires in", alerts: "Firing alerts", cores: "cores", of: "of", days: "days", running: "running",
      overview: "Overview", containers_nav: "Containers", websites_nav: "Websites", disks: "Disks", network: "Network",
      targets_nav: "Targets", alerts_nav: "Alerts", servers_nav: "Servers", notifications_nav: "Notifications",
      rules_nav: "Alert rules", settings_nav: "Settings",
      d_overview: "Live resource usage of the selected server. Charts update automatically.",
      d_containers: "Every Docker container on this server. Start, stop, restart, read logs or create new ones.",
      d_websites: "Websites and TCP ports that are checked for uptime, response time and SSL expiry. Add or remove them here.",
      d_disks: "Mounted filesystems and how full they are.",
      d_network: "Traffic on the physical network interfaces (virtual and Docker interfaces are hidden).",
      d_servers: "The servers whose CPU, memory, disk and network are monitored. Add another server to watch it too.",
      d_notifications: "Where alerts are sent. Connect a Telegram bot to get a message when something goes wrong.",
      d_rules: "When an alert fires. Change the thresholds, switch rules off, or restore the defaults.",
      d_settings: "Panel password, Docker control and information about this installation.",
      nx_nodata: "No network interface data yet. Rates need about 30 seconds of samples; if this stays empty, check the Targets tab.",
      nx_nojob: "The node-net exporter is not in Prometheus. Re-run install.sh, or run: docker compose up -d && docker compose restart panel prometheus",
      nx_down: "The node-net exporter is down, so network cards cannot be read. Error:",
      d_targets: "Everything Prometheus scrapes. A target that is down means its metrics are missing.",
      d_alerts: "Alerts that are firing or about to fire. Change when they fire on the Alert rules page.",
      server: "Server", range: "Range", r1h: "Last hour", r6h: "Last 6 hours", r24h: "Last 24 hours", r7d: "Last 7 days",
      c_cpu: "CPU usage", c_mem: "Memory usage", c_net: "Network traffic", c_load: "Load average",
      rx: "in", tx: "out", no_data: "No data yet", empty: "Nothing to show yet.",
      name: "Name", cpu_h: "CPU", mem_h: "Memory", uptime_h: "Uptime", status: "Status", target: "Target", type: "Type",
      response: "Response", http: "HTTP", ssl_h: "SSL days left", mount: "Mount", device: "Device", fs: "Filesystem",
      usage: "Usage", used_total: "Used / Total", iface: "Interface", speed: "Link speed", rate_in: "In", rate_out: "Out", total_in: "Total in", total_out: "Total out",
      job: "Job", instance: "Instance", scrape: "Scrape time", error: "Error", severity: "Severity", alert: "Alert", summary: "Summary", state: "State", since: "Since",
      s_running: "Running", s_up: "Up", s_down: "Down", s_firing: "Firing", s_pending: "Pending", s_exited: "Stopped", s_paused: "Paused", s_created: "Created", s_restarting: "Restarting",
      no_alerts: "No active alerts. Everything looks healthy.", host_online: "Host online",
      err_api: "Cannot load data", last_update: "Last update", auto: "auto-refresh every 10s", ago: "ago",
      t_dark: "Switch to light theme", t_light: "Switch to dark theme",
      // generic UI
      add: "Add", cancel: "Cancel", close: "Close", save: "Save", saved: "Saved", remove: "Remove", working: "Working…", copy: "Copy", copied: "Copied",
      confirm: "Please confirm", actions: "Actions", minutes: "min", added: "Added", removed: "Removed", reset_defaults: "Restore defaults",
      // containers
      image: "Image", ports: "Ports", a_start: "Start", a_stop: "Stop", a_restart: "Restart", a_logs: "Logs", a_remove: "Remove",
      c_stack: "stack", c_self: "this panel", c_docker_off: "Container control is off, so this list is read-only (from cAdvisor). Enable it by mounting the Docker socket (see Settings).",
      c_add: "Add container", c_added: "Container created and started", c_done: "Done",
      c_confirm_remove: "Remove container \"{n}\"? It is deleted (its data volumes are kept).", c_confirm_stop: "Stop container \"{n}\"?", c_confirm_restart: "Restart container \"{n}\"?",
      logs_title: "Logs", lines: "lines", f_image: "Image", f_image_hint: "For example nginx:alpine or ghcr.io/org/app:1.2. It is downloaded if missing.",
      f_cname: "Container name (optional)", f_ports: "Port mappings (one per line)", f_ports_hint: "HOST:CONTAINER, for example 8081:80 (add /udp for UDP).",
      f_env: "Environment variables (one per line)", f_env_hint: "KEY=value", f_volumes: "Volumes (one per line)", f_volumes_hint: "/host/path:/container/path or /host/path:/container/path:ro",
      f_restart: "Restart policy", rp_no: "Never", rp_unless: "Unless stopped (recommended)", rp_always: "Always", rp_failure: "On failure",
      pulling_hint: "Creating… downloading a new image can take a few minutes.",
      // websites + servers
      add_site: "Add website or port", type_http: "Website (HTTP / HTTPS)", type_tcp: "TCP port", f_target: "Address", f_name_opt: "Name (optional)",
      hint_http: "A full address, for example https://example.com", hint_tcp: "host:port, for example 203.0.113.10:22 (SSH) or db.internal:5432",
      probe: "Test now / why?", probe_title: "Check result", probe_running: "Checking now…", probe_ok: "This check passes from the server right now.",
      probe_fail: "This check fails from the server.", probe_reason: "Reason", probe_log: "Technical details", probe_status: "HTTP status",
      probe_k_reset: "The site (or the network in front of it) accepted the connection and then cut it off during the handshake. This is what a firewall or geo-block does: the site works for you but refuses this server's IP address.",
      probe_k_refused: "The server answered but nothing is listening on that port (or a firewall is actively rejecting it).",
      probe_k_dns: "The server cannot resolve this domain name. Check the spelling and the DNS settings of the server.",
      probe_k_timeout: "No answer in time. The host is down, or a firewall silently drops packets from this server.",
      probe_k_tls: "The site's certificate has a problem: expired, issued for another domain, or from an untrusted issuer.",
      probe_k_unreachable: "This server has no network route to the address.",
      probe_k_status: "The site answered but with an error status (4xx or 5xx), so it is not counted as healthy.",
      probe_k_other: "The check failed for another reason; see the technical details below.",
      probe_k_handshake: "The site rejected the secure connection during the TLS handshake. Usual causes: it only supports old TLS versions or ciphers, its certificate/SNI setup is broken, or its firewall refuses this server's IP address. The table below tries the alternatives for you.",
      v_legacy_tls: "Allow old TLS (1.0 / 1.1)", v_no_verify: "Ignore certificate errors", v_legacy_no_verify: "Old TLS and ignore certificate errors",
      v_plain_http: "Plain HTTP (no encryption)", v_tcp: "Only connect to the port (TCP)",
      diag_title: "What works from the server", diag_works: "Works", diag_fails: "Fails", diag_apply: "Monitor this site this way",
      diag_suggest: "The site passes in the mode marked below. Switch the check to it to monitor the site without false alarms.",
      diag_applied: "Check mode changed. The status updates within a minute.", mode_default: "standard",
      mode_legacy_tls: "old TLS", mode_no_verify: "no certificate check", mode_legacy_no_verify: "old TLS, no certificate check",
      diag_blocked: "The port accepts connections but every secure variant is rejected: the site or its firewall refuses this server specifically (typical for IP/geo blocking).",
      diag_plain: "Plain HTTP works, but every secure (HTTPS) attempt is rejected, whatever the TLS mode. The site is up; its HTTPS side refuses this server. You can monitor it over plain HTTP instead (the certificate expiry then cannot be checked).",
      diag_use_http: "Monitor over plain HTTP instead", diag_replaced: "Now monitoring the plain HTTP address.",
      diag_closed: "Even a plain TCP connection fails: the address is unreachable from this server (down, wrong port, or blocked).",
      probe_hint: "If the address opens in your browser but fails here, the server's IP is probably blocked by the site or its network (common for sites hosted in Iran when the monitoring server is abroad), or the server has no route to it. Monitoring shows what the server sees, not what you see.",
      s_wait: "Waiting", w_confirm_remove: "Stop monitoring {n}?", w_hint: "New entries show \"Waiting\" until the first check completes (about a minute).",
      add_server: "Add server", f_srv_addr: "Server address", f_srv_hint: "IP or hostname with the node_exporter port, for example 203.0.113.10:9100",
      srv_local: "this server", srv_confirm_remove: "Stop monitoring server {n}?",
      srv_help_title: "How to add another server",
      srv_help_1: "1. On the other server, run node_exporter (needs Docker):",
      srv_help_2: "2. Allow port 9100 only from this monitoring server in that server's firewall, for example:",
      srv_help_3: "3. Click \"Add server\" and enter its address as IP:9100.",
      // notifications
      tg_title: "Telegram", tg_ok: "Connected", tg_no: "Not configured", tg_bot: "Bot",
      tg_s1: "Open Telegram, talk to @BotFather, send /newbot and copy the token it gives you.",
      tg_s2: "Open your new bot and press Start (or add it to a group and write any message).",
      tg_s3: "Paste the token below and press \"Find chat ID\". Pick the chat, then Save.",
      tg_token: "Bot token", tg_token_saved: "Saved: {h} (leave empty to keep it)", tg_chat: "Chat ID", tg_find: "Find chat ID",
      tg_found: "Click a chat to use it:", tg_none: "No chats found yet. Send your bot a message in Telegram, then try again.",
      tg_test: "Send test message", tg_test_ok: "Test message sent. Check Telegram.", tg_saved: "Telegram saved. Alerts will be sent there.",
      tg_remove: "Disconnect", tg_confirm_remove: "Stop sending alerts to Telegram?", tg_removed: "Telegram disconnected",
      at_title: "Test the whole alert pipeline", at_text: "Fires a harmless test alert through Alertmanager. If Telegram is connected, the message arrives within about 30 seconds.",
      at_btn: "Send test alert", at_ok: "Test alert fired. Telegram gets it in about 30 seconds.",
      // rules
      rl_rule: "Rule", rl_enabled: "On", rl_threshold: "Threshold", rl_for: "Must last", rl_reset_confirm: "Restore every rule to its default threshold and switch all rules on?",
      rl_saved: "Rule saved and applied", rl_reset_ok: "Defaults restored",
      rd_InstanceDown: "A monitored target (server, exporter or checker) stopped responding.",
      rd_HighCpuUsage: "CPU usage stays above the threshold.",
      rd_HighMemoryUsage: "Memory usage stays above the threshold.",
      rd_DiskSpaceLow: "A disk is fuller than the threshold.",
      rd_DiskWillFillIn24h: "At the current rate a disk runs out of space within this many hours.",
      rd_HighLoad: "Load average per CPU core is above the threshold.",
      rd_HostRebooted: "A server restarted within this many seconds.",
      rd_ContainerHighCpu: "A container uses more CPU than the threshold.",
      rd_ContainerHighMemory: "A container uses more of its memory limit than the threshold.",
      rd_EndpointDown: "A website or port check fails.",
      rd_SslCertExpiringSoon: "An SSL certificate expires in fewer days than the threshold.",
      rd_SlowEndpoint: "A website needs longer than this to respond.",
      // settings
      st_pw_title: "Change login", st_user: "Username", st_current: "Current password", st_new: "New password (8+ characters)", st_repeat: "Repeat new password",
      st_change: "Change login", st_mismatch: "The two passwords do not match", st_pw_ok: "Login changed. Other devices are signed out.",
      st_docker_title: "Docker control", st_docker_on: "Enabled", st_docker_off: "Off",
      st_docker_hint_on: "The panel can start, stop, create and remove containers through the Docker socket. Anyone who signs in here can control the whole server, so keep the password strong and put HTTPS in front of the panel.",
      st_docker_hint_off: "The panel only reads container metrics. To enable control, make sure the docker.sock mount in docker-compose.yml is present and PANEL_DOCKER_CONTROL is not 0, then run: docker compose up -d",
      st_docker_unavail: "Enabled in settings, but the Docker socket is not reachable.",
      st_about: "About", st_version: "Panel version",
    },
    fa: {
      title: "مانیتورینگ سرور", monitors: "مانیتورها", manage: "مدیریت", refresh: "بروزرسانی", logout: "خروج",
      lang_switch: "English", host: "سرور",
      cpu: "پردازنده", memory: "حافظه (رم)", disk: "دیسک", load: "میانگین بار",
      net_down: "دریافت شبکه", net_up: "ارسال شبکه", containers: "کانتینرها", targets: "تارگت‌های فعال",
      websites: "چک‌های سالم", ssl: "انقضای SSL", alerts: "هشدارهای فعال", cores: "هسته", of: "از", days: "روز", running: "در حال اجرا",
      overview: "نمای کلی", containers_nav: "کانتینرها", websites_nav: "سایت‌ها", disks: "دیسک‌ها", network: "شبکه",
      targets_nav: "تارگت‌ها", alerts_nav: "هشدارها", servers_nav: "سرورها", notifications_nav: "اعلان‌ها",
      rules_nav: "قوانین هشدار", settings_nav: "تنظیمات",
      d_overview: "مصرف زنده‌ی منابع سرور انتخاب‌شده. نمودارها خودکار بروز می‌شوند.",
      d_containers: "همه‌ی کانتینرهای داکر این سرور. شروع، توقف، ری‌استارت، دیدن لاگ یا ساخت کانتینر جدید.",
      d_websites: "سایت‌ها و پورت‌های TCP که آپتایم، زمان پاسخ و انقضای SSL‌شان چک می‌شود. از اینجا اضافه یا حذف کنید.",
      d_disks: "فایل‌سیستم‌های مونت‌شده و میزان پر بودن هرکدام.",
      d_network: "ترافیک کارت‌شبکه‌های واقعی (کارت‌های مجازی و داکر پنهان هستند).",
      d_servers: "سرورهایی که پردازنده، رم، دیسک و شبکه‌شان مانیتور می‌شود. برای نظارت بر سرور دیگر، آن را اضافه کنید.",
      d_notifications: "هشدارها کجا فرستاده شوند. یک ربات تلگرام وصل کنید تا هر مشکلی پیام بگیرید.",
      d_rules: "هشدار چه زمانی فعال شود. آستانه‌ها را عوض کنید، قانونی را خاموش کنید یا پیش‌فرض‌ها را برگردانید.",
      d_settings: "رمز پنل، کنترل داکر و اطلاعات این نصب.",
      nx_nodata: "هنوز داده‌ی کارت شبکه نرسیده. نرخ‌ها حدود ۳۰ ثانیه داده می‌خواهند؛ اگر خالی ماند تب تارگت‌ها را ببینید.",
      nx_nojob: "اکسپورتر node-net در Prometheus نیست. install.sh را دوباره اجرا کنید یا بزنید: docker compose up -d && docker compose restart panel prometheus",
      nx_down: "اکسپورتر node-net قطع است و کارت‌های شبکه خوانده نمی‌شوند. خطا:",
      d_targets: "همه‌ی چیزهایی که Prometheus از آن‌ها متریک می‌گیرد. تارگت قطع یعنی متریکش را نداریم.",
      d_alerts: "هشدارهایی که فعال هستند یا در شرف فعال شدن‌اند. زمان فعال شدنشان را در صفحه‌ی قوانین هشدار عوض کنید.",
      server: "سرور", range: "بازه", r1h: "یک ساعت اخیر", r6h: "۶ ساعت اخیر", r24h: "۲۴ ساعت اخیر", r7d: "۷ روز اخیر",
      c_cpu: "مصرف پردازنده", c_mem: "مصرف حافظه", c_net: "ترافیک شبکه", c_load: "میانگین بار",
      rx: "دریافت", tx: "ارسال", no_data: "هنوز داده‌ای نیست", empty: "هنوز چیزی برای نمایش نیست.",
      name: "نام", cpu_h: "پردازنده", mem_h: "حافظه", uptime_h: "مدت اجرا", status: "وضعیت", target: "مقصد", type: "نوع",
      response: "پاسخ", http: "HTTP", ssl_h: "روز تا انقضای SSL", mount: "مسیر", device: "دستگاه", fs: "فایل‌سیستم",
      usage: "مصرف", used_total: "مصرف / کل", iface: "کارت شبکه", speed: "سرعت لینک", rate_in: "دریافت", rate_out: "ارسال", total_in: "کل دریافت", total_out: "کل ارسال",
      job: "گروه", instance: "نمونه", scrape: "زمان جمع‌آوری", error: "خطا", severity: "شدت", alert: "هشدار", summary: "خلاصه", state: "حالت", since: "از",
      s_running: "در حال اجرا", s_up: "فعال", s_down: "قطع", s_firing: "فعال", s_pending: "در انتظار", s_exited: "متوقف", s_paused: "مکث", s_created: "ساخته‌شده", s_restarting: "در حال ری‌استارت",
      no_alerts: "هشدار فعالی وجود ندارد. همه چیز سالم است.", host_online: "سرور آنلاین است",
      err_api: "داده‌ها بارگذاری نشد", last_update: "آخرین بروزرسانی", auto: "بروزرسانی خودکار هر ۱۰ ثانیه", ago: "پیش",
      t_dark: "تم روشن", t_light: "تم تیره",
      add: "افزودن", cancel: "انصراف", close: "بستن", save: "ذخیره", saved: "ذخیره شد", remove: "حذف", working: "در حال انجام…", copy: "کپی", copied: "کپی شد",
      confirm: "لطفاً تأیید کنید", actions: "عملیات", minutes: "دقیقه", added: "اضافه شد", removed: "حذف شد", reset_defaults: "بازگشت به پیش‌فرض",
      image: "ایمیج", ports: "پورت‌ها", a_start: "شروع", a_stop: "توقف", a_restart: "ری‌استارت", a_logs: "لاگ", a_remove: "حذف",
      c_stack: "استک", c_self: "همین پنل", c_docker_off: "کنترل کانتینر خاموش است، پس این فهرست فقط‌خواندنی است (از cAdvisor). برای فعال‌سازی سوکت داکر را مونت کنید (تنظیمات را ببینید).",
      c_add: "افزودن کانتینر", c_added: "کانتینر ساخته و اجرا شد", c_done: "انجام شد",
      c_confirm_remove: "کانتینر «{n}» حذف شود؟ خود کانتینر پاک می‌شود (ولیوم‌های داده می‌مانند).", c_confirm_stop: "کانتینر «{n}» متوقف شود؟", c_confirm_restart: "کانتینر «{n}» ری‌استارت شود؟",
      logs_title: "لاگ", lines: "خط", f_image: "ایمیج", f_image_hint: "مثلاً nginx:alpine یا ghcr.io/org/app:1.2. اگر روی سرور نباشد دانلود می‌شود.",
      f_cname: "نام کانتینر (اختیاری)", f_ports: "پورت‌ها (هر خط یکی)", f_ports_hint: "HOST:CONTAINER مثل 8081:80 (برای UDP بنویسید /udp).",
      f_env: "متغیرهای محیطی (هر خط یکی)", f_env_hint: "KEY=value", f_volumes: "ولیوم‌ها (هر خط یکی)", f_volumes_hint: "/host/path:/container/path یا /host/path:/container/path:ro",
      f_restart: "سیاست ری‌استارت", rp_no: "هرگز", rp_unless: "مگر دستی متوقف شود (پیشنهادی)", rp_always: "همیشه", rp_failure: "فقط با خطا",
      pulling_hint: "در حال ساخت… دانلود ایمیج جدید ممکن است چند دقیقه طول بکشد.",
      add_site: "افزودن سایت یا پورت", type_http: "سایت (HTTP / HTTPS)", type_tcp: "پورت TCP", f_target: "آدرس", f_name_opt: "نام (اختیاری)",
      hint_http: "آدرس کامل، مثلاً https://example.com", hint_tcp: "host:port مثل 203.0.113.10:22 (SSH) یا db.internal:5432",
      probe: "آزمایش الان / چرا؟", probe_title: "نتیجه‌ی چک", probe_running: "در حال چک کردن…", probe_ok: "این چک همین الان از سرور موفق است.",
      probe_fail: "این چک از سرور ناموفق است.", probe_reason: "دلیل", probe_log: "جزئیات فنی", probe_status: "کد HTTP",
      probe_k_reset: "سایت (یا شبکه‌ی جلوی آن) اتصال را پذیرفت و وسط handshake قطعش کرد. این رفتار فایروال یا مسدودسازی جغرافیایی است: سایت برای شما باز می‌شود ولی IP این سرور را رد می‌کند.",
      probe_k_refused: "سرور پاسخ داد ولی روی آن پورت چیزی گوش نمی‌دهد (یا فایروال فعالانه رد می‌کند).",
      probe_k_dns: "سرور نمی‌تواند این نام دامنه را پیدا کند. املا و تنظیمات DNS سرور را بررسی کنید.",
      probe_k_timeout: "در زمان مقرر پاسخی نیامد. میزبان خاموش است یا فایروال بی‌صدا بسته‌های این سرور را دور می‌اندازد.",
      probe_k_tls: "گواهی سایت مشکل دارد: منقضی‌شده، برای دامنه‌ی دیگر یا از مرجع نامعتبر.",
      probe_k_unreachable: "این سرور مسیر شبکه‌ای به این آدرس ندارد.",
      probe_k_status: "سایت پاسخ داد ولی با کد خطا (4xx یا 5xx)، پس سالم حساب نمی‌شود.",
      probe_k_other: "چک به دلیل دیگری ناموفق بود؛ جزئیات فنی پایین را ببینید.",
      probe_k_handshake: "سایت اتصال امن را در مرحله‌ی TLS handshake رد کرد. علت‌های معمول: فقط نسخه‌ها یا رمزهای قدیمی TLS را می‌پذیرد، تنظیم گواهی/SNI خراب است، یا فایروالش IP این سرور را رد می‌کند. جدول پایین گزینه‌های جایگزین را برایتان امتحان می‌کند.",
      v_legacy_tls: "پذیرش TLS قدیمی (۱.۰ / ۱.۱)", v_no_verify: "نادیده گرفتن خطای گواهی", v_legacy_no_verify: "TLS قدیمی و نادیده گرفتن خطای گواهی",
      v_plain_http: "HTTP ساده (بدون رمزنگاری)", v_tcp: "فقط اتصال به پورت (TCP)",
      diag_title: "چه چیزی از سرور کار می‌کند", diag_works: "کار می‌کند", diag_fails: "ناموفق", diag_apply: "مانیتور سایت با این حالت",
      diag_suggest: "سایت در حالتی که پایین علامت خورده موفق است. چک را روی آن بگذارید تا بدون هشدار اشتباه مانیتور شود.",
      diag_applied: "حالت چک عوض شد. وضعیت تا یک دقیقه‌ی دیگر بروز می‌شود.", mode_default: "استاندارد",
      mode_legacy_tls: "TLS قدیمی", mode_no_verify: "بدون بررسی گواهی", mode_legacy_no_verify: "TLS قدیمی، بدون بررسی گواهی",
      diag_blocked: "پورت اتصال را می‌پذیرد ولی همه‌ی حالت‌های امن رد می‌شوند: سایت یا فایروالش مشخصاً این سرور را رد می‌کند (معمول در مسدودسازی IP یا جغرافیایی).",
      diag_plain: "HTTP ساده کار می‌کند ولی هر تلاش امن (HTTPS) با هر حالت TLS رد می‌شود. سایت بالاست؛ بخش HTTPS آن این سرور را رد می‌کند. می‌توانید به‌جای آن روی HTTP ساده مانیتورش کنید (تاریخ انقضای گواهی دیگر چک نمی‌شود).",
      diag_use_http: "مانیتور روی HTTP ساده", diag_replaced: "حالا آدرس HTTP ساده مانیتور می‌شود.",
      diag_closed: "حتی اتصال ساده‌ی TCP هم ناموفق است: آدرس از این سرور در دسترس نیست (خاموش، پورت اشتباه یا مسدود).",
      probe_hint: "اگر آدرس در مرورگر شما باز می‌شود ولی اینجا ناموفق است، احتمالاً IP سرور توسط سایت یا شبکه‌اش مسدود است (برای سایت‌های میزبانی‌شده در ایران وقتی سرور مانیتورینگ خارج از ایران است رایج است) یا سرور مسیری به آن ندارد. مانیتورینگ همان چیزی را نشان می‌دهد که «سرور» می‌بیند، نه آنچه شما می‌بینید.",
      s_wait: "در انتظار", w_confirm_remove: "نظارت بر {n} متوقف شود؟", w_hint: "موارد جدید تا تکمیل اولین چک (حدود یک دقیقه) «در انتظار» نشان داده می‌شوند.",
      add_server: "افزودن سرور", f_srv_addr: "آدرس سرور", f_srv_hint: "آی‌پی یا نام سرور همراه پورت node_exporter، مثل 203.0.113.10:9100",
      srv_local: "همین سرور", srv_confirm_remove: "نظارت بر سرور {n} متوقف شود؟",
      srv_help_title: "چطور سرور دیگری را اضافه کنم",
      srv_help_1: "۱. روی سرور دیگر node_exporter را اجرا کنید (داکر لازم است):",
      srv_help_2: "۲. پورت 9100 را فقط برای همین سرور مانیتورینگ در فایروال آن سرور باز کنید، مثلاً:",
      srv_help_3: "۳. روی «افزودن سرور» بزنید و آدرسش را به شکل IP:9100 وارد کنید.",
      tg_title: "تلگرام", tg_ok: "متصل", tg_no: "تنظیم نشده", tg_bot: "ربات",
      tg_s1: "تلگرام را باز کنید، با @BotFather صحبت کنید، /newbot را بفرستید و توکنی که می‌دهد را کپی کنید.",
      tg_s2: "ربات جدیدتان را باز کنید و Start بزنید (یا آن را به گروه اضافه کنید و یک پیام بنویسید).",
      tg_s3: "توکن را پایین بچسبانید و «پیدا کردن Chat ID» را بزنید. چت را انتخاب کنید و ذخیره کنید.",
      tg_token: "توکن ربات", tg_token_saved: "ذخیره‌شده: {h} (برای نگه داشتن خالی بگذارید)", tg_chat: "Chat ID", tg_find: "پیدا کردن Chat ID",
      tg_found: "برای انتخاب روی یک چت بزنید:", tg_none: "هنوز چتی پیدا نشد. در تلگرام به ربات پیام بدهید و دوباره تلاش کنید.",
      tg_test: "ارسال پیام آزمایشی", tg_test_ok: "پیام آزمایشی فرستاده شد. تلگرام را ببینید.", tg_saved: "تلگرام ذخیره شد. هشدارها به آنجا می‌روند.",
      tg_remove: "قطع اتصال", tg_confirm_remove: "ارسال هشدار به تلگرام متوقف شود؟", tg_removed: "اتصال تلگرام قطع شد",
      at_title: "آزمایش کل مسیر هشدار", at_text: "یک هشدار آزمایشی بی‌خطر را از طریق Alertmanager می‌فرستد. اگر تلگرام وصل باشد، پیام تا حدود ۳۰ ثانیه می‌رسد.",
      at_btn: "ارسال هشدار آزمایشی", at_ok: "هشدار آزمایشی ارسال شد. تلگرام تا حدود ۳۰ ثانیه دیگر پیام می‌گیرد.",
      rl_rule: "قانون", rl_enabled: "روشن", rl_threshold: "آستانه", rl_for: "مدت پایداری", rl_reset_confirm: "همه‌ی قانون‌ها به آستانه‌ی پیش‌فرض برگردند و روشن شوند؟",
      rl_saved: "قانون ذخیره و اعمال شد", rl_reset_ok: "پیش‌فرض‌ها برگشتند",
      rd_InstanceDown: "یکی از تارگت‌ها (سرور، اکسپورتر یا چک‌کننده) پاسخ نمی‌دهد.",
      rd_HighCpuUsage: "مصرف پردازنده مدتی بالاتر از آستانه می‌ماند.",
      rd_HighMemoryUsage: "مصرف رم مدتی بالاتر از آستانه می‌ماند.",
      rd_DiskSpaceLow: "یک دیسک بیشتر از آستانه پر شده است.",
      rd_DiskWillFillIn24h: "با روند فعلی، یک دیسک تا این تعداد ساعت دیگر پر می‌شود.",
      rd_HighLoad: "میانگین بار به ازای هر هسته بالاتر از آستانه است.",
      rd_HostRebooted: "یک سرور در این تعداد ثانیه‌ی اخیر ری‌استارت شده است.",
      rd_ContainerHighCpu: "یک کانتینر بیشتر از آستانه پردازنده مصرف می‌کند.",
      rd_ContainerHighMemory: "یک کانتینر بیشتر از آستانه‌ی سقف رم خودش مصرف می‌کند.",
      rd_EndpointDown: "چک یک سایت یا پورت ناموفق است.",
      rd_SslCertExpiringSoon: "گواهی SSL کمتر از این تعداد روز اعتبار دارد.",
      rd_SlowEndpoint: "پاسخ یک سایت بیشتر از این زمان طول می‌کشد.",
      st_pw_title: "تغییر اطلاعات ورود", st_user: "نام کاربری", st_current: "رمز فعلی", st_new: "رمز جدید (حداقل ۸ نویسه)", st_repeat: "تکرار رمز جدید",
      st_change: "تغییر اطلاعات ورود", st_mismatch: "دو رمز یکسان نیستند", st_pw_ok: "اطلاعات ورود عوض شد. دستگاه‌های دیگر خارج شدند.",
      st_docker_title: "کنترل داکر", st_docker_on: "فعال", st_docker_off: "خاموش",
      st_docker_hint_on: "پنل می‌تواند از طریق سوکت داکر کانتینر شروع، متوقف، بسازد و حذف کند. هر کسی که اینجا وارد شود کنترل کل سرور را دارد؛ پس رمز قوی بگذارید و جلوی پنل HTTPS قرار دهید.",
      st_docker_hint_off: "پنل فقط متریک کانتینرها را می‌خواند. برای فعال‌سازی، مطمئن شوید مونت docker.sock در docker-compose.yml هست و PANEL_DOCKER_CONTROL برابر 0 نیست، سپس بزنید: docker compose up -d",
      st_docker_unavail: "در تنظیمات فعال است ولی سوکت داکر در دسترس نیست.",
      st_about: "درباره", st_version: "نسخه‌ی پنل",
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
    names: {},
    view: "overview",
    overview: null,
    settings: null,
    renderId: 0,
  };
  const t = (k, vars) => {
    let s = T[state.lang][k] ?? T.en[k] ?? k;
    if (vars) for (const [a, b] of Object.entries(vars)) s = s.replace(`{${a}}`, b);
    return s;
  };

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
    logout: '<path d="M9 4H5a1 1 0 00-1 1v14a1 1 0 001 1h4M16 8l4 4-4 4M20 12H9"/>',
    cpu: '<rect x="5" y="5" width="14" height="14" rx="2"/><rect x="9" y="9" width="6" height="6"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/>',
    memory: '<rect x="2" y="7" width="20" height="10" rx="2"/><path d="M6 11v2M10 11v2M14 11v2M18 11v2M6 17v2M10 17v2M14 17v2M18 17v2"/>',
    disk: '<ellipse cx="12" cy="5" rx="8" ry="3"/><path d="M4 5v14c0 1.7 3.6 3 8 3s8-1.3 8-3V5M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3"/>',
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
    okmark: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 12a1 1 0 001 1h8a1 1 0 001-1l1-12M9 7V4h6v3"/>',
    play: '<path d="M7 4.5v15l12-7.5-12-7.5z"/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="2"/>',
    file: '<path d="M14 3H7a1 1 0 00-1 1v16a1 1 0 001 1h10a1 1 0 001-1V8l-4-5z"/><path d="M14 3v5h5M9 13h6M9 17h6"/>',
    send: '<path d="M21 3L10 14M21 3l-7 18-4-7-7-4 18-7z"/>',
    sliders: '<path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M4.9 19.1L7 17M17 7l2.1-2.1"/>',
    search: '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l5 5"/>',
    x: '<path d="M6 6l12 12M18 6L6 18"/>',
    copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V5a1 1 0 00-1-1H5a1 1 0 00-1 1v10a1 1 0 001 1h3"/>',
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
  async function post(path, body = {}) {
    const r = await fetch(path, {
      method: "POST", credentials: "same-origin", cache: "no-store",
      headers: { "Content-Type": "application/json", "X-Panel": "1" }, body: JSON.stringify(body),
    });
    if (r.status === 401) { location.replace("/login"); throw new Error("unauthorized"); }
    const data = await r.json().catch(() => ({}));
    if (!r.ok) { const e = new Error(data.error || `HTTP ${r.status}`); e.saved = !!data.saved; throw e; }
    return data;
  }
  const withInstance = (extra = {}) => (state.instance ? { instance: state.instance, ...extra } : extra);

  // ---------------------------------------------------------------- toasts, dialogs, small UI helpers
  function toast(message, kind = "") {
    const el = document.createElement("div");
    el.className = `toast ${kind}`;
    el.setAttribute("role", kind === "bad" ? "alert" : "status");
    el.textContent = message;
    const box = $("toasts");
    box.appendChild(el);
    while (box.children.length > 4) box.firstChild.remove();   // never pile up a long stack
    setTimeout(() => el.remove(), kind ? 8000 : 4000);
  }

  function openDialog(o) {
    const dlg = document.createElement("dialog");
    dlg.className = `modal${o.wide ? " wide" : ""}`;
    dlg.innerHTML = `<form class="modal-form">
      <header><h3>${esc(o.title)}</h3><button type="button" class="btn small icon ghost" data-close aria-label="${esc(t("close"))}">${icon("x")}</button></header>
      <div class="modal-body">${o.body}</div>
      <div class="form-error" role="alert"></div>
      <footer><button type="button" class="btn" data-close>${esc(o.cancel || t("cancel"))}</button>${o.hideSubmit ? "" : `<button type="submit" class="btn ${o.danger ? "danger solid" : "primary"}">${esc(o.submit || t("save"))}</button>`}</footer>
    </form>`;
    const form = dlg.querySelector("form"), err = dlg.querySelector(".form-error"), submitBtn = dlg.querySelector('[type="submit"]');
    dlg.querySelectorAll("[data-close]").forEach((b) => b.addEventListener("click", () => dlg.close()));
    dlg.addEventListener("close", () => dlg.remove());
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      err.textContent = "";
      if (!o.onSubmit) { dlg.close(); return; }
      const label = submitBtn.textContent;
      submitBtn.disabled = true;
      submitBtn.textContent = o.busy || t("working");
      try { await o.onSubmit(form, dlg); dlg.close(); }
      catch (x) { if (x.message !== "unauthorized") err.textContent = x.message; }
      finally { submitBtn.disabled = false; submitBtn.textContent = label; }
    });
    document.body.appendChild(dlg);
    dlg.showModal();
    if (o.onOpen) o.onOpen(dlg, form);
    return dlg;
  }

  function confirmBox({ message, label, danger = true }) {
    return new Promise((resolve) => {
      let answered = false;
      const dlg = openDialog({
        title: t("confirm"), body: `<p>${esc(message)}</p>`, submit: label, danger,
        onSubmit: async () => { answered = true; resolve(true); },
      });
      dlg.addEventListener("close", () => { if (!answered) resolve(false); });
    });
  }

  // Runs an action on a button: disables it, reports errors as toasts, optionally confirms success.
  async function act(btn, fn, okMessage) {
    if (btn) btn.disabled = true;
    try {
      const result = await fn();
      if (okMessage) toast(okMessage);
      return result ?? true;
    } catch (e) {
      if (e.message !== "unauthorized") toast(e.message, e.saved ? "warn" : "bad");
      return null;
    } finally { if (btn) btn.disabled = false; }
  }

  function copyText(text) {
    // navigator.clipboard only exists on HTTPS/localhost; the panel is often served over plain HTTP.
    const ta = document.createElement("textarea");
    ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
    document.body.appendChild(ta); ta.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (e) { /* ignore */ }
    ta.remove();
    toast(ok ? t("copied") : text, ok ? "" : "warn");
  }

  // ---------------------------------------------------------------- chrome (header, nav)
  const VIEWS = [
    { id: "overview", icon: "grid", label: "overview", desc: "d_overview", group: "monitor" },
    { id: "containers", icon: "box", label: "containers_nav", desc: "d_containers", group: "monitor" },
    { id: "websites", icon: "globe", label: "websites_nav", desc: "d_websites", group: "monitor" },
    { id: "disks", icon: "disk", label: "disks", desc: "d_disks", group: "monitor" },
    { id: "network", icon: "network", label: "network", desc: "d_network", group: "monitor" },
    { id: "targets", icon: "check", label: "targets_nav", desc: "d_targets", group: "monitor" },
    { id: "alerts", icon: "bell", label: "alerts_nav", desc: "d_alerts", group: "monitor" },
    { id: "servers", icon: "server", label: "servers_nav", desc: "d_servers", group: "manage" },
    { id: "notifications", icon: "send", label: "notifications_nav", desc: "d_notifications", group: "manage", static: true },
    { id: "rules", icon: "sliders", label: "rules_nav", desc: "d_rules", group: "manage", static: true },
    { id: "settings", icon: "gear", label: "settings_nav", desc: "d_settings", group: "manage", static: true },
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
    $("logout").innerHTML = `${icon("logout")}<span class="txt">${esc(t("logout"))}</span>`;
    renderNav();
  }

  function badgeFor(id) {
    const o = state.overview, s = state.settings;
    if (id === "notifications") return s && !s.telegram.configured ? '<span class="badge bad">!</span>' : "";
    if (id === "servers") return state.instances.length ? `<span class="badge">${state.instances.length}</span>` : "";
    if (!o) return "";
    if (id === "containers") return `<span class="badge">${o.containers}</span>`;
    if (id === "websites") return o.checks.total ? `<span class="badge${o.checks.up < o.checks.total ? " bad" : ""}">${o.checks.up}/${o.checks.total}</span>` : "";
    if (id === "targets") return `<span class="badge${o.targets.up < o.targets.total ? " bad" : ""}">${o.targets.up}/${o.targets.total}</span>`;
    if (id === "alerts") return o.alerts.firing ? `<span class="badge bad">${o.alerts.firing}</span>` : "";
    return "";
  }
  function renderNav() {
    const link = (v) => `<a href="#${v.id}" class="${v.id === state.view ? "active" : ""}" ${v.id === state.view ? 'aria-current="page"' : ""}>${icon(v.icon)}<span class="name">${esc(t(v.label))}</span>${badgeFor(v.id)}</a>`;
    $("nav").innerHTML = VIEWS.filter((v) => v.group === "monitor").map(link).join("");
    $("nav-manage").innerHTML = VIEWS.filter((v) => v.group === "manage").map(link).join("");
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
  function table(cols, rows, rowAttrs) {
    if (!rows.length) return `<div class="table-wrap"><div class="empty">${esc(t("empty"))}</div></div>`;
    const head = cols.map((c) => `<th>${c.raw ? c.h : esc(t(c.h))}</th>`).join("");
    const body = rows.map((r) => `<tr${rowAttrs ? " " + rowAttrs(r) : ""}>${cols.map((c) => `<td class="${c.cls || ""}">${c.cell(r)}</td>`).join("")}</tr>`).join("");
    return `<div class="table-wrap"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
  }
  const pill = (kind, text, dot = true) => `<span class="pill ${kind}${dot ? " dot" : ""}">${esc(text)}</span>`;
  const miniBar = (pct) => `<div class="mini-bar"><div class="bar ${level(pct)}"><i style="width:${Math.min(100, pct)}%"></i></div>${num(`${nf(pct, 0)}%`)}</div>`;
  const btnIcon = (ic, label, attrs, cls = "") => `<button type="button" class="btn small icon ${cls}" title="${esc(label)}" aria-label="${esc(label)}" ${attrs}>${icon(ic)}</button>`;
  const addButton = (id, label) => `<button type="button" class="btn small primary" id="${id}">${icon("plus")}<span>${esc(label)}</span></button>`;
  const statusPill = (up, known = true) => (!known ? pill("", t("s_wait")) : up ? pill("ok", t("s_up")) : pill("bad", t("s_down")));
  const val = (form, name) => form.elements[name].value;
  const field = (label, control, hint = "") => `<div class="field"><label>${esc(label)}</label>${control}${hint ? `<p class="hint">${esc(hint)}</p>` : ""}</div>`;

  // ---------------------------------------------------------------- views: each has build() and optional bind()
  const CONTAINER_STATE = { running: "ok", restarting: "warn", paused: "warn", created: "warn", exited: "bad", dead: "bad" };
  const stateLabel = (st) => { const k = `s_${st}`; const v = t(k); return v === k ? st : v; };

  const IMPL = {
    // ---- containers
    containers: {
      async build() {
        const { docker, rows } = await api("/api/containers");
        const note = docker ? "" : `<div class="notice">${icon("bell")}<span>${esc(t("c_docker_off"))}</span></div>`;
        const cols = [
          { h: "name", cls: "strong", cell: (r) => `${esc(r.name)}${r.stack ? `<span class="tag">${esc(t("c_stack"))}</span>` : ""}${r.self ? `<span class="tag">${esc(t("c_self"))}</span>` : ""}${r.image ? `<div class="sub-line">${esc(r.image)}</div>` : ""}` },
          { h: "status", cell: (r) => pill(CONTAINER_STATE[r.state] || "", stateLabel(r.state)) },
          { h: "cpu_h", cell: (r) => num(r.cpu == null ? "–" : `${nf(r.cpu)}%`) },
          { h: "mem_h", cell: (r) => num(fmtBytes(r.mem)) },
          { h: "uptime_h", cell: (r) => num(fmtDur(r.uptime)) },
          { h: "ports", cls: "wrap-cell", cell: (r) => (r.ports && r.ports.length ? `<div class="chips">${r.ports.map((p) => `<code>${esc(p)}</code>`).join("")}</div>` : "–") },
        ];
        if (docker) cols.push({ h: "actions", cell: (r) => {
          if (r.self) return "–";
          const a = (act, ic, label, extra = "") => btnIcon(ic, label, `data-act="${act}" data-id="${esc(r.id)}" data-name="${esc(r.name)}"`, extra);
          const running = r.state === "running";
          return `<div class="row-actions">${running ? a("restart", "refresh", t("a_restart")) + a("stop", "stop", t("a_stop")) : a("start", "play", t("a_start"))}${a("logs", "file", t("a_logs"))}${r.stack ? "" : a("remove", "trash", t("a_remove"), "danger")}</div>`;
        } });
        return { html: note + table(cols, rows), tools: docker ? addButton("btn-add-container", t("c_add")) : "" };
      },
      bind(root) {
        $("btn-add-container")?.addEventListener("click", addContainerDialog);
        root.addEventListener("click", async (e) => {
          const b = e.target.closest("[data-act]");
          if (!b) return;
          const { act: action, id, name } = b.dataset;
          if (action === "logs") return logsDialog(id, name);
          if (action === "remove" && !(await confirmBox({ message: t("c_confirm_remove", { n: name }), label: t("a_remove") }))) return;
          if (action === "stop" && !(await confirmBox({ message: t("c_confirm_stop", { n: name }), label: t("a_stop") }))) return;
          if (action === "restart" && !(await confirmBox({ message: t("c_confirm_restart", { n: name }), label: t("a_restart"), danger: false }))) return;
          if (await act(b, () => post("/api/docker/action", { id, action }), t("c_done"))) renderView(false);
        });
      },
    },

    // ---- websites + TCP ports
    websites: {
      async build() {
        const checks = await api("/api/checks");
        let metrics = [];
        try { metrics = (await api("/api/websites")).rows; } catch (e) { /* metrics are optional here */ }
        const byTarget = new Map(metrics.map((m) => [m.target, m]));
        const managed = [...checks.http.map((x) => ({ ...x, kind: "http" })), ...checks.tcp.map((x) => ({ ...x, kind: "tcp" }))];
        const known = new Set(managed.map((m) => m.target));
        const extra = metrics.filter((m) => !known.has(m.target)).map((m) => ({ target: m.target, name: "", kind: m.job === "tcp" ? "tcp" : "http", fixed: true }));
        const rows = [...managed, ...extra].map((r) => ({ ...r, m: byTarget.get(r.target) }));
        const cols = [
          { h: "target", cls: "strong", cell: (r) => `${num(esc(r.target))}${r.mode && r.mode !== "default" ? `<span class="tag">${esc(t("mode_" + r.mode))}</span>` : ""}${r.name ? `<div class="sub-line">${esc(r.name)}</div>` : ""}` },
          { h: "type", cell: (r) => pill("info", r.kind.toUpperCase(), false) },
          { h: "status", cell: (r) => statusPill(r.m && r.m.up, !!r.m) },
          { h: "response", cell: (r) => num(r.m ? fmtMs(r.m.duration) : "–") },
          { h: "http", cell: (r) => num(r.m && r.m.http ? r.m.http : "–") },
          { h: "ssl_h", cell: (r) => (!r.m || r.m.ssl_days == null ? "–" : pill(r.m.ssl_days < 7 ? "bad" : r.m.ssl_days < 14 ? "warn" : "ok", nf(r.m.ssl_days, 0), false)) },
          { h: "actions", cell: (r) => `<div class="row-actions">${btnIcon("search", t("probe"), `data-act="probe" data-kind="${r.kind}" data-target="${esc(r.target)}"`)}${r.fixed ? "" : btnIcon("trash", t("remove"), `data-act="del" data-kind="${r.kind}" data-target="${esc(r.target)}"`, "danger")}</div>` },
        ];
        return { html: table(cols, rows) + `<p class="muted" style="margin-top:12px">${esc(t("w_hint"))}</p>`, tools: addButton("btn-add-site", t("add_site")) };
      },
      bind(root) {
        $("btn-add-site")?.addEventListener("click", addSiteDialog);
        root.addEventListener("click", async (e) => {
          const pb = e.target.closest('[data-act="probe"]');
          if (pb) return probeDialog(pb.dataset.kind, pb.dataset.target);
          const b = e.target.closest('[data-act="del"]');
          if (!b) return;
          if (!(await confirmBox({ message: t("w_confirm_remove", { n: b.dataset.target }), label: t("remove") }))) return;
          if (await act(b, () => post("/api/checks/remove", { kind: b.dataset.kind, target: b.dataset.target }), t("removed"))) renderView(false);
        });
      },
    },

    disks: {
      async build() {
        const { rows } = await api("/api/disks", withInstance());
        return table([
          { h: "mount", cls: "strong", cell: (r) => num(esc(r.mount)) },
          { h: "device", cls: "muted", cell: (r) => num(esc(r.device)) },
          { h: "fs", cell: (r) => esc(r.fstype) },
          { h: "usage", cell: (r) => miniBar(r.pct) },
          { h: "used_total", cell: (r) => num(`${fmtBytes(r.used)} / ${fmtBytes(r.total)}`) },
        ], rows);
      },
    },

    network: {
      async build() {
        const { rows, exporter } = await api("/api/network", withInstance());
        if (!rows.length) {
          const why = !exporter ? "nx_nodata" : !exporter.present ? "nx_nojob" : !exporter.up ? "nx_down" : "nx_nodata";
          const detail = exporter && exporter.error ? ` <code>${esc(exporter.error)}</code>` : "";
          return `<div class="notice bad">${icon("bell")}<span>${esc(t(why))}${detail}</span></div>` + table([], []);
        }
        return table([
          { h: "iface", cls: "strong", cell: (r) => num(esc(r.device)) },
          { h: "status", cell: (r) => (r.up ? pill("ok", t("s_up")) : pill("bad", t("s_down"))) },
          { h: "speed", cell: (r) => num(r.speed ? `${nf((r.speed * 8) / 1e6, 0)} Mbit/s` : "–") },
          { h: "rate_in", cell: (r) => num(fmtRate(r.rx)) },
          { h: "rate_out", cell: (r) => num(fmtRate(r.tx)) },
          { h: "total_in", cell: (r) => num(fmtBytes(r.rx_total)) },
          { h: "total_out", cell: (r) => num(fmtBytes(r.tx_total)) },
        ], rows);
      },
    },

    targets: {
      async build() {
        const { rows } = await api("/api/targets");
        return table([
          { h: "job", cls: "strong", cell: (r) => esc(r.job) },
          { h: "instance", cell: (r) => num(esc(r.instance)) },
          { h: "status", cell: (r) => (r.up ? pill("ok", t("s_up")) : pill("bad", t("s_down"))) },
          { h: "scrape", cell: (r) => num(fmtMs(r.duration)) },
          { h: "error", cls: "wrap-cell", cell: (r) => (r.error ? `<span style="color:var(--red)">${esc(r.error)}</span>` : "") },
        ], rows);
      },
    },

    alerts: {
      async build() {
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
    },

    // ---- servers (node_exporter targets)
    servers: {
      async build() {
        const checks = await api("/api/checks");
        let targets = [];
        try { targets = (await api("/api/targets")).rows.filter((r) => r.job === "node"); } catch (e) { /* optional */ }
        const byInst = new Map(targets.map((r) => [r.instance, r]));
        const cols = [
          { h: "target", cls: "strong", cell: (r) => `${num(esc(r.target))}${r.locked ? `<span class="tag">${esc(t("srv_local"))}</span>` : ""}` },
          { h: "name", cell: (r) => esc(r.name || "–") },
          { h: "status", cell: (r) => { const m = byInst.get(r.target); return statusPill(m && m.up, !!m); } },
          { h: "actions", cell: (r) => (r.locked ? "–" : `<div class="row-actions">${btnIcon("trash", t("remove"), `data-act="del" data-target="${esc(r.target)}"`, "danger")}</div>`) },
        ];
        const cmd = "docker run -d --name node-exporter --restart unless-stopped \\\n  --net host --pid host -v /:/host:ro,rslave \\\n  prom/node-exporter:v1.8.2 --path.rootfs=/host";
        const fw = "ufw allow from <MONITORING-SERVER-IP> to any port 9100 proto tcp";
        const help = `<div class="subcard" style="margin-top:18px"><h3>${esc(t("srv_help_title"))}</h3>
          <p>${esc(t("srv_help_1"))}</p><div class="codebox">${esc(cmd)}</div><button type="button" class="btn small" data-copy="${esc(cmd)}">${icon("copy")}<span>${esc(t("copy"))}</span></button>
          <p>${esc(t("srv_help_2"))}</p><div class="codebox">${esc(fw)}</div><p>${esc(t("srv_help_3"))}</p></div>`;
        return { html: table(cols, checks.nodes) + help, tools: addButton("btn-add-server", t("add_server")) };
      },
      bind(root) {
        $("btn-add-server")?.addEventListener("click", addServerDialog);
        root.addEventListener("click", async (e) => {
          const c = e.target.closest("[data-copy]");
          if (c) return copyText(c.dataset.copy);
          const b = e.target.closest('[data-act="del"]');
          if (!b) return;
          if (!(await confirmBox({ message: t("srv_confirm_remove", { n: b.dataset.target }), label: t("remove") }))) return;
          if (await act(b, () => post("/api/checks/remove", { kind: "nodes", target: b.dataset.target }), t("removed"))) { state.instances = []; renderView(false); }
        });
      },
    },

    // ---- notifications (Telegram)
    notifications: {
      async build() {
        const s = (state.settings = await api("/api/settings"));
        const tg = s.telegram;
        const status = tg.configured ? pill("ok", t("tg_ok")) : pill("", t("tg_no"));
        const bot = tg.configured && tg.bot ? ` <span class="muted">${esc(t("tg_bot"))}: @${esc(tg.bot)}</span>` : "";
        const tokenHint = tg.configured ? t("tg_token_saved", { h: tg.token_hint }) : "";
        const html = `<div class="split">
          <section class="subcard"><h3>${icon("send")}${esc(t("tg_title"))} ${status}${bot}</h3>
            <ol class="steps"><li>${esc(t("tg_s1"))}</li><li>${esc(t("tg_s2"))}</li><li>${esc(t("tg_s3"))}</li></ol>
            <form id="tg-form" autocomplete="off">
              ${field(t("tg_token"), `<input name="token" type="password" dir="ltr" autocomplete="new-password" placeholder="123456789:AA…">`, tokenHint)}
              ${field(t("tg_chat"), `<input name="chat_id" dir="ltr" inputmode="numeric" value="${esc(tg.chat_id)}" placeholder="123456789">`)}
              <div id="tg-chats" class="chips" style="margin:-4px 0 14px"></div>
              <div class="actions-row">
                <button type="submit" class="btn primary">${esc(t("save"))}</button>
                <button type="button" class="btn" id="tg-find">${icon("search")}<span>${esc(t("tg_find"))}</span></button>
                <button type="button" class="btn" id="tg-test">${esc(t("tg_test"))}</button>
                ${tg.configured ? `<button type="button" class="btn danger" id="tg-remove">${esc(t("tg_remove"))}</button>` : ""}
              </div>
            </form></section>
          <section class="subcard"><h3>${icon("bell")}${esc(t("at_title"))}</h3><p>${esc(t("at_text"))}</p>
            <button type="button" class="btn" id="alert-test">${esc(t("at_btn"))}</button></section></div>`;
        return { html, tools: "" };
      },
      bind(root) {
        const form = root.querySelector("#tg-form");
        const creds = () => ({ token: val(form, "token").trim(), chat_id: val(form, "chat_id").trim() });
        form.addEventListener("submit", async (e) => {
          e.preventDefault();
          if (await act(form.querySelector('[type="submit"]'), () => post("/api/telegram/save", creds()), t("tg_saved"))) renderView(true);
        });
        root.querySelector("#tg-find").addEventListener("click", async (e) => {
          const box = root.querySelector("#tg-chats");
          const r = await act(e.currentTarget, () => post("/api/telegram/chats", { token: val(form, "token").trim() }));
          if (!r) return;
          box.innerHTML = r.chats.length
            ? `<span class="muted">${esc(t("tg_found"))}</span>` + r.chats.map((c) => `<button type="button" class="btn small" data-chat="${esc(c.id)}">${esc(c.title)} <code>${esc(c.id)}</code></button>`).join("")
            : `<span class="muted">${esc(t("tg_none"))}</span>`;
        });
        root.querySelector("#tg-chats").addEventListener("click", (e) => {
          const b = e.target.closest("[data-chat]");
          if (b) form.elements.chat_id.value = b.dataset.chat;
        });
        root.querySelector("#tg-test").addEventListener("click", (e) => act(e.currentTarget, () => post("/api/telegram/test", creds()), t("tg_test_ok")));
        root.querySelector("#tg-remove")?.addEventListener("click", async (e) => {
          if (!(await confirmBox({ message: t("tg_confirm_remove"), label: t("tg_remove") }))) return;
          if (await act(e.currentTarget, () => post("/api/telegram/remove"), t("tg_removed"))) renderView(true);
        });
        root.querySelector("#alert-test").addEventListener("click", (e) => act(e.currentTarget, () => post("/api/alerts/test"), t("at_ok")));
      },
    },

    // ---- alert rules
    rules: {
      async build() {
        const { rules } = await api("/api/rules");
        const sev = { critical: "bad", warning: "warn", info: "info" };
        const cols = [
          { h: "rl_enabled", cell: (r) => `<label class="switch"><input type="checkbox" data-f="enabled" ${r.enabled ? "checked" : ""} aria-label="${esc(r.name)}"><span></span></label>` },
          { h: "rl_rule", cls: "strong", cell: (r) => `${esc(r.name)}<div class="sub-line">${esc(t("rd_" + r.name))}</div>` },
          { h: "severity", cell: (r) => pill(sev[r.severity] || "", r.severity, false) },
          { h: "rl_threshold", cell: (r) => (r.has_threshold ? `<span class="inline-field"><input type="number" data-f="value" step="any" min="${r.min}" max="${r.max}" value="${esc(r.value)}" aria-label="${esc(t("rl_threshold"))}"><small>${esc(r.unit)}</small></span>` : "–") },
          { h: "rl_for", cell: (r) => `<span class="inline-field"><input type="number" data-f="for" step="1" min="0" max="1440" value="${esc(r.for)}" aria-label="${esc(t("rl_for"))}"><small>${esc(t("minutes"))}</small></span>` },
          { h: "", raw: true, cell: () => `<button type="button" class="btn small primary" data-save disabled>${esc(t("save"))}</button>` },
        ];
        const html = table(cols, rules, (r) => `data-rule="${esc(r.name)}"`);
        return { html, tools: `<button type="button" class="btn small" id="btn-reset-rules">${esc(t("reset_defaults"))}</button>` };
      },
      bind(root) {
        root.addEventListener("input", (e) => { const row = e.target.closest("tr[data-rule]"); if (row) row.querySelector("[data-save]").disabled = false; });
        root.addEventListener("change", (e) => { const row = e.target.closest("tr[data-rule]"); if (row) row.querySelector("[data-save]").disabled = false; });
        root.addEventListener("click", async (e) => {
          const b = e.target.closest("[data-save]");
          if (!b) return;
          const row = b.closest("tr[data-rule]");
          const val = row.querySelector('[data-f="value"]');
          const body = { name: row.dataset.rule, enabled: row.querySelector('[data-f="enabled"]').checked, value: val ? val.value : null, for: row.querySelector('[data-f="for"]').value };
          if (await act(b, () => post("/api/rules/set", body), t("rl_saved"))) renderView(true);
        });
        $("btn-reset-rules")?.addEventListener("click", async (e) => {
          if (!(await confirmBox({ message: t("rl_reset_confirm"), label: t("reset_defaults"), danger: false }))) return;
          if (await act(e.currentTarget, () => post("/api/rules/reset"), t("rl_reset_ok"))) renderView(true);
        });
      },
    },

    // ---- settings
    settings: {
      async build() {
        const s = (state.settings = await api("/api/settings"));
        const d = s.docker;
        const dockerPill = d.enabled && d.available ? pill("ok", t("st_docker_on")) : d.enabled ? pill("warn", t("st_docker_unavail"), false) : pill("", t("st_docker_off"));
        const html = `<div class="split">
          <section class="subcard"><h3>${icon("lock")}${esc(t("st_pw_title"))}</h3>
            <form id="pw-form" autocomplete="off">
              ${field(t("st_user"), `<input name="user" dir="ltr" value="${esc(s.user)}" autocomplete="username" required>`)}
              ${field(t("st_current"), `<input name="current" type="password" dir="ltr" autocomplete="current-password" required>`)}
              ${field(t("st_new"), `<input name="new" type="password" dir="ltr" autocomplete="new-password" minlength="8" required>`)}
              ${field(t("st_repeat"), `<input name="repeat" type="password" dir="ltr" autocomplete="new-password" minlength="8" required>`)}
              <div class="actions-row"><button type="submit" class="btn primary">${esc(t("st_change"))}</button></div>
            </form></section>
          <div style="display:grid;gap:16px">
            <section class="subcard"><h3>${icon("box")}${esc(t("st_docker_title"))} ${dockerPill}</h3>
              <p>${esc(d.enabled ? t("st_docker_hint_on") : t("st_docker_hint_off"))}</p></section>
            <section class="subcard"><h3>${icon("server")}${esc(t("st_about"))}</h3>
              <p>${esc(t("st_version"))}: ${num(esc(s.version))}</p></section></div></div>`;
        return { html, tools: "" };
      },
      bind(root) {
        const form = root.querySelector("#pw-form");
        form.addEventListener("submit", async (e) => {
          e.preventDefault();
          if (val(form, "new") !== val(form, "repeat")) return toast(t("st_mismatch"), "bad");
          const ok = await act(form.querySelector('[type="submit"]'), () => post("/api/password", { user: val(form, "user").trim(), current: val(form, "current"), new: val(form, "new") }), t("st_pw_ok"));
          if (ok) { ["current", "new", "repeat"].forEach((n) => { form.elements[n].value = ""; }); }
        });
      },
    },
  };

  // ---------------------------------------------------------------- dialogs
  function logsDialog(id, name) {
    openDialog({
      title: `${t("logs_title")}: ${name}`, wide: true, hideSubmit: true, cancel: t("close"),
      body: `<div style="display:flex;gap:10px;align-items:center;margin-bottom:10px;flex-wrap:wrap">
        <select id="log-tail" aria-label="${esc(t("lines"))}"><option value="100">100 ${esc(t("lines"))}</option><option value="300" selected>300 ${esc(t("lines"))}</option><option value="1000">1000 ${esc(t("lines"))}</option></select>
        <button type="button" class="btn small" id="log-refresh">${icon("refresh")}<span>${esc(t("refresh"))}</span></button></div>
        <pre class="logs" id="log-pre">…</pre>`,
      onOpen: (dlg) => {
        const pre = dlg.querySelector("#log-pre");
        const load = async () => {
          try {
            const r = await api("/api/docker/logs", { id, tail: dlg.querySelector("#log-tail").value });
            pre.textContent = r.text || "—";
            pre.scrollTop = pre.scrollHeight;
          } catch (e) { pre.textContent = e.message; }
        };
        dlg.querySelector("#log-refresh").addEventListener("click", load);
        dlg.querySelector("#log-tail").addEventListener("change", load);
        load();
      },
    });
  }

  function probeDialog(kind, target) {
    openDialog({
      title: `${t("probe_title")}: ${target}`, wide: true, hideSubmit: true, cancel: t("close"),
      body: `<div id="probe-out"><div class="skeleton" style="height:70px"></div><p class="muted">${esc(t("probe_running"))}</p></div>`,
      onOpen: async (dlg) => {
        const out = dlg.querySelector("#probe-out");
        try {
          const r = await post("/api/checks/probe", { kind, target });
          const status = r.http_status ? ` · ${esc(t("probe_status"))}: ${num(r.http_status)}` : "";
          let diag = "";
          if (r.variants && r.variants.length) {
            const by = Object.fromEntries(r.variants.map((v) => [v.id, v]));
            const secureOk = r.variants.some((v) => v.ok && v.id in { legacy_tls: 1, no_verify: 1, legacy_no_verify: 1 });
            const note = secureOk ? t("diag_suggest")
              : by.plain_http && by.plain_http.ok ? t("diag_plain")
              : by.tcp && by.tcp.ok ? t("diag_blocked") : t("diag_closed");
            const rows = r.variants.map((v) => {
              const label = t(v.id === "tcp" ? "v_tcp" : `v_${v.id}`);
              const apply = v.ok && v.id in { legacy_tls: 1, no_verify: 1, legacy_no_verify: 1 }
                ? `<button type="button" class="btn small primary" data-mode="${v.id}">${esc(t("diag_apply"))}</button>` : "";
              return `<tr><td>${v.ok ? pill("ok", t("diag_works")) : pill("bad", t("diag_fails"))}</td><td class="strong" style="white-space:normal">${esc(label)}${apply ? `<div style="margin-top:8px">${apply}</div>` : ""}</td><td class="wrap-cell muted" style="min-width:300px">${v.ok ? "" : `<code class="reason">${esc(v.reason)}</code>`}</td></tr>`;
            }).join("");
            const httpFix = !secureOk && by.plain_http && by.plain_http.ok && target.startsWith("https://")
              ? `<p><button type="button" class="btn small primary" data-replace="http://${esc(target.slice(8))}">${esc(t("diag_use_http"))}</button></p>` : "";
            diag = `<h4 style="margin:18px 0 8px">${esc(t("diag_title"))}</h4><p class="muted">${esc(note)}</p>${httpFix}<div class="table-wrap"><table><tbody>${rows}</tbody></table></div>`;
          }
          out.innerHTML = `<div class="notice ${r.ok ? "ok" : "bad"}">${icon(r.ok ? "okmark" : "bell")}<span><b>${esc(t(r.ok ? "probe_ok" : "probe_fail"))}</b>${status}</span></div>
            ${r.ok ? "" : `<p>${esc(t("probe_k_" + (r.kind || "other")))}</p>`}
            ${r.reason ? `<p><b>${esc(t("probe_reason"))}:</b> <code>${esc(r.reason)}</code></p>` : ""}
            ${diag}
            ${r.ok ? "" : `<p class="muted">${esc(t("probe_hint"))}</p>`}
            <details><summary>${esc(t("probe_log"))}</summary><pre class="logs" style="height:280px;margin-top:10px">${esc(r.log)}</pre></details>`;
          out.querySelectorAll("[data-replace]").forEach((b) => b.addEventListener("click", async () => {
            if (await act(b, () => post("/api/checks/replace", { kind, target, new_target: b.dataset.replace }), t("diag_replaced"))) { dlg.close(); renderView(false); }
          }));
          out.querySelectorAll("[data-mode]").forEach((b) => b.addEventListener("click", async () => {
            if (await act(b, () => post("/api/checks/mode", { kind, target, mode: b.dataset.mode }), t("diag_applied"))) { dlg.close(); renderView(false); }
          }));
        } catch (e) { out.innerHTML = `<div class="notice bad">${icon("bell")}<span>${esc(e.message)}</span></div>`; }
      },
    });
  }

  const lines = (value) => value.split("\n").map((s) => s.trim()).filter(Boolean);

  function addContainerDialog() {
    openDialog({
      title: t("c_add"), submit: t("add"), busy: t("pulling_hint"), wide: true,
      body: `${field(t("f_image"), `<input name="image" dir="ltr" required placeholder="nginx:alpine" autocomplete="off">`, t("f_image_hint"))}
        <div class="field-row">
          ${field(t("f_cname"), `<input name="name" dir="ltr" placeholder="my-app" autocomplete="off">`)}
          ${field(t("f_restart"), `<select name="restart"><option value="unless-stopped">${esc(t("rp_unless"))}</option><option value="always">${esc(t("rp_always"))}</option><option value="on-failure">${esc(t("rp_failure"))}</option><option value="no">${esc(t("rp_no"))}</option></select>`)}
        </div>
        <div class="field-row">
          ${field(t("f_ports"), `<textarea name="ports" placeholder="8081:80"></textarea>`, t("f_ports_hint"))}
          ${field(t("f_env"), `<textarea name="env" placeholder="KEY=value"></textarea>`, t("f_env_hint"))}
        </div>
        ${field(t("f_volumes"), `<textarea name="volumes" placeholder="/srv/data:/data"></textarea>`, t("f_volumes_hint"))}`,
      onSubmit: async (form) => {
        await post("/api/docker/run", {
          image: val(form, "image").trim(), name: val(form, "name").trim(), restart: val(form, "restart"),
          ports: lines(val(form, "ports")), env: lines(val(form, "env")), volumes: lines(val(form, "volumes")),
        });
        toast(t("c_added"));
        renderView(false);
      },
    });
  }

  function addSiteDialog() {
    openDialog({
      title: t("add_site"), submit: t("add"),
      body: `${field(t("type"), `<select name="kind"><option value="http">${esc(t("type_http"))}</option><option value="tcp">${esc(t("type_tcp"))}</option></select>`)}
        ${field(t("f_target"), `<input name="target" dir="ltr" required placeholder="https://example.com" autocomplete="off">`, t("hint_http"))}
        ${field(t("f_name_opt"), `<input name="name" maxlength="60" autocomplete="off">`)}`,
      onOpen: (dlg, form) => {
        const hint = dlg.querySelector(".hint");
        form.elements.kind.addEventListener("change", () => {
          const http = val(form, "kind") === "http";
          form.elements.target.placeholder = http ? "https://example.com" : "203.0.113.10:22";
          hint.textContent = t(http ? "hint_http" : "hint_tcp");
        });
        form.elements.target.focus();
      },
      onSubmit: async (form) => {
        let target = val(form, "target").trim();
        const kind = val(form, "kind");
        if (kind === "http" && target && !/^[a-z][a-z0-9+.-]*:\/\//i.test(target)) target = `https://${target}`;  // only when no scheme was typed
        await post("/api/checks/add", { kind, target, name: val(form, "name").trim() });
        toast(t("added"));
        renderView(false);
      },
    });
  }

  function addServerDialog() {
    openDialog({
      title: t("add_server"), submit: t("add"),
      body: `${field(t("f_srv_addr"), `<input name="target" dir="ltr" required placeholder="203.0.113.10:9100" autocomplete="off">`, t("f_srv_hint"))}
        ${field(t("f_name_opt"), `<input name="name" maxlength="60" autocomplete="off">`)}`,
      onOpen: (dlg, form) => form.elements.target.focus(),
      onSubmit: async (form) => {
        let target = val(form, "target").trim();
        if (target && !/:\d+$/.test(target)) target += ":9100";
        await post("/api/checks/add", { kind: "nodes", target, name: val(form, "name").trim() });
        toast(t("added"));
        state.instances = [];
        renderView(false);
      },
    });
  }

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
    // A line needs at least two samples at different times; right after startup there is only one.
    if (new Set(all.map((p) => p[0])).size < 2) { box.innerHTML = `<div class="empty">${esc(t("no_data"))}</div>`; return; }
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
      `<div class="chart"><header><h3>${esc(t(c.title))}</h3><span class="now" id="now-${i}"></span></header><div class="plot" id="plot-${i}"><div class="skeleton"></div></div>${c.names || c.colors.length > 1 ? `<div class="legend">${(c.names ? c.names.map((n) => t(n)) : ["1m", "5m", "15m"]).map((n, k) => `<span><i style="background:var(${c.colors[k]})"></i>${esc(n)}</span>`).join("")}</div>` : ""}</div>`).join("")}</div>`;
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
  function overviewTools() {
    const label = (i) => (state.names[i] ? `${state.names[i]} (${i})` : i);
    const inst = state.instances.length > 1
      ? `<label class="muted" for="sel-inst">${esc(t("server"))}</label><select id="sel-inst">${state.instances.map((i) => `<option ${i === state.instance ? "selected" : ""} value="${esc(i)}">${esc(label(i))}</option>`).join("")}</select>` : "";
    const range = `<label class="muted" for="sel-range">${esc(t("range"))}</label><select id="sel-range">${["1h", "6h", "24h", "7d"].map((r) => `<option ${r === state.range ? "selected" : ""} value="${r}">${esc(t("r" + r))}</option>`).join("")}</select>`;
    return inst + range;
  }

  async function renderView(first) {
    const id = ++state.renderId;
    const v = VIEWS.find((x) => x.id === state.view) || VIEWS[0];
    const root = $("panel");
    const hadShell = root.dataset.view === v.id && root.dataset.lang === state.lang;
    if (v.static && hadShell && !first) return;   // forms must not be wiped by the 10-second refresh
    if (!hadShell || first) {
      root.dataset.view = v.id;
      root.dataset.lang = state.lang;
      root.innerHTML = `<div class="panel-head"><h2>${icon(v.icon)}${esc(t(v.label))}</h2><div class="tools" id="tools">${v.id === "overview" ? overviewTools() : ""}</div></div><p class="desc">${esc(t(v.desc))}</p><hr><div id="body"><div class="skeleton"></div></div>`;
      const si = $("sel-inst"), sr = $("sel-range");
      if (si) si.onchange = () => { state.instance = si.value; store.set("instance", si.value); tick(true); };
      if (sr) sr.onchange = () => { state.range = sr.value; store.set("range", sr.value); renderView(true); };
    }
    try {
      if (v.id === "overview") { await buildOverview(root, id, !hadShell || first); return; }
      const impl = IMPL[v.id];
      const res = await impl.build();
      if (id !== state.renderId) return;
      const html = typeof res === "string" ? res : res.html;
      const body = root.querySelector("#body");
      const fresh = body.cloneNode(false);              // drop handlers bound to the previous render
      fresh.innerHTML = html;
      body.replaceWith(fresh);
      if (typeof res !== "string") $("tools").innerHTML = res.tools || "";
      if (impl.bind) impl.bind(fresh);
    } catch (e) {
      if (id === state.renderId && e.message !== "unauthorized") root.querySelector("#body").innerHTML = `<div class="notice bad">${esc(t("err_api"))}: ${esc(e.message)}</div>`;
    }
  }

  async function loadStats() {
    try {
      const inst = await api("/api/instances");
      state.instances = inst.instances;
      state.names = inst.names || {};
      if (!state.instances.includes(state.instance)) state.instance = state.instances[0] || "";
      state.overview = await api("/api/overview", withInstance());
      $("banner").innerHTML = "";
      renderStats();
    } catch (e) {
      if (e.message !== "unauthorized") $("banner").innerHTML = `<div class="notice bad">${esc(t("err_api"))}: ${esc(e.message)}</div>`;
    }
    try { state.settings = await api("/api/settings"); renderNav(); } catch (e) { /* the badge is optional */ }
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

code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12.5px; direction: ltr; unicode-bidi: isolate; word-break: break-all; }

/* ================================================================ management UI */
.side h2.second { margin-top: 18px; }
.btn.small.icon { width: 32px; padding: 0; justify-content: center; }
.btn:disabled { opacity: .5; cursor: not-allowed; }
.btn.ghost { background: transparent; }
.btn.danger.solid { background: var(--red); border-color: var(--red); color: #fff; }
.btn.danger.solid:hover { filter: brightness(1.08); background: var(--red); }
.row-actions { display: flex; gap: 6px; flex-wrap: nowrap; }
.row-actions .btn.small.icon:hover { border-color: var(--accent); color: var(--accent); }
.row-actions .btn.small.icon.danger:hover { border-color: var(--red); color: var(--red); }
.sub-line { color: var(--muted); font-size: 12px; font-weight: 400; margin-top: 2px; white-space: normal; max-width: 460px; }
.tag { display: inline-block; font-size: 11px; font-weight: 650; padding: 1px 8px; border-radius: 6px; background: var(--card-2); border: 1px solid var(--border); color: var(--muted); margin-inline-start: 8px; vertical-align: middle; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chips code { background: var(--card-2); border: 1px solid var(--border); border-radius: 6px; padding: 1px 7px; font-size: 12px; }

/* forms */
.field.inline { margin: 0; }
.field input, .field select, .field textarea {
  width: 100%; border-radius: 10px; border: 1px solid var(--border-2); background: var(--card-2); padding: 0 14px; color: var(--text); font: inherit;
}
.field input, .field select { height: 42px; }
.field textarea { padding: 10px 14px; min-height: 84px; resize: vertical; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 13px; direction: ltr; text-align: left; }
.field input:focus, .field select:focus, .field textarea:focus { border-color: var(--accent); outline: none; }
.field .hint { color: var(--muted); font-size: 12px; margin: 0; }
.field-row { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.inline-field { display: inline-flex; align-items: center; gap: 8px; }
.inline-field input {
  width: 96px; height: 34px; border-radius: 8px; border: 1px solid var(--border-2); background: var(--card-2); padding: 0 10px; color: var(--text); font: inherit; direction: ltr;
}
.inline-field input:focus { border-color: var(--accent); outline: none; }
.inline-field small { color: var(--muted); }

/* toggle switch */
.switch { position: relative; display: inline-block; width: 40px; height: 22px; }
.switch input { position: absolute; opacity: 0; inset: 0; width: 100%; height: 100%; margin: 0; cursor: pointer; z-index: 1; }
.switch span { position: absolute; inset: 0; border-radius: 999px; background: var(--border-2); transition: background .2s; }
.switch span::after { content: ""; position: absolute; top: 3px; inset-inline-start: 3px; width: 16px; height: 16px; border-radius: 50%; background: #fff; transition: transform .2s; }
.switch input:checked + span { background: var(--accent); }
.switch input:checked + span::after { transform: translateX(18px); }
:root[dir="rtl"] .switch input:checked + span::after { transform: translateX(-18px); }
.switch input:focus-visible + span { outline: 2px solid var(--accent); outline-offset: 2px; }

/* sub cards inside the main panel */
.split { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(340px, 1fr)); align-items: start; }
.subcard { border: 1px solid var(--border); border-radius: 12px; background: var(--card-2); padding: 20px 22px; }
.subcard h3 { margin: 0 0 4px; font-size: 16px; display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.subcard p { color: var(--muted); margin: 6px 0 14px; }
.subcard .field { margin-bottom: 14px; }
.subcard .actions-row { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 6px; }
.steps { margin: 8px 0 16px; padding-inline-start: 20px; color: var(--muted); }
.steps li { margin: 3px 0; }
.codebox { position: relative; background: var(--bg); border: 1px solid var(--border); border-radius: 10px; padding: 12px 14px; margin: 8px 0 12px; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 12.5px; direction: ltr; text-align: left; overflow-x: auto; white-space: pre; }
.notice.warn { background: var(--yellow-soft); border-color: color-mix(in srgb, var(--yellow) 40%, transparent); border-inline-start-color: var(--yellow); }

/* dialog */
dialog.modal { border: 1px solid var(--border-2); border-radius: 16px; background: var(--card); color: var(--text); padding: 0; width: min(560px, calc(100vw - 24px)); max-height: calc(100vh - 32px); box-shadow: 0 24px 80px rgba(0, 0, 0, .55); }
dialog.modal.wide { width: min(900px, calc(100vw - 24px)); }
dialog.modal::backdrop { background: rgba(3, 7, 12, .66); backdrop-filter: blur(2px); }
.modal-form { display: flex; flex-direction: column; max-height: calc(100vh - 32px); }
.modal-form header { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 18px 22px 12px; }
.modal-form header h3 { margin: 0; font-size: 17px; }
.modal-body { padding: 4px 22px 8px; overflow-y: auto; }
.modal-body .field { margin-bottom: 14px; }
.modal-form .form-error { padding: 0 22px; min-height: 0; margin: 0; }
.modal-form .form-error:not(:empty) { padding-top: 6px; padding-bottom: 6px; }
.modal-form footer { display: flex; justify-content: flex-end; gap: 10px; padding: 14px 22px 20px; flex-wrap: wrap; }
pre.logs { margin: 0; background: var(--bg); border: 1px solid var(--border); border-radius: 10px; padding: 12px 14px; height: min(60vh, 520px); overflow: auto; font-size: 12px; line-height: 1.5; direction: ltr; text-align: left; white-space: pre-wrap; word-break: break-all; }

/* toasts */
.toasts { position: fixed; inset-inline-end: 16px; bottom: 16px; display: grid; gap: 8px; z-index: 50; max-width: min(420px, calc(100vw - 32px)); }
.toast { display: flex; gap: 10px; align-items: flex-start; padding: 12px 14px; border-radius: 12px; background: var(--card); border: 1px solid var(--border-2); border-inline-start: 3px solid var(--accent); box-shadow: 0 10px 30px rgba(0, 0, 0, .4); animation: toast-in .2s ease-out; }
.toast.bad { border-inline-start-color: var(--red); }
.toast.warn { border-inline-start-color: var(--yellow); }
@keyframes toast-in { from { transform: translateY(8px); opacity: 0; } }

@media (max-width: 640px) {
  .field-row { grid-template-columns: 1fr; }
  .subcard { padding: 16px; }
  .modal-form header, .modal-body, .modal-form footer { padding-inline: 16px; }
}

code.reason { word-break: normal; overflow-wrap: anywhere; line-height: 1.5; }
__MONITORING_EOF__
  write_file panel/static/favicon.svg 644 <<'__MONITORING_EOF__'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect width="32" height="32" rx="8" fill="#0e1520"/><path d="M16 5l9 3.5v7c0 5.4-3.7 9.2-9 11.5-5.3-2.3-9-6.1-9-11.5v-7L16 5z" fill="none" stroke="#2ee6a6" stroke-width="2" stroke-linejoin="round"/><path d="M10.5 16h3l2-3.5 2.5 7 2-3.5h1.5" fill="none" stroke="#2ee6a6" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>
__MONITORING_EOF__
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
