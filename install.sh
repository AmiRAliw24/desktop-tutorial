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

تم تیره/روشن، فارسی و انگلیسی (با راست‌به‌چپ، فونت وزیرمتن داخلی)، کارت «وضعیت کلی» که مشکلات را خلاصه می‌کند، گیج‌های حلقه‌ای CPU/رم/دیسک با رنگ شدت، اسپارک‌لاین و نمودارهای تعاملی (با نمایش جدولی). کاملاً ریسپانسیو: دسکتاپ با سایدبار، تبلت با نوار آیکون، و گوشی با نوار تب پایین + منوی «بیشتر»، جدول‌ها به کارت و پنجره‌ها به باتم‌شیت تبدیل می‌شوند. صفحه‌ها:

**مانیتورها:** نمای کلی، کانتینرها، سایت‌ها، دیسک‌ها، شبکه، تارگت‌ها، هشدارها.

**مدیریت (همه از پنل):**
- **سایت‌ها:** افزودن/حذف سایت (HTTP/HTTPS) و پورت TCP برای چک آپتایم، زمان پاسخ و انقضای SSL. **رفع خودکار** (پیش‌فرض روشن): اگر سایتی که اضافه می‌کنید یا سایتی که ۵ دقیقه خراب بوده با چک استاندارد کار نکند، پنل خودش بهترین راه را پیدا و اعمال می‌کند: حالت TLS دیگر، یا صفحه‌ای که آدرس `http://` سایت به آن ریدایرکت می‌شود، یا خود `http://`. چکِ سالم هرگز تغییر نمی‌کند و سایتِ واقعاً خاموش دست‌نخورده می‌ماند. هر تغییر در بخش «Automatic adjustments» ثبت می‌شود و از تنظیمات قابل خاموش کردن است. دکمه‌ی ذره‌بین کنار هر ردیف چک را همان لحظه اجرا می‌کند و **دلیل ناموفق بودن** را به زبان ساده می‌گوید (قطع شدن handshake توسط سایت، پورت بسته، DNS، timeout، مشکل گواهی، کد خطای HTTP). برای سایتی که چک استاندارد را رد می‌کند، خودش حالت‌های دیگر (TLS قدیمی ۱.۰/۱.۱، نادیده گرفتن خطای گواهی، HTTP ساده، فقط اتصال TCP) را هم امتحان می‌کند و می‌گوید کدام کار می‌کند؛ با یک کلیک همان حالت برای مانیتور آن سایت فعال می‌شود (کنار آدرس برچسب حالت دیده می‌شود). اگر سایت فقط با HTTP ساده در دسترس باشد و HTTPS را برای این سرور رد کند، دکمه‌ی «مانیتور روی HTTP ساده» آدرس را (با حفظ نام) به `http://` تغییر می‌دهد.
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
    "/fonts.css": ("fonts.css", "text/css; charset=utf-8"),
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
       "img-src 'self' data:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
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
    return {**{k: store.list_targets(k) for k in store.KINDS}, "auto": {"enabled": store.auto_enabled(), "events": store.auto_events()}}


def api_rules(_q):
    return {"rules": store.get_rules()}


def api_settings(_q):
    return {"user": auth.user, "version": VERSION, "auto_fix": store.auto_enabled(),
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


def post_checks_autofix(b, _h):
    target = str(b.get("target", "")).strip()
    if not any(r["target"] == target for r in store.list_targets("http")):
        raise store.ConfigError("Only monitored addresses can be fixed")
    return {"ok": True, "event": store.auto_fix(target)}


def post_auto_setting(b, _h):
    store.set_auto_enabled(b.get("enabled", True))
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
    "/api/checks/add": post_checks_add, "/api/checks/remove": post_checks_remove, "/api/checks/probe": post_checks_probe, "/api/checks/mode": post_checks_mode, "/api/checks/replace": post_checks_replace, "/api/checks/autofix": post_checks_autofix, "/api/settings/auto": post_auto_setting,
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
    threading.Thread(target=store.auto_loop, daemon=True).start()
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
from urllib.parse import urlencode, urljoin, urlparse
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
                         "mode": MODE_BY_MODULE.get(labels.get("check_module", ""), "default") if kind == "http" else "default",
                         "auto_from": labels.get("auto_from", "")})
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
    if kind == "http":
        auto_fix_async(target)


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
    redirects = [m.group(1).strip('"') for m in re.finditer(r'msg="Received redirect" location=("(?:[^"\\]|\\.)*"|\S+)', text)]
    return {"ok": ok, "reason": reason, "kind": "" if ok else classify_failure(reason, http_status), "http_status": http_status,
            "redirects": redirects, "log": "\n".join(l for l in text.splitlines() if not l.startswith("#"))[-20000:]}


def final_url(start, redirects):
    """Where a chain of (possibly relative) redirects ends. Empty if there were none."""
    url = start
    for location in redirects:
        url = urljoin(url, location)
    return url if redirects else ""


def _variant_plan(target, mode):
    """Other ways to check the same website: (id, blackbox module, address to probe)."""
    parsed = urlparse(target)
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    host = f"[{parsed.hostname}]" if ":" in (parsed.hostname or "") else parsed.hostname
    plan = [(m, HTTP_MODES[m], target) for m in HTTP_MODES if m != mode]
    if parsed.scheme == "https":
        plan.append(("plain_http", "http_2xx", "http://" + target[len("https://"):]))
    plan.append(("tcp", "tcp_connect", f"{host}:{port}"))
    return plan


def _run_variants(target, mode):
    """Probe every variant in parallel. Returns [(id, probed address, result)]."""
    plan = _variant_plan(target, mode)
    with ThreadPoolExecutor(max_workers=len(plan)) as pool:
        outcomes = list(pool.map(lambda p: _blackbox(p[1], p[2]), plan))
    return [(vid, vtarget, out) for (vid, _module, vtarget), out in zip(plan, outcomes)]


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
    for vid, vtarget, out in _run_variants(target, mode):
        result["variants"].append({"id": vid, "ok": out["ok"], "reason": out["reason"], "kind": out["kind"],
                                   "http_status": out["http_status"],
                                   "final_url": final_url(vtarget, out["redirects"]) if vid == "plain_http" else ""})
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


def replace_target(kind, old, new, extra_labels=None):
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
        labels.update(extra_labels or {})
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


# ------------------------------------------------------------------ automatic fixing of failing websites

AUTO_COOLDOWN = 1800          # seconds between automatic attempts for the same address
_auto_last, _auto_busy = {}, set()
SECURE_MODES = ("legacy_tls", "no_verify", "legacy_no_verify")


def auto_enabled():
    return bool(load_settings().get("auto_fix", True))


def set_auto_enabled(enabled):
    with LOCK:
        s = load_settings()
        s["auto_fix"] = bool(enabled)
        save_settings(s)


def auto_events(limit=10):
    return list(reversed(load_settings().get("auto_events", [])[-limit:]))


def _record_event(**event):
    with LOCK:
        s = load_settings()
        s["auto_events"] = (s.get("auto_events", []) + [{"t": int(time.time()), **event}])[-30:]
        save_settings(s)


def auto_fix(target):
    """Find the best way to monitor a website that fails its standard check, and apply it.

    Never touches a check that currently passes. Order of preference: another TLS mode on the same
    address, then the address the site's plain http:// version finally redirects to (if that passes a
    standard check), then the plain http:// address itself. Returns the recorded event or None."""
    row = next((r for r in list_targets("http") if r["target"] == target), None)
    if row is None:
        return None
    if _blackbox(HTTP_MODES[row["mode"]], target)["ok"]:
        return None
    outcomes = _run_variants(target, row["mode"])
    ok = {vid: (vtarget, out) for vid, vtarget, out in outcomes if out["ok"]}
    mode = next((m for m in SECURE_MODES if m in ok), None)
    if mode:
        set_mode("http", target, mode)
        event = {"action": "mode", "from": target, "mode": mode}
    elif "plain_http" in ok:
        plain_url, out = ok["plain_http"]
        new = plain_url
        landing = final_url(plain_url, out["redirects"])
        if landing.startswith("https://") and landing != target and _blackbox("http_2xx", landing)["ok"]:
            new = landing                                   # the page users really reach, with its real certificate
        event = {"action": "replace", "from": target, "to": new}
        existing = {r["target"] for r in list_targets("http")}
        if new in existing:                                 # already monitored: the failing entry is just a duplicate
            remove_target("http", target)
            event["action"] = "merge"
        else:
            replace_target("http", target, new, {"auto_from": target})
    else:
        return None
    _record_event(**event)
    return event


def auto_fix_async(target):
    """Run auto_fix in the background right after a site is added."""
    if not auto_enabled():
        return

    def run():
        try:
            _auto_last[target] = time.time()
            auto_fix(target)
        except Exception:        # background helper: a failure must never break adding a site
            pass
        finally:
            _auto_busy.discard(target)

    if target not in _auto_busy:
        _auto_busy.add(target)
        threading.Thread(target=run, daemon=True).start()


def auto_scan():
    """Called periodically: fix websites that have failed for the last five minutes."""
    if not auto_enabled():
        return
    import monitor
    down = {m.get("instance", "") for m, _ in monitor.vector('min_over_time(probe_success{job="blackbox-http"}[5m]) == 0')}
    managed = {r["target"] for r in list_targets("http")}
    for target in sorted(down & managed):
        if time.time() - _auto_last.get(target, 0) >= AUTO_COOLDOWN and target not in _auto_busy:
            _auto_last[target] = time.time()
            try:
                auto_fix(target)
            except Exception:
                pass


def auto_loop():
    time.sleep(90)
    while True:
        try:
            auto_scan()
        except Exception:
            pass
        time.sleep(300)


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
    live = {m.get("instance", "") for m, v in rows if v}
    # Reachable servers first, so the panel opens on one that actually has data.
    order = sorted(set(names) - {""}, key=lambda i: (i not in live, i))
    return {"instances": order, "names": {k: v for k, v in names.items() if k and v}}


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
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Server Monitor</title>
  <link rel="icon" href="data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%2032%2032%22%3E%3Crect%20width=%2232%22%20height=%2232%22%20rx=%228%22%20fill=%22%230e1520%22/%3E%3Cpath%20d=%22M16%205l9%203.5v7c0%205.4-3.7%209.2-9%2011.5-5.3-2.3-9-6.1-9-11.5v-7L16%205z%22%20fill=%22none%22%20stroke=%22%232ee6a6%22%20stroke-width=%222%22%20stroke-linejoin=%22round%22/%3E%3Cpath%20d=%22M10.5%2016h3l2-3.5%202.5%207%202-3.5h1.5%22%20fill=%22none%22%20stroke=%22%232ee6a6%22%20stroke-width=%221.8%22%20stroke-linecap=%22round%22%20stroke-linejoin=%22round%22/%3E%3C/svg%3E" type="image/svg+xml">
  <link rel="icon" href="/favicon-32.png" type="image/png" sizes="32x32">
  <link rel="shortcut icon" href="/favicon.ico">
  <link rel="apple-touch-icon" href="/apple-touch-icon.png">
  <meta name="theme-color" content="#0a0f16">
  <link rel="stylesheet" href="/fonts.css">
  <link rel="stylesheet" href="/style.css">
  <script src="/app.js" defer></script>
</head>
<body>
  <div class="app">
    <aside class="sidebar">
      <div class="brand">
        <div class="logo" id="logo"></div>
        <div class="brand-text">
          <h1 data-i18n="title">Server Monitor</h1>
          <small id="hostline">&nbsp;</small>
        </div>
      </div>
      <h2 data-i18n="monitors">Monitors</h2>
      <nav class="nav" id="nav"></nav>
      <h2 class="second" data-i18n="manage">Manage</h2>
      <nav class="nav" id="nav-manage"></nav>
    </aside>

    <div class="main">
      <header class="topbar">
        <div class="top-left">
          <div class="logo top-brand" id="top-logo"></div>
          <h2 class="top-title" id="page-title"></h2>
          <div class="live"><i class="pulse"></i><span id="foot"></span></div>
        </div>
        <div class="actions">
          <button class="btn icon" id="theme" type="button" aria-label="Theme"></button>
          <button class="btn" id="lang" type="button"></button>
          <button class="btn" id="refresh" type="button"></button>
          <button class="btn danger" id="logout" type="button"></button>
        </div>
      </header>

      <div class="content">
        <div id="banner"></div>
        <section class="stats" id="stats" aria-live="polite"></section>
        <main class="card panel" id="panel"></main>
      </div>
    </div>
  </div>

  <nav class="tabbar" id="tabbar" aria-label="Main"></nav>
  <div class="toasts" id="toasts" aria-live="polite"></div>
</body>
</html>
__MONITORING_EOF__
  write_file panel/static/login.html 644 <<'__MONITORING_EOF__'
<!doctype html>
<html lang="en" data-theme="dark">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Sign in - Server Monitor</title>
  <link rel="icon" href="data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%2032%2032%22%3E%3Crect%20width=%2232%22%20height=%2232%22%20rx=%228%22%20fill=%22%230e1520%22/%3E%3Cpath%20d=%22M16%205l9%203.5v7c0%205.4-3.7%209.2-9%2011.5-5.3-2.3-9-6.1-9-11.5v-7L16%205z%22%20fill=%22none%22%20stroke=%22%232ee6a6%22%20stroke-width=%222%22%20stroke-linejoin=%22round%22/%3E%3Cpath%20d=%22M10.5%2016h3l2-3.5%202.5%207%202-3.5h1.5%22%20fill=%22none%22%20stroke=%22%232ee6a6%22%20stroke-width=%221.8%22%20stroke-linecap=%22round%22%20stroke-linejoin=%22round%22/%3E%3C/svg%3E" type="image/svg+xml">
  <link rel="icon" href="/favicon-32.png" type="image/png" sizes="32x32">
  <link rel="shortcut icon" href="/favicon.ico">
  <link rel="apple-touch-icon" href="/apple-touch-icon.png">
  <meta name="theme-color" content="#0a0f16">
  <link rel="stylesheet" href="/fonts.css">
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
      h_ok: "Everything is healthy", h_ok_sub: "The server and all of your checks are working normally.", h_warn: "Needs your attention", h_bad: "Problems detected",
      i_alerts: "{n} active alert(s)", i_sites: "{n} website/port check(s) failing", i_targets: "{n} monitoring target(s) not responding",
      i_res: "{what} is high ({v}%)", i_pending: "{n} alert(s) about to fire", i_ssl: "an SSL certificate expires in {n} day(s)",
      lv_ok: "Normal", lv_warn: "High", lv_bad: "Critical", more: "More", tbl_view: "Table view", time: "Time",
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
      diag_plain: "Plain HTTP works, but every secure (HTTPS) attempt is rejected, whatever the TLS mode. The site is up; its HTTPS side refuses this server. You can monitor it over plain HTTP instead (if that address redirects to an HTTPS page, that page's certificate is still checked).",
      diag_use_http: "Monitor over plain HTTP instead", diag_replaced: "Now monitoring the plain HTTP address.",
      diag_closed: "Even a plain TCP connection fails: the address is unreachable from this server (down, wrong port, or blocked).",
      auto_title: "Automatic fixing of failing websites",
      auto_text: "When a website keeps failing, the panel tries other ways to check it (old TLS, ignoring certificate errors, the page its http:// address redirects to, plain http://) and switches to the first one that works. A check that works is never changed. Turn it off to keep your addresses exactly as typed.",
      auto_on: "Fix failing websites automatically", auto_off_saved: "Automatic fixing is off", auto_on_saved: "Automatic fixing is on",
      auto_log: "Automatic adjustments", auto_tag: "auto", auto_was: "was {from}",
      auto_ev_replace: "{from} is now monitored as {to}", auto_ev_mode: "{from} is now checked with: {mode}", auto_ev_merge: "{from} was removed: {to} is already monitored",
      auto_fix_btn: "Fix automatically", auto_done: "Done. The status updates within a minute.",
      auto_none: "Nothing better was found: no other way of checking this address works from the server.",
      added_auto: "Added. The panel is choosing the best way to monitor it automatically.", redirects_to: "redirects to",
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
      h_ok: "همه چیز سالم است", h_ok_sub: "سرور و تمام بررسی‌های شما عادی کار می‌کنند.", h_warn: "نیاز به توجه دارد", h_bad: "مشکل شناسایی شد",
      i_alerts: "{n} هشدار فعال", i_sites: "{n} بررسی سایت/پورت ناموفق است", i_targets: "{n} هدف مانیتورینگ پاسخ نمی‌دهد",
      i_res: "{what} بالا است ({v}٪)", i_pending: "{n} هشدار در آستانه‌ی فعال شدن", i_ssl: "گواهی SSL تا {n} روز دیگر منقضی می‌شود",
      lv_ok: "عادی", lv_warn: "بالا", lv_bad: "بحرانی", more: "بیشتر", tbl_view: "نمایش جدول", time: "زمان",
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
      diag_plain: "HTTP ساده کار می‌کند ولی هر تلاش امن (HTTPS) با هر حالت TLS رد می‌شود. سایت بالاست؛ بخش HTTPS آن این سرور را رد می‌کند. می‌توانید به‌جای آن روی HTTP ساده مانیتورش کنید (اگر آن آدرس به یک صفحه‌ی HTTPS ریدایرکت شود، گواهی همان صفحه همچنان چک می‌شود).",
      diag_use_http: "مانیتور روی HTTP ساده", diag_replaced: "حالا آدرس HTTP ساده مانیتور می‌شود.",
      diag_closed: "حتی اتصال ساده‌ی TCP هم ناموفق است: آدرس از این سرور در دسترس نیست (خاموش، پورت اشتباه یا مسدود).",
      auto_title: "رفع خودکار سایت‌های خراب",
      auto_text: "وقتی سایتی مدام ناموفق است، پنل راه‌های دیگر چک را امتحان می‌کند (TLS قدیمی، نادیده گرفتن خطای گواهی، صفحه‌ای که آدرس http:// به آن ریدایرکت می‌شود، HTTP ساده) و روی اولین راهی که کار کند می‌رود. چکِ سالم هرگز تغییر نمی‌کند. برای اینکه آدرس‌ها دقیقاً همان‌طور که وارد کردید بمانند، خاموشش کنید.",
      auto_on: "سایت‌های خراب را خودکار درست کن", auto_off_saved: "رفع خودکار خاموش شد", auto_on_saved: "رفع خودکار روشن شد",
      auto_log: "تنظیمات خودکار", auto_tag: "خودکار", auto_was: "قبلاً {from}",
      auto_ev_replace: "{from} حالا به‌صورت {to} مانیتور می‌شود", auto_ev_mode: "{from} حالا با این حالت چک می‌شود: {mode}", auto_ev_merge: "{from} حذف شد: {to} از قبل مانیتور می‌شود",
      auto_fix_btn: "رفع خودکار", auto_done: "انجام شد. وضعیت تا یک دقیقه‌ی دیگر بروز می‌شود.",
      auto_none: "راه بهتری پیدا نشد: هیچ راه دیگری برای چک این آدرس از سرور کار نمی‌کند.",
      added_auto: "اضافه شد. پنل خودکار بهترین راه مانیتور آن را انتخاب می‌کند.", redirects_to: "ریدایرکت می‌شود به",
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
    shield: '<path d="M12 3l8 3v6c0 4.6-3.2 7.9-8 9.8C7.2 19.9 4 16.6 4 12V6l8-3z"/><path d="M8.5 12.2l2.4 2.4 4.6-4.8"/>',
    alert: '<path d="M12 3.6l9.4 16.4H2.6L12 3.6z"/><path d="M12 10v4.4M12 17.4h.01"/>',
    octagon: '<path d="M8.2 3h7.6L21 8.2v7.6L15.8 21H8.2L3 15.8V8.2L8.2 3z"/><path d="M9.2 9.2l5.6 5.6M14.8 9.2l-5.6 5.6"/>',
    dots: '<circle cx="5" cy="12" r="1.3"/><circle cx="12" cy="12" r="1.3"/><circle cx="19" cy="12" r="1.3"/>',
    table: '<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M9 4v16"/>',
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
    $("top-logo").innerHTML = icon("logo");
    $("theme").innerHTML = icon(state.theme === "dark" ? "sun" : "moon");
    $("theme").setAttribute("aria-label", state.theme === "dark" ? t("t_dark") : t("t_light"));
    $("theme").title = $("theme").getAttribute("aria-label");
    $("lang").innerHTML = `${icon("globe")}<span class="txt">${esc(t("lang_switch"))}</span>`;
    $("refresh").innerHTML = `${icon("refresh")}<span class="txt">${esc(t("refresh"))}</span>`;
    $("logout").innerHTML = `${icon("logout")}<span class="txt">${esc(t("logout"))}</span>`;
    for (const id of ["lang", "refresh", "logout"]) $(id).title = $(id).textContent.trim();
    document.querySelector('meta[name="theme-color"]').setAttribute("content", state.theme === "dark" ? "#070b12" : "#eef2f8");
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
  const TAB_IDS = ["overview", "containers", "websites", "alerts"];   // the rest live behind "More" on phones
  function renderNav() {
    const link = (v) => `<a href="#${v.id}" class="${v.id === state.view ? "active" : ""}" ${v.id === state.view ? 'aria-current="page"' : ""} title="${esc(t(v.label))}">${icon(v.icon)}<span class="name">${esc(t(v.label))}</span>${badgeFor(v.id)}</a>`;
    $("nav").innerHTML = VIEWS.filter((v) => v.group === "monitor").map(link).join("");
    $("nav-manage").innerHTML = VIEWS.filter((v) => v.group === "manage").map(link).join("");
    const cur = VIEWS.find((v) => v.id === state.view) || VIEWS[0];
    $("page-title").textContent = t(cur.label);
    const firing = state.overview ? state.overview.alerts.firing : 0;
    const tab = (v) => `<button type="button" data-go="${v.id}" class="${v.id === state.view ? "active" : ""}" ${v.id === state.view ? 'aria-current="page"' : ""}>${icon(v.icon)}<span class="lbl">${esc(t(v.label))}</span>${v.id === "alerts" && firing ? `<span class="dot">${firing}</span>` : ""}</button>`;
    $("tabbar").innerHTML = TAB_IDS.map((id) => tab(VIEWS.find((v) => v.id === id))).join("")
      + `<button type="button" data-more class="${TAB_IDS.includes(cur.id) ? "" : "active"}">${icon("dots")}<span class="lbl">${esc(t("more"))}</span></button>`;
  }

  // Phones: every view that has no tab sits in a bottom sheet.
  function moreSheet() {
    const dlg = document.createElement("dialog");
    dlg.className = "sheet";
    dlg.innerHTML = `<div class="sheet-card"><h3>${esc(t("more"))}</h3><div class="sheet-grid">${VIEWS.filter((v) => !TAB_IDS.includes(v.id)).map((v) =>
      `<button type="button" data-go="${v.id}" class="${v.id === state.view ? "active" : ""}">${icon(v.icon)}<span>${esc(t(v.label))}</span></button>`).join("")}</div></div>`;
    dlg.addEventListener("click", (e) => { if (e.target === dlg || e.target.closest("[data-go]")) dlg.close(); });
    dlg.addEventListener("close", () => dlg.remove());
    document.body.appendChild(dlg);
    dlg.showModal();
  }

  // ---------------------------------------------------------------- overview: health hero, gauges, tiles
  state.hist = {};
  const SPARK_W = 120, SPARK_H = 34;
  function sparkline(points, color) {
    const pts = (points || []).filter((p) => p[1] != null);
    if (pts.length < 2) return "";
    const xs = pts.map((p) => p[0]), vs = pts.map((p) => p[1]);
    const x0 = Math.min(...xs), x1 = Math.max(...xs), lo = Math.min(...vs), hi = Math.max(...vs), pad = (hi - lo) * 0.18 || 1;
    const X = (ts) => ((ts - x0) / Math.max(1, x1 - x0)) * SPARK_W;
    const Y = (v) => 4 + (1 - (v - (lo - pad * 0.2)) / (hi - lo + pad * 1.2)) * (SPARK_H - 8);
    const d = pts.map((p, i) => `${i ? "L" : "M"}${X(p[0]).toFixed(1)},${Y(p[1]).toFixed(1)}`).join("");
    const last = pts[pts.length - 1];
    return `<svg viewBox="0 0 ${SPARK_W} ${SPARK_H}" preserveAspectRatio="none" aria-hidden="true"><path d="${d}L${SPARK_W},${SPARK_H}L0,${SPARK_H}Z" fill="${color}" opacity=".11"/><path d="${d}" fill="none" stroke="${color}" stroke-width="2" vector-effect="non-scaling-stroke" stroke-linejoin="round" stroke-linecap="round"/></svg><i class="sd" style="top:${Y(last[1]).toFixed(1)}px;background:${color}"></i>`;
  }
  const sparkBox = (key, idx, color) => `<div class="spark" data-spark="${key}" data-idx="${idx}" data-color="${color}">${sparkline(((state.hist[key] || [])[idx] || {}).points, `var(${color})`)}</div>`;
  function refreshSparks() {
    document.querySelectorAll("[data-spark]").forEach((el) => {
      const s = (state.hist[el.dataset.spark] || [])[+el.dataset.idx];
      el.innerHTML = sparkline(s && s.points, `var(${el.dataset.color})`);
    });
  }

  function health(o, memPct) {
    const issues = [];
    let sev = 0;
    const bump = (n, msg) => { issues.push(msg); sev = Math.max(sev, n); };
    if (o.alerts.firing) bump(2, t("i_alerts", { n: o.alerts.firing }));
    if (o.checks.total > o.checks.up) bump(2, t("i_sites", { n: o.checks.total - o.checks.up }));
    if (o.targets.total > o.targets.up) bump(2, t("i_targets", { n: o.targets.total - o.targets.up }));
    for (const [what, v] of [[t("cpu"), o.cpu], [t("memory"), memPct], [t("disk"), o.disk ? o.disk.pct : null]]) {
      if (v == null) continue;
      if (v >= 90) bump(2, t("i_res", { what, v: nf(v, 0) }));
      else if (v >= 75) bump(1, t("i_res", { what, v: nf(v, 0) }));
    }
    if (o.alerts.pending) bump(1, t("i_pending", { n: o.alerts.pending }));
    const ssl = o.checks.min_ssl_days;
    if (ssl != null && ssl < 14) bump(ssl < 7 ? 2 : 1, t("i_ssl", { n: nf(ssl, 0) }));
    return { sev, issues };
  }

  const ringSvg = (pct) => {
    const C = 2 * Math.PI * 42, v = Math.min(100, Math.max(0, pct || 0));
    return `<svg viewBox="0 0 104 104" aria-hidden="true"><circle class="track" cx="52" cy="52" r="42" fill="none" stroke-width="10"/><circle class="fill" cx="52" cy="52" r="42" fill="none" stroke-width="10" stroke-dasharray="${((C * v) / 100).toFixed(1)} ${C.toFixed(1)}"/></svg>`;
  };
  const LVL = { "": "lv_ok", warn: "lv_warn", bad: "lv_bad" };
  function gauge({ label, ic, pct, main, sub = "", go = "", spark = "" }) {
    const lv = pct == null ? "" : level(pct);
    return `<div class="card stat gauge ${lv}" ${go ? `data-go="${go}" role="link" tabindex="0"` : ""}>
      <div class="ring ${lv}">${ringSvg(pct)}<div class="center"><span class="value num">${pct == null ? "–" : `${nf(pct, 0)}<small>%</small>`}</span></div></div>
      <div class="g-title">${icon(ic)}${esc(label)}</div>
      <div class="g-main">${main}</div>
      <div class="sub"><span class="lvl">${esc(t(LVL[lv]))}</span>${sub ? `<br>${sub}` : ""}</div>
      ${spark}
    </div>`;
  }
  function tile({ label, ic, value, sub = "", go = "", cls = "", tight = false, spark = "" }) {
    return `<div class="card stat ${cls}" ${go ? `data-go="${go}" role="link" tabindex="0"` : ""}><div class="label">${icon(ic)}${esc(label)}</div><div class="value${tight ? " tight" : ""}">${value}</div>${sub ? `<div class="sub">${sub}</div>` : ""}${spark}</div>`;
  }

  function renderStats() {
    const o = state.overview;
    if (!o) return;
    const memPct = o.mem.total ? (o.mem.used / o.mem.total) * 100 : null;
    const d = o.disk;
    const { sev, issues } = health(o, memPct);
    const tone = ["", "warn", "bad"][sev];
    const chips = [
      o.host.name ? `<span class="chip">${icon("server")}<b>${num(esc(o.host.name))}</b></span>` : "",
      o.host.os ? `<span class="chip">${num(esc(o.host.os))}</span>` : "",
      o.host.cores != null ? `<span class="chip">${icon("cpu")}<b>${num(nf(o.host.cores, 0))}</b> ${esc(t("cores"))}</span>` : "",
    ].join("");
    const hero = `<section class="card hero ${tone}"><div class="hero-icon">${icon(["shield", "alert", "octagon"][sev])}</div>
      <div class="hero-text"><h2>${esc(t("h_" + ["ok", "warn", "bad"][sev]))}</h2><p>${esc(issues.length ? issues.join(" · ") : t("h_ok_sub"))}</p></div>
      <div class="hero-meta">${chips}</div></section>`;
    const gauges = [
      gauge({ label: t("cpu"), ic: "cpu", pct: o.cpu, main: o.host.cores != null ? `${num(nf(o.host.cores, 0))} ${esc(t("cores"))}` : "", sub: o.host.cpu_model ? num(esc(o.host.cpu_model)) : "", spark: sparkBox("cpu", 0, "--c1") }),
      gauge({ label: t("memory"), ic: "memory", pct: memPct, main: `${num(fmtBytes(o.mem.used))} ${esc(t("of"))} ${num(fmtBytes(o.mem.total))}`, spark: sparkBox("mem", 0, "--c3") }),
      gauge({ label: t("disk"), ic: "disk", pct: d ? d.pct : null, go: "disks", main: d ? `${num(fmtBytes(d.used))} ${esc(t("of"))} ${num(fmtBytes(d.total))}` : "", sub: d ? num(esc(d.mount)) : "" }),
    ].join("");
    const tiles = [
      tile({ label: t("net_down"), ic: "down", go: "network", value: num(fmtRate(o.net.rx)), spark: sparkBox("net", 0, "--c1") }),
      tile({ label: t("net_up"), ic: "up", go: "network", value: num(fmtRate(o.net.tx)), spark: sparkBox("net", 1, "--c2") }),
      tile({ label: t("load"), ic: "activity", tight: true, value: num(o.load.map((x) => nf(x, 2)).join(" / ")) }),
      tile({ label: t("containers"), ic: "box", go: "containers", value: num(o.containers), sub: esc(t("running")) }),
      tile({ label: t("targets"), ic: "check", go: "targets", value: num(`${o.targets.up} / ${o.targets.total}`) }),
      tile({ label: t("websites"), ic: "globe", go: "websites", value: num(`${o.checks.up} / ${o.checks.total}`) }),
      tile({ label: t("ssl"), ic: "lock", go: "websites", value: o.checks.min_ssl_days == null ? "–" : num(`${nf(o.checks.min_ssl_days, 0)} <small>${t("days")}</small>`) }),
      tile({ label: t("alerts"), ic: "bell", go: "alerts", cls: o.alerts.firing ? "alert-on" : "", value: o.alerts.firing ? num(o.alerts.firing) : `<span class="ok-mark">${icon("okmark")}</span>` }),
    ].join("");
    $("stats").innerHTML = `${hero}<div class="gauges">${gauges}</div><div class="tiles">${tiles}</div>`;
    $("hostline").textContent = [o.host.name, o.host.os].filter(Boolean).join(" · ") || " ";
    renderNav();
  }

  // ---------------------------------------------------------------- tables
  function table(cols, rows, rowAttrs) {
    if (!rows.length) return `<div class="table-wrap"><div class="empty">${esc(t("empty"))}</div></div>`;
    const head = cols.map((c) => `<th>${c.raw ? c.h : esc(t(c.h))}</th>`).join("");
    const body = rows.map((r) => `<tr${rowAttrs ? " " + rowAttrs(r) : ""}>${cols.map((c) => `<td class="${c.cls || ""}" data-label="${c.raw ? "" : esc(t(c.h))}">${c.cell(r)}</td>`).join("")}</tr>`).join("");
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
          { h: "target", cls: "strong", cell: (r) => `${num(esc(r.target))}${r.mode && r.mode !== "default" ? `<span class="tag">${esc(t("mode_" + r.mode))}</span>` : ""}${r.auto_from ? `<span class="tag" title="${esc(t("auto_was", { from: r.auto_from }))}">${esc(t("auto_tag"))}</span>` : ""}${r.name ? `<div class="sub-line">${esc(r.name)}</div>` : ""}` },
          { h: "type", cell: (r) => pill("info", r.kind.toUpperCase(), false) },
          { h: "status", cell: (r) => statusPill(r.m && r.m.up, !!r.m) },
          { h: "response", cell: (r) => num(r.m ? fmtMs(r.m.duration) : "–") },
          { h: "http", cell: (r) => num(r.m && r.m.http ? r.m.http : "–") },
          { h: "ssl_h", cell: (r) => (!r.m || r.m.ssl_days == null ? "–" : pill(r.m.ssl_days < 7 ? "bad" : r.m.ssl_days < 14 ? "warn" : "ok", nf(r.m.ssl_days, 0), false)) },
          { h: "actions", cell: (r) => `<div class="row-actions">${btnIcon("search", t("probe"), `data-act="probe" data-kind="${r.kind}" data-target="${esc(r.target)}"`)}${r.fixed ? "" : btnIcon("trash", t("remove"), `data-act="del" data-kind="${r.kind}" data-target="${esc(r.target)}"`, "danger")}</div>` },
        ];
        const events = (checks.auto && checks.auto.events) || [];
        const evText = (e) => (e.action === "mode" ? t("auto_ev_mode", { from: e.from, mode: t("mode_" + e.mode) }) : e.action === "merge" ? t("auto_ev_merge", { from: e.from, to: e.to }) : t("auto_ev_replace", { from: e.from, to: e.to }));
        const log = events.length ? `<div class="subcard" style="margin-top:18px"><h3>${icon("check")}${esc(t("auto_log"))}</h3><ul class="steps">${events.slice(0, 5).map((e) => `<li><span class="muted">${esc(new Date(e.t * 1000).toLocaleString())}</span> · ${esc(evText(e))}</li>`).join("")}</ul></div>` : "";
        return { html: table(cols, rows) + `<p class="muted" style="margin-top:12px">${esc(t("w_hint"))}</p>` + log, tools: addButton("btn-add-site", t("add_site")) };
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
          { h: "error", cls: "wrap-cell", cell: (r) => (r.error ? `<span style="color:var(--s-bad)">${esc(r.error)}</span>` : "") },
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
            <section class="subcard"><h3>${icon("check")}${esc(t("auto_title"))}</h3><p>${esc(t("auto_text"))}</p>
              <label style="display:flex;align-items:center;gap:12px;cursor:pointer"><span class="switch"><input type="checkbox" id="auto-toggle" ${s.auto_fix ? "checked" : ""}><span></span></span><b>${esc(t("auto_on"))}</b></label></section>
            <section class="subcard"><h3>${icon("server")}${esc(t("st_about"))}</h3>
              <p>${esc(t("st_version"))}: ${num(esc(s.version))}</p></section></div></div>`;
        return { html, tools: "" };
      },
      bind(root) {
        root.querySelector("#auto-toggle").addEventListener("change", async (e) => {
          const on = e.currentTarget.checked;
          if (await act(e.currentTarget, () => post("/api/settings/auto", { enabled: on }), t(on ? "auto_on_saved" : "auto_off_saved"))) state.settings = { ...state.settings, auto_fix: on };
          else e.currentTarget.checked = !on;
        });
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
              return `<tr><td>${v.ok ? pill("ok", t("diag_works")) : pill("bad", t("diag_fails"))}</td><td class="strong" style="white-space:normal">${esc(label)}${apply ? `<div style="margin-top:8px">${apply}</div>` : ""}</td><td class="wrap-cell muted" style="min-width:300px">${v.ok ? (v.final_url ? `${esc(t("redirects_to"))} <code class="reason">${esc(v.final_url)}</code>` : "") : `<code class="reason">${esc(v.reason)}</code>`}</td></tr>`;
            }).join("");
            const httpFix = !secureOk && by.plain_http && by.plain_http.ok && target.startsWith("https://")
              ? `<p><button type="button" class="btn small primary" data-replace="http://${esc(target.slice(8))}">${esc(t("diag_use_http"))}</button></p>` : "";
            const autoBtn = r.variants.some((v) => v.ok && (v.id in { legacy_tls: 1, no_verify: 1, legacy_no_verify: 1 } || v.id === "plain_http"))
              ? `<p><button type="button" class="btn primary" data-autofix>${esc(t("auto_fix_btn"))}</button></p>` : "";
            diag = `<h4 style="margin:18px 0 8px">${esc(t("diag_title"))}</h4>${autoBtn}<p class="muted">${esc(note)}</p>${httpFix}<div class="table-wrap"><table><tbody>${rows}</tbody></table></div>`;
          }
          out.innerHTML = `<div class="notice ${r.ok ? "ok" : "bad"}">${icon(r.ok ? "okmark" : "bell")}<span><b>${esc(t(r.ok ? "probe_ok" : "probe_fail"))}</b>${status}</span></div>
            ${r.ok ? "" : `<p>${esc(t("probe_k_" + (r.kind || "other")))}</p>`}
            ${r.reason ? `<p><b>${esc(t("probe_reason"))}:</b> <code>${esc(r.reason)}</code></p>` : ""}
            ${diag}
            ${r.ok ? "" : `<p class="muted">${esc(t("probe_hint"))}</p>`}
            <details><summary>${esc(t("probe_log"))}</summary><pre class="logs" style="height:280px;margin-top:10px">${esc(r.log)}</pre></details>`;
          out.querySelectorAll("[data-autofix]").forEach((b) => b.addEventListener("click", async () => {
            const res = await act(b, () => post("/api/checks/autofix", { target }));
            if (!res) return;
            toast(res.event ? t("auto_done") : t("auto_none"), res.event ? "" : "warn");
            dlg.close(); renderView(false);
          }));
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
        toast(kind === "http" && state.settings && state.settings.auto_fix ? t("added_auto") : t("added"));
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
  // One categorical slot per series, in fixed order (blue, orange, aqua); text never wears a series colour.
  const CHARTS = [
    { m: "cpu", title: "c_cpu", fmt: (v) => `${nf(v)}%`, max: 100, colors: ["--c1"], now: true },
    { m: "mem", title: "c_mem", fmt: (v) => `${nf(v)}%`, max: 100, colors: ["--c3"], now: true },
    { m: "net", title: "c_net", fmt: fmtRate, colors: ["--c1", "--c2"], names: ["rx", "tx"] },
    { m: "load", title: "c_load", fmt: (v) => nf(v, 2), colors: ["--c1", "--c2", "--c3"] },
  ];
  const niceMax = (v) => {
    if (!(v > 0)) return 1;
    const p = 10 ** Math.floor(Math.log10(v));
    return [1, 2, 2.5, 5, 10].map((x) => x * p).find((x) => x >= v);
  };
  const seriesName = (cfg, s, i) => (cfg.names ? t(cfg.names[i]) : s.name);
  const hhmm = (d) => `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

  function drawChart(box, cfg, series, uid) {
    const all = series.flatMap((s) => s.points.filter((p) => p[1] != null));
    // A line needs at least two samples at different times; right after startup there is only one.
    if (new Set(all.map((p) => p[0])).size < 2) { box.innerHTML = `<div class="empty">${esc(t("no_data"))}</div>`; return; }
    const bw = Math.round(box.clientWidth) || 600, compact = bw < 420;
    const W = Math.max(240, bw), H = compact ? 170 : 190, L = compact ? 42 : 52, R = 10, TOP = 12, B = 24;
    const x0 = Math.min(...all.map((p) => p[0])), x1 = Math.max(...all.map((p) => p[0])) || x0 + 1;
    const ymax = cfg.max || niceMax(Math.max(...all.map((p) => p[1])) * 1.1);
    const X = (ts) => L + ((ts - x0) / Math.max(1, x1 - x0)) * (W - L - R);
    const Y = (v) => TOP + (1 - v / ymax) * (H - TOP - B);
    const colors = cfg.colors.map((c) => `var(${c})`);

    let grid = "";
    for (let i = 0; i <= 4; i++) {
      const v = (ymax * i) / 4, y = Y(v);
      grid += `<line x1="${L}" x2="${W - R}" y1="${y}" y2="${y}"/><text x="${L - 8}" y="${y + 4}" text-anchor="end">${esc(cfg.fmt(v).replace(/\.0+(?=\D|$)/, ""))}</text>`;
    }
    const span = x1 - x0, ticks = compact ? 3 : 4;
    for (let i = 0; i <= ticks; i++) {
      const ts = x0 + (span * i) / ticks, d = new Date(ts * 1000);
      const label = span > 2 * 86400 ? `${d.getMonth() + 1}/${d.getDate()}` : span < 900 ? `${hhmm(d)}:${String(d.getSeconds()).padStart(2, "0")}` : hhmm(d);
      grid += `<text x="${X(ts)}" y="${H - 6}" text-anchor="${i === 0 ? "start" : i === ticks ? "end" : "middle"}">${label}</text>`;
    }
    let paths = "", defs = "", dots = "";
    const lastOf = series.map((s) => [...s.points].reverse().find((p) => p[1] != null));
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
      if (series.length <= 2) {   // area wash ~10%; with three lines it would only muddy the overlaps
        defs += `<linearGradient id="g${uid}${i}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${colors[i]}" stop-opacity=".2"/><stop offset="1" stop-color="${colors[i]}" stop-opacity=".02"/></linearGradient>`;
        paths += `<path d="${d}L${X(last).toFixed(1)},${Y(0)}L${X(first).toFixed(1)},${Y(0)}Z" fill="url(#g${uid}${i})" stroke="none"/>`;
      }
      paths += `<path d="${d}" fill="none" stroke="${colors[i]}" stroke-width="2" stroke-linejoin="round" stroke-linecap="round"/>`;
      const lp = lastOf[i];
      dots += `<circle r="4.5" fill="${colors[i]}" cx="${X(lp[0]).toFixed(1)}" cy="${Y(lp[1]).toFixed(1)}"/>`;
    });
    box.innerHTML = `<svg viewBox="0 0 ${W} ${H}" width="${W}" height="${H}" role="img" aria-label="${esc(t(cfg.title))}"><defs>${defs}</defs><g class="grid">${grid}</g>${paths}<line class="cross" y1="${TOP}" y2="${H - B}" opacity="0"/><g class="dots">${dots}</g><rect class="hit" x="${L}" y="0" width="${W - L - R}" height="${H}" fill="transparent"/></svg><div class="tip" hidden></div>`;

    const svg = box.querySelector("svg"), tip = box.querySelector(".tip"), cross = box.querySelector(".cross");
    const dotEls = [...box.querySelectorAll(".dots circle")];
    const ref = series.reduce((a, b) => (b.points.length > a.points.length ? b : a), series[0]).points;
    const rest = () => {
      tip.hidden = true; cross.setAttribute("opacity", "0");
      dotEls.forEach((c, i) => { const lp = lastOf[i]; c.setAttribute("cx", X(lp[0]).toFixed(1)); c.setAttribute("cy", Y(lp[1]).toFixed(1)); });
    };
    const show = (e) => {
      const rect = svg.getBoundingClientRect();
      const px = ((e.clientX - rect.left) / rect.width) * W;
      const ts = x0 + ((px - L) / (W - L - R)) * (x1 - x0);
      let best = 0;
      ref.forEach((p, i) => { if (Math.abs(p[0] - ts) < Math.abs(ref[best][0] - ts)) best = i; });
      const at = ref[best][0], cx = X(at);
      cross.setAttribute("x1", cx); cross.setAttribute("x2", cx); cross.setAttribute("opacity", "1");
      const rows = series.map((s, i) => {
        const p = s.points.find((q) => q[0] === at);
        if (p && p[1] != null) { dotEls[i].setAttribute("cx", cx.toFixed(1)); dotEls[i].setAttribute("cy", Y(p[1]).toFixed(1)); }
        const name = series.length > 1 ? `<span>${esc(seriesName(cfg, s, i))}</span>` : "";
        return `<div class="r"><i style="background:${colors[i]}"></i><b>${esc(p && p[1] != null ? cfg.fmt(p[1]) : "–")}</b>${name}</div>`;
      }).join("");
      const dt = new Date(at * 1000);
      tip.innerHTML = `<div class="t">${esc(span > 2 * 86400 ? dt.toLocaleString() : dt.toLocaleTimeString([], { hour12: false }))}</div>${rows}`;
      tip.hidden = false;
      const cxPx = (cx / W) * rect.width, w = tip.offsetWidth;
      tip.style.left = `${Math.max(0, Math.min(rect.width - w, cxPx > rect.width / 2 ? cxPx - w - 14 : cxPx + 14))}px`;
      tip.style.top = "4px";
    };
    svg.addEventListener("pointermove", show);
    svg.addEventListener("pointerdown", show);
    svg.addEventListener("pointerleave", rest);
    svg.addEventListener("pointercancel", rest);
  }

  // Every chart has a table twin: the same numbers, readable without colour or hover.
  function chartTable(cfg, series) {
    const ref = series.reduce((a, b) => (b.points.length > a.points.length ? b : a), series[0]).points.filter((p) => p[1] != null);
    if (!ref.length) return `<div class="empty">${esc(t("no_data"))}</div>`;
    const step = Math.max(1, Math.floor(ref.length / 24));
    const rows = ref.filter((_, i) => (ref.length - 1 - i) % step === 0).reverse();
    const long = ref[ref.length - 1][0] - ref[0][0] > 2 * 86400;
    const head = `<th>${esc(t("time"))}</th>${series.map((s, i) => `<th>${esc(seriesName(cfg, s, i) || t(cfg.title))}</th>`).join("")}`;
    const body = rows.map(([ts]) => {
      const d = new Date(ts * 1000);
      return `<tr><td>${num(esc(long ? `${d.getMonth() + 1}/${d.getDate()} ${hhmm(d)}` : hhmm(d)))}</td>${series.map((s) => { const p = s.points.find((q) => q[0] === ts); return `<td>${num(esc(p && p[1] != null ? cfg.fmt(p[1]) : "–"))}</td>`; }).join("")}</tr>`;
    }).join("");
    return `<div class="chart-table table-wrap"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
  }
  state.charts = [];
  state.tv = {};

  function paintChart(root, i) {
    const c = CHARTS[i], got = state.charts[i];
    const box = root.querySelector(`#plot-${i}`);
    if (!box || !got) return;
    if (state.tv[i]) box.innerHTML = chartTable(c, got);
    else drawChart(box, c, got, i);
    if (c.now) {
      const last = [...got[0].points].reverse().find((p) => p[1] != null);
      const now = root.querySelector(`#now-${i}`);
      if (now) now.innerHTML = last ? num(esc(c.fmt(last[1]))) : "";
    }
  }

  async function buildOverview(root, id, rebuild) {
    if (rebuild) {
      state.charts = [];
      root.querySelector("#body").innerHTML = `<div class="charts">${CHARTS.map((c, i) => {
        const names = c.names ? c.names.map((n) => t(n)) : c.colors.length > 1 ? ["1m", "5m", "15m"] : [];
        const legend = names.length > 1 ? `<div class="legend">${names.map((n, k) => `<span><i style="background:var(${c.colors[k]})"></i>${esc(n)}</span>`).join("")}</div>` : "";
        const tv = !!state.tv[i];
        return `<div class="chart"><header><h3>${esc(t(c.title))}</h3><span class="now" id="now-${i}"></span><button type="button" class="btn small icon ghost view-toggle" data-tv="${i}" aria-pressed="${tv}" title="${esc(t("tbl_view"))}" aria-label="${esc(t("tbl_view"))}">${icon("table")}</button></header>${legend}<div class="plot" id="plot-${i}"><div class="skeleton"></div></div></div>`;
      }).join("")}</div>`;
    }
    await Promise.all(CHARTS.map(async (c, i) => {
      try {
        const { series } = await api("/api/history", withInstance({ metric: c.m, range: state.range }));
        if (id !== state.renderId) return;
        state.charts[i] = series;
        state.hist[c.m] = series;
        paintChart(root, i);
      } catch (e) {
        if (id === state.renderId && !state.charts[i]) root.querySelector(`#plot-${i}`).innerHTML = `<div class="empty">${esc(e.message)}</div>`;
      }
    }));
    if (id === state.renderId) refreshSparks();
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
    $("stats").hidden = v.id !== "overview";
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
    window.scrollTo(0, 0);
    renderView(true);
  }

  // ---------------------------------------------------------------- boot
  $("theme").onclick = () => { state.theme = state.theme === "dark" ? "light" : "dark"; store.set("theme", state.theme); applyLocale(); renderStats(); renderView(true); };
  $("lang").onclick = () => { state.lang = state.lang === "en" ? "fa" : "en"; store.set("lang", state.lang); applyLocale(); renderStats(); renderView(true); };
  $("refresh").onclick = () => tick(true);
  $("logout").onclick = async () => { try { await fetch("/logout", { method: "POST" }); } catch (e) { /* ignore */ } location.replace("/login"); };
  window.addEventListener("hashchange", route);
  document.addEventListener("click", (e) => {
    const go = e.target.closest("[data-go]");
    if (go) { location.hash = go.dataset.go; return; }
    if (e.target.closest("[data-more]")) { moreSheet(); return; }
    const tv = e.target.closest("[data-tv]");
    if (tv) {
      const i = +tv.dataset.tv;
      state.tv[i] = !state.tv[i];
      tv.setAttribute("aria-pressed", String(!!state.tv[i]));
      paintChart($("panel"), i);
    }
  });
  document.addEventListener("keydown", (e) => {
    if ((e.key === "Enter" || e.key === " ") && e.target.matches && e.target.matches('[data-go][role="link"]')) { e.preventDefault(); location.hash = e.target.dataset.go; }
  });
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
/* =====================================================================
   Server Monitor panel - design system
   Dark-first, glass-like layered surfaces, one mint accent.
   Layout: sidebar (>=1100px) -> icon rail (700-1099px) -> bottom tab bar (<700px).
   Chart colours are validated categorical slots (blue, orange, aqua); status colours are
   reserved for state and always come with a shape + label.
   ===================================================================== */
:root {
  --font: "Vazirmatn", ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, Tahoma, "Helvetica Neue", Arial, sans-serif;
  --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;

  --bg: #070b12;
  --glow-a: rgba(46, 230, 166, .09);
  --glow-b: rgba(77, 124, 255, .08);
  --surface: #0e1521;
  --surface-2: #121b2a;
  --surface-3: #18233a;
  --line: rgba(148, 172, 205, .13);
  --line-2: rgba(148, 172, 205, .24);
  --ink: #e9eff8;
  --muted: #8d9db3;
  --faint: #5f6f86;

  --accent: #2ee6a6;
  --accent-2: #17c58c;
  --accent-ink: #03271b;
  --accent-soft: rgba(46, 230, 166, .12);

  /* status: reserved for state, never reused as a series colour */
  --s-good: #22c55e;
  --s-warn: #fab219;
  --s-serious: #ec835a;
  --s-bad: #f0605d;

  /* categorical chart slots, validated for the dark surface */
  --c1: #3987e5;
  --c2: #d95926;
  --c3: #199e70;

  --shadow: 0 1px 0 rgba(255, 255, 255, .035) inset, 0 8px 24px -12px rgba(0, 0, 0, .55);
  --shadow-pop: 0 24px 70px rgba(0, 0, 0, .6);
  --radius: 16px;
  --side-w: 272px;
  --tab-h: 62px;
  color-scheme: dark;
}
:root[data-theme="light"] {
  --bg: #eef2f8;
  --glow-a: rgba(15, 160, 115, .09);
  --glow-b: rgba(60, 110, 230, .08);
  --surface: #ffffff;
  --surface-2: #f5f8fc;
  --surface-3: #e9eff7;
  --line: rgba(20, 45, 80, .10);
  --line-2: rgba(20, 45, 80, .2);
  --ink: #0d1a2b;
  --muted: #54667d;
  --faint: #8494a8;

  --accent: #0b8a62;
  --accent-2: #0a7a57;
  --accent-ink: #ffffff;
  --accent-soft: rgba(11, 138, 98, .10);

  --s-good: #0ca30c;
  --s-warn: #d99200;
  --s-serious: #d9622f;
  --s-bad: #d03b3b;

  --c1: #2a78d6;
  --c2: #e0561f;
  --c3: #14946a;

  --shadow: 0 1px 2px rgba(15, 35, 70, .05), 0 8px 24px -14px rgba(15, 35, 70, .25);
  --shadow-pop: 0 24px 70px rgba(15, 35, 70, .28);
  color-scheme: light;
}

* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
html, body { margin: 0; }
body {
  min-height: 100vh;
  min-height: 100dvh;
  background:
    radial-gradient(900px 480px at 88% -8%, var(--glow-a), transparent 62%),
    radial-gradient(800px 460px at -4% -6%, var(--glow-b), transparent 60%),
    var(--bg);
  background-attachment: fixed;
  color: var(--ink);
  font: 14.5px/1.55 var(--font);
  -webkit-font-smoothing: antialiased;
  -webkit-tap-highlight-color: transparent;
}
button, input, select, textarea { font: inherit; color: inherit; }
svg { display: block; flex: none; }
a { color: inherit; }
.ico { width: 18px; height: 18px; stroke: currentColor; fill: none; stroke-width: 1.9; stroke-linecap: round; stroke-linejoin: round; }
.num { direction: ltr; unicode-bidi: isolate; display: inline-block; }
code { font-family: var(--mono); font-size: 12.5px; direction: ltr; unicode-bidi: isolate; word-break: break-all; }
code.reason { word-break: normal; overflow-wrap: anywhere; line-height: 1.5; }
.muted { color: var(--muted); }
::selection { background: color-mix(in srgb, var(--accent) 35%, transparent); }
* { scrollbar-width: thin; scrollbar-color: var(--line-2) transparent; }

.card { background: var(--surface); border: 1px solid var(--line); border-radius: var(--radius); box-shadow: var(--shadow); }

/* ================================================================== app shell */
.app { display: grid; grid-template-columns: var(--side-w) minmax(0, 1fr); min-height: 100vh; min-height: 100dvh; }

.sidebar {
  position: sticky; top: 0; height: 100vh; height: 100dvh; overflow-y: auto; overflow-x: hidden;
  padding: 22px 14px 18px; display: flex; flex-direction: column; gap: 4px;
  background: linear-gradient(180deg, color-mix(in srgb, var(--surface) 92%, transparent), color-mix(in srgb, var(--bg) 70%, transparent));
  border-inline-end: 1px solid var(--line);
  backdrop-filter: blur(14px);
}
.brand { display: flex; align-items: center; gap: 13px; padding: 0 8px 20px; min-width: 0; }
.logo {
  width: 42px; height: 42px; border-radius: 13px; display: grid; place-items: center; flex: none; color: var(--accent-ink);
  background: linear-gradient(145deg, var(--accent), var(--accent-2)); box-shadow: 0 8px 22px -8px var(--accent), 0 1px 0 rgba(255, 255, 255, .35) inset;
}
.logo .ico { width: 23px; height: 23px; stroke-width: 2.1; }
.brand-text { min-width: 0; }
.brand h1 { margin: 0; font-size: 17px; font-weight: 750; letter-spacing: .01em; line-height: 1.25; }
.brand small { display: block; color: var(--muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.sidebar h2 { margin: 14px 12px 8px; font-size: 11px; letter-spacing: .13em; color: var(--faint); font-weight: 700; text-transform: uppercase; }
.sidebar h2.second { margin-top: 22px; }
.nav { display: grid; gap: 3px; }
.nav a {
  position: relative; display: flex; align-items: center; gap: 12px; min-height: 44px; padding: 0 12px; border-radius: 12px;
  text-decoration: none; color: var(--muted); font-weight: 600; border: 1px solid transparent; cursor: pointer;
  transition: background .15s, color .15s, border-color .15s;
}
.nav a .ico { width: 19px; height: 19px; }
.nav a:hover { color: var(--ink); background: var(--surface-2); }
.nav a.active {
  color: var(--accent); background: var(--accent-soft); border-color: color-mix(in srgb, var(--accent) 28%, transparent);
}
.nav a.active::before {
  content: ""; position: absolute; inset-inline-start: -15px; top: 11px; bottom: 11px; width: 3px; border-radius: 3px; background: var(--accent);
  box-shadow: 0 0 12px var(--accent);
}
.nav a .name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.badge { font-size: 11.5px; font-weight: 700; padding: 1px 8px; border-radius: 999px; background: var(--surface-3); color: var(--muted); line-height: 1.7; }
.nav a.active .badge { background: color-mix(in srgb, var(--accent) 20%, transparent); color: var(--accent); }
.badge.bad { background: color-mix(in srgb, var(--s-bad) 18%, transparent); color: var(--s-bad); }
.side-foot { margin-top: auto; padding: 18px 10px 0; color: var(--faint); font-size: 11.5px; }

.main { min-width: 0; display: flex; flex-direction: column; }
.topbar {
  position: sticky; top: 0; z-index: 30; display: flex; align-items: center; justify-content: space-between; gap: 14px;
  padding: 12px clamp(14px, 3vw, 34px); min-height: 66px;
  background: color-mix(in srgb, var(--bg) 78%, transparent); backdrop-filter: blur(16px) saturate(1.3);
  border-bottom: 1px solid var(--line);
}
.top-left { display: flex; align-items: center; gap: 12px; min-width: 0; }
.top-brand { display: none; }
.top-title { margin: 0; font-size: 17px; font-weight: 750; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.live { display: inline-flex; align-items: center; gap: 9px; color: var(--muted); font-size: 12.5px; padding: 6px 12px; border-radius: 999px; background: var(--surface); border: 1px solid var(--line); min-width: 0; }
.live .pulse { width: 8px; height: 8px; border-radius: 50%; background: var(--s-good); flex: none; position: relative; }
.live .pulse::after { content: ""; position: absolute; inset: -4px; border-radius: 50%; border: 2px solid var(--s-good); opacity: 0; animation: pulse 2.4s ease-out infinite; }
@keyframes pulse { 0% { transform: scale(.5); opacity: .7; } 100% { transform: scale(1.5); opacity: 0; } }
.live span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.actions { display: flex; gap: 8px; align-items: center; flex: none; }

.content { padding: clamp(14px, 2.4vw, 30px) clamp(14px, 3vw, 34px) 60px; width: 100%; max-width: 1560px; margin: 0 auto; display: grid; gap: 18px; align-content: start; min-width: 0; }

/* ================================================================== buttons + forms */
.btn {
  display: inline-flex; align-items: center; justify-content: center; gap: 8px; height: 40px; padding: 0 16px; border-radius: 12px;
  background: var(--surface-2); border: 1px solid var(--line-2); cursor: pointer; font-weight: 650; font-size: 13.5px;
  text-decoration: none; white-space: nowrap; transition: border-color .15s, background .15s, transform .06s, box-shadow .15s;
}
.btn:hover { border-color: color-mix(in srgb, var(--muted) 70%, transparent); background: var(--surface-3); }
.btn:active { transform: translateY(1px) scale(.99); }
.btn.icon { width: 40px; padding: 0; }
.btn.primary {
  background: linear-gradient(145deg, var(--accent), var(--accent-2)); border-color: transparent; color: var(--accent-ink);
  box-shadow: 0 6px 18px -8px var(--accent), 0 1px 0 rgba(255, 255, 255, .3) inset;
}
.btn.primary:hover { filter: brightness(1.07); background: linear-gradient(145deg, var(--accent), var(--accent-2)); }
.btn.danger { color: var(--s-bad); border-color: color-mix(in srgb, var(--s-bad) 42%, transparent); background: transparent; }
.btn.danger:hover { background: color-mix(in srgb, var(--s-bad) 12%, transparent); }
.btn.danger.solid { background: var(--s-bad); border-color: var(--s-bad); color: #fff; }
.btn.danger.solid:hover { filter: brightness(1.08); background: var(--s-bad); }
.btn.ghost { background: transparent; border-color: transparent; }
.btn.ghost:hover { background: var(--surface-2); }
.btn.small { height: 34px; padding: 0 13px; font-size: 12.5px; border-radius: 10px; }
.btn.small.icon { width: 34px; padding: 0; }
.btn:disabled { opacity: .5; cursor: not-allowed; }
.btn:focus-visible, select:focus-visible, input:focus-visible, textarea:focus-visible, .nav a:focus-visible, [data-go]:focus-visible {
  outline: 2px solid var(--accent); outline-offset: 2px;
}
.row-actions { display: flex; gap: 6px; flex-wrap: nowrap; }
.row-actions .btn.small.icon:hover { border-color: var(--accent); color: var(--accent); }
.row-actions .btn.small.icon.danger:hover { border-color: var(--s-bad); color: var(--s-bad); }

select {
  height: 36px; border-radius: 10px; background: var(--surface-2); border: 1px solid var(--line-2); padding: 0 12px; cursor: pointer; font-size: 13px; font-weight: 600;
}
.field { display: grid; gap: 7px; margin-bottom: 16px; }
.field.inline { margin: 0; }
.field label { font-size: 12.5px; color: var(--muted); font-weight: 650; }
.field input, .field select, .field textarea {
  width: 100%; border-radius: 12px; border: 1px solid var(--line-2); background: var(--surface-2); padding: 0 14px; color: var(--ink);
  transition: border-color .15s, box-shadow .15s;
}
.field input, .field select { height: 44px; }
.field textarea { padding: 11px 14px; min-height: 88px; resize: vertical; font-family: var(--mono); font-size: 13px; direction: ltr; text-align: left; }
.field input:focus, .field select:focus, .field textarea:focus { border-color: var(--accent); outline: none; box-shadow: 0 0 0 3px var(--accent-soft); }
.field .hint { color: var(--muted); font-size: 12px; margin: 0; }
.field-row { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
.inline-field { display: inline-flex; align-items: center; gap: 8px; }
.inline-field input {
  width: 96px; height: 36px; border-radius: 10px; border: 1px solid var(--line-2); background: var(--surface-2); padding: 0 10px; direction: ltr;
}
.inline-field input:focus { border-color: var(--accent); outline: none; box-shadow: 0 0 0 3px var(--accent-soft); }
.inline-field small { color: var(--muted); }
.form-error { color: var(--s-bad); font-size: 13px; min-height: 20px; margin-bottom: 8px; }

.switch { position: relative; display: inline-block; width: 44px; height: 26px; flex: none; }
.switch input { position: absolute; opacity: 0; inset: 0; width: 100%; height: 100%; margin: 0; cursor: pointer; z-index: 1; }
.switch span { position: absolute; inset: 0; border-radius: 999px; background: var(--line-2); transition: background .2s; }
.switch span::after { content: ""; position: absolute; top: 3px; inset-inline-start: 3px; width: 20px; height: 20px; border-radius: 50%; background: #fff; box-shadow: 0 1px 3px rgba(0, 0, 0, .35); transition: transform .2s; }
.switch input:checked + span { background: var(--accent-2); }
.switch input:checked + span::after { transform: translateX(18px); }
:root[dir="rtl"] .switch input:checked + span::after { transform: translateX(-18px); }
.switch input:focus-visible + span { outline: 2px solid var(--accent); outline-offset: 2px; }

/* ================================================================== overview: hero, gauges, tiles */
.stats { display: grid; gap: 14px; }
.stats[hidden] { display: none; }

.hero {
  position: relative; overflow: hidden; display: flex; align-items: center; gap: 20px; padding: 22px 26px; flex-wrap: wrap;
  --tone: var(--s-good);
  background: linear-gradient(115deg, color-mix(in srgb, var(--tone) 13%, var(--surface)) 0%, var(--surface) 62%);
  border-color: color-mix(in srgb, var(--tone) 32%, var(--line));
}
.hero.warn { --tone: var(--s-warn); }
.hero.bad { --tone: var(--s-bad); }
.hero::after {
  content: ""; position: absolute; inset-inline-end: -60px; top: -80px; width: 280px; height: 280px; border-radius: 50%;
  background: radial-gradient(circle, color-mix(in srgb, var(--tone) 22%, transparent), transparent 68%); pointer-events: none;
}
.hero-icon {
  width: 58px; height: 58px; border-radius: 18px; display: grid; place-items: center; flex: none; color: var(--tone);
  background: color-mix(in srgb, var(--tone) 16%, transparent); border: 1px solid color-mix(in srgb, var(--tone) 38%, transparent);
}
.hero-icon .ico { width: 28px; height: 28px; stroke-width: 2; }
.hero-text { flex: 1 1 280px; min-width: 0; position: relative; z-index: 1; }
.hero-text h2 { margin: 0; font-size: clamp(19px, 2.6vw, 25px); font-weight: 800; letter-spacing: -.005em; line-height: 1.3; }
.hero-text p { margin: 4px 0 0; color: var(--muted); overflow-wrap: anywhere; }
.hero-meta { display: flex; gap: 10px; flex-wrap: wrap; position: relative; z-index: 1; }
.chip { display: inline-flex; align-items: center; gap: 8px; padding: 7px 13px; border-radius: 12px; background: color-mix(in srgb, var(--surface-2) 80%, transparent); border: 1px solid var(--line); font-size: 12.5px; color: var(--muted); max-width: 100%; }
.chip .ico { width: 15px; height: 15px; color: var(--faint); }
.chip b { color: var(--ink); font-weight: 700; }

.gauges { display: grid; gap: 14px; grid-template-columns: repeat(3, minmax(0, 1fr)); }
.tiles { display: grid; gap: 14px; grid-template-columns: repeat(auto-fill, minmax(196px, 1fr)); }

.stat { position: relative; padding: 16px 18px; min-width: 0; transition: border-color .15s, transform .15s; }
.stat[data-go] { cursor: pointer; }
.stat[data-go]:hover { border-color: var(--line-2); transform: translateY(-1px); }
.stat .label { display: flex; align-items: center; gap: 9px; color: var(--muted); font-size: 13px; font-weight: 600; }
.stat .label .ico { width: 16px; height: 16px; color: var(--faint); }
.stat .value { margin-top: 8px; font-size: 27px; font-weight: 800; letter-spacing: -.015em; line-height: 1.15; }
.stat .value.tight { font-size: 20px; line-height: 31px; white-space: nowrap; }
.stat .value small { font-size: 13px; font-weight: 650; color: var(--muted); letter-spacing: 0; }
.stat .sub { margin-top: 8px; color: var(--muted); font-size: 12px; line-height: 1.55; overflow-wrap: anywhere; }
.stat.alert-on { border-color: color-mix(in srgb, var(--s-bad) 45%, var(--line)); background: linear-gradient(160deg, color-mix(in srgb, var(--s-bad) 10%, var(--surface)), var(--surface)); }
.stat.alert-on .value { color: var(--s-bad); }
.stat .ok-mark { color: var(--s-good); display: inline-flex; }
.stat .ok-mark .ico { width: 30px; height: 30px; stroke-width: 2.3; }
.spark { height: 34px; margin-top: 10px; direction: ltr; }
.spark svg { width: 100%; height: 34px; overflow: visible; }

/* ring gauge */
.stat.gauge { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 4px 18px; align-items: center; padding: 18px 20px; }
.ring { position: relative; width: 104px; height: 104px; --tone: var(--s-good); grid-row: span 3; }
.ring.warn { --tone: var(--s-warn); }
.ring.bad { --tone: var(--s-bad); }
.ring svg { width: 104px; height: 104px; transform: rotate(-90deg); }
.ring .track { stroke: color-mix(in srgb, var(--tone) 17%, transparent); }
.ring .fill { stroke: var(--tone); stroke-linecap: round; transition: stroke-dasharray .6s cubic-bezier(.3, .8, .3, 1); filter: drop-shadow(0 0 6px color-mix(in srgb, var(--tone) 45%, transparent)); }
.ring .center { position: absolute; inset: 0; display: grid; place-items: center; font-size: 24px; font-weight: 800; letter-spacing: -.02em; }
.ring .center small { font-size: 12px; font-weight: 700; color: var(--muted); margin-inline-start: 1px; }
.gauge .g-title { display: flex; align-items: center; gap: 8px; color: var(--muted); font-weight: 650; font-size: 13px; }
.gauge .g-title .ico { width: 16px; height: 16px; color: var(--faint); }
.gauge .g-main { font-size: 13px; color: var(--ink); overflow-wrap: anywhere; font-weight: 600; }
.gauge .sub { margin-top: 0; }
.lvl { display: inline-flex; align-items: center; gap: 6px; font-size: 11.5px; font-weight: 700; color: color-mix(in srgb, var(--tone, var(--s-good)) 60%, var(--ink)); }
.lvl::before { content: ""; width: 8px; height: 8px; background: var(--tone, var(--s-good)); border-radius: 50%; }
.ring.warn ~ .g-lvl .lvl::before, .gauge.warn .lvl::before { clip-path: polygon(50% 0, 100% 100%, 0 100%); border-radius: 0; }
.gauge.bad .lvl::before { clip-path: polygon(50% 0, 100% 50%, 50% 100%, 0 50%); border-radius: 0; }
.gauge { --tone: var(--s-good); }
.gauge.warn { --tone: var(--s-warn); }
.gauge.bad { --tone: var(--s-bad); }

/* linear meters (tables, small spaces): fill carries severity, track is the lighter same ramp */
.bar { height: 6px; border-radius: 6px; background: color-mix(in srgb, var(--s-good) 18%, transparent); margin-top: 10px; overflow: hidden; }
.bar > i { display: block; height: 100%; width: 0; border-radius: 6px; background: var(--s-good); transition: width .5s; }
.bar.warn { background: color-mix(in srgb, var(--s-warn) 20%, transparent); }
.bar.warn > i { background: var(--s-warn); }
.bar.bad { background: color-mix(in srgb, var(--s-bad) 20%, transparent); }
.bar.bad > i { background: var(--s-bad); }
.mini-bar { display: flex; align-items: center; gap: 10px; min-width: 190px; }
.mini-bar .bar { flex: 1; margin: 0; }

/* ================================================================== main panel */
.panel { padding: clamp(16px, 2.2vw, 28px); min-width: 0; }
.panel-head { display: flex; align-items: center; justify-content: space-between; gap: 14px; flex-wrap: wrap; }
.panel-head h2 { margin: 0; display: flex; align-items: center; gap: 12px; font-size: 21px; font-weight: 800; letter-spacing: -.005em; }
.panel-head h2 .ico {
  width: 38px; height: 38px; padding: 9px; border-radius: 12px; color: var(--accent); background: var(--accent-soft);
  border: 1px solid color-mix(in srgb, var(--accent) 25%, transparent);
}
.tools { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.panel .desc { color: var(--muted); margin: 12px 0 20px; max-width: 760px; }
.panel hr { display: none; }

.notice {
  display: flex; align-items: center; gap: 12px; padding: 13px 16px; border-radius: 12px; margin-bottom: 16px;
  background: color-mix(in srgb, var(--c1) 11%, transparent); border: 1px solid color-mix(in srgb, var(--c1) 30%, transparent); border-inline-start: 3px solid var(--c1);
}
.notice .ico { color: var(--c1); }
.notice.bad { background: color-mix(in srgb, var(--s-bad) 10%, transparent); border-color: color-mix(in srgb, var(--s-bad) 35%, transparent); border-inline-start-color: var(--s-bad); }
.notice.bad .ico { color: var(--s-bad); }
.notice.ok { background: color-mix(in srgb, var(--s-good) 10%, transparent); border-color: color-mix(in srgb, var(--s-good) 32%, transparent); border-inline-start-color: var(--s-good); }
.notice.ok .ico { color: var(--s-good); }
.notice.warn { background: color-mix(in srgb, var(--s-warn) 11%, transparent); border-color: color-mix(in srgb, var(--s-warn) 36%, transparent); border-inline-start-color: var(--s-warn); }
.notice.warn .ico { color: var(--s-warn); }

/* ---------- tables */
.table-wrap { overflow-x: auto; border: 1px solid var(--line); border-radius: 14px; background: color-mix(in srgb, var(--surface-2) 40%, transparent); }
table { width: 100%; border-collapse: collapse; min-width: 640px; }
th, td { text-align: start; padding: 14px 16px; white-space: nowrap; }
th { font-size: 12px; letter-spacing: .03em; color: var(--muted); font-weight: 700; background: color-mix(in srgb, var(--surface-2) 80%, transparent); border-bottom: 1px solid var(--line); }
td { border-bottom: 1px solid var(--line); }
tr:last-child td { border-bottom: 0; }
tbody tr { transition: background .12s; }
tbody tr:hover td { background: color-mix(in srgb, var(--surface-3) 55%, transparent); }
td .num, td code { font-variant-numeric: tabular-nums; }
td.strong { font-weight: 700; }
td.wrap-cell { white-space: normal; min-width: 240px; }
td.muted { color: var(--muted); }
.empty { padding: 36px 16px; text-align: center; color: var(--muted); }
.sub-line { color: var(--muted); font-size: 12px; font-weight: 400; margin-top: 2px; white-space: normal; max-width: 460px; }
.tag { display: inline-block; font-size: 11px; font-weight: 700; padding: 1px 8px; border-radius: 7px; background: var(--surface-3); border: 1px solid var(--line); color: var(--muted); margin-inline-start: 8px; vertical-align: middle; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chips code { background: var(--surface-3); border: 1px solid var(--line); border-radius: 7px; padding: 1px 8px; font-size: 12px; }

/* ---------- status pills: colour + shape + label, never colour alone */
.pill {
  --tone: var(--muted);
  display: inline-flex; align-items: center; gap: 7px; padding: 3px 12px; border-radius: 999px; font-size: 12.5px; font-weight: 650;
  background: color-mix(in srgb, var(--tone) 13%, transparent); border: 1px solid color-mix(in srgb, var(--tone) 32%, transparent);
  color: color-mix(in srgb, var(--tone) 55%, var(--ink));
}
.pill.ok { --tone: var(--s-good); }
.pill.info { --tone: var(--c1); }
.pill.warn { --tone: var(--s-warn); }
.pill.bad { --tone: var(--s-bad); }
.pill.dot::before { content: ""; width: 8px; height: 8px; background: var(--tone); border-radius: 50%; flex: none; }
.pill.warn.dot::before { border-radius: 0; clip-path: polygon(50% 0, 100% 100%, 0 100%); width: 9px; height: 9px; }
.pill.bad.dot::before { border-radius: 0; clip-path: polygon(50% 0, 100% 50%, 50% 100%, 0 50%); width: 9px; height: 9px; }

/* ================================================================== charts */
.charts { display: grid; gap: 14px; grid-template-columns: repeat(2, minmax(0, 1fr)); }
.chart { border: 1px solid var(--line); border-radius: 16px; padding: 16px 18px 12px; background: var(--surface-2); position: relative; min-width: 0; }
.chart header { display: flex; align-items: center; justify-content: space-between; gap: 10px; margin-bottom: 4px; }
.chart h3 { margin: 0; font-size: 14px; font-weight: 700; flex: 1; min-width: 0; }
.chart .now { font-size: 22px; font-weight: 800; letter-spacing: -.01em; }
.chart .legend { display: flex; flex-wrap: wrap; gap: 6px 16px; color: var(--muted); font-size: 12px; margin: 2px 0 6px; }
.chart .legend span { display: inline-flex; align-items: center; }
.chart .legend i { display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-inline-end: 7px; }
.chart .view-toggle { color: var(--muted); }
.chart .view-toggle[aria-pressed="true"] { color: var(--accent); background: var(--accent-soft); }
.plot { direction: ltr; position: relative; min-height: 190px; }
.plot svg { width: 100%; height: 190px; overflow: visible; max-width: 100%; touch-action: pan-y; display: block; }
.plot .grid line { stroke: var(--line); stroke-width: 1; }
.plot text { fill: var(--muted); font-size: 11px; font-family: var(--font); }
.plot .cross { stroke: var(--line-2); stroke-width: 1; }
.plot .dots circle { stroke: var(--surface-2); stroke-width: 2; }
.chart-table { max-height: 190px; overflow: auto; border-radius: 10px; border: 1px solid var(--line); }
.chart-table table { min-width: 0; }
.chart-table th, .chart-table td { padding: 7px 12px; font-size: 12.5px; }
.chart-table th { position: sticky; top: 0; }
.tip {
  position: absolute; pointer-events: none; background: color-mix(in srgb, var(--surface) 94%, transparent); border: 1px solid var(--line-2);
  border-radius: 12px; padding: 8px 11px; font-size: 12px; white-space: nowrap; box-shadow: var(--shadow-pop); z-index: 3; backdrop-filter: blur(8px);
}
.tip .t { color: var(--muted); font-size: 11.5px; margin-bottom: 4px; }
.tip .r { display: flex; align-items: center; gap: 8px; line-height: 1.7; }
.tip .r i { width: 10px; height: 3px; border-radius: 2px; flex: none; }
.tip .r b { font-weight: 800; font-size: 13px; }
.tip .r span { color: var(--muted); }

.skeleton { height: 120px; border-radius: 14px; background: linear-gradient(90deg, var(--surface-2), var(--surface-3), var(--surface-2)); background-size: 200% 100%; animation: sk 1.3s infinite; }
@keyframes sk { to { background-position: -200% 0; } }

/* ================================================================== management UI */
.split { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(min(340px, 100%), 1fr)); align-items: start; }
.subcard { border: 1px solid var(--line); border-radius: 16px; background: var(--surface-2); padding: 22px 24px; }
.subcard h3 { margin: 0 0 4px; font-size: 16px; display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
.subcard p { color: var(--muted); margin: 6px 0 14px; }
.subcard .field { margin-bottom: 14px; }
.subcard .actions-row { display: flex; gap: 10px; flex-wrap: wrap; margin-top: 6px; }
.steps { margin: 8px 0 16px; padding-inline-start: 20px; color: var(--muted); }
.steps li { margin: 4px 0; }
.codebox { position: relative; background: var(--bg); border: 1px solid var(--line); border-radius: 12px; padding: 12px 14px; margin: 8px 0 12px; font-family: var(--mono); font-size: 12.5px; direction: ltr; text-align: left; overflow-x: auto; white-space: pre; }

/* ================================================================== dialogs + toasts */
dialog.modal {
  border: 1px solid var(--line-2); border-radius: 20px; background: var(--surface); color: var(--ink); padding: 0;
  width: min(560px, calc(100vw - 24px)); max-height: calc(100dvh - 32px); box-shadow: var(--shadow-pop); animation: pop .18s ease-out;
}
dialog.modal.wide { width: min(920px, calc(100vw - 24px)); }
dialog.modal::backdrop { background: rgba(3, 7, 12, .66); backdrop-filter: blur(4px); }
@keyframes pop { from { transform: translateY(10px) scale(.98); opacity: 0; } }
.modal-form { display: flex; flex-direction: column; max-height: calc(100dvh - 32px); }
.modal-form header { display: flex; align-items: center; justify-content: space-between; gap: 12px; padding: 20px 24px 12px; }
.modal-form header h3 { margin: 0; font-size: 18px; font-weight: 800; }
.modal-body { padding: 4px 24px 8px; overflow-y: auto; overscroll-behavior: contain; }
.modal-body .field { margin-bottom: 14px; }
.modal-form .form-error { padding: 0 24px; min-height: 0; margin: 0; }
.modal-form .form-error:not(:empty) { padding-top: 6px; padding-bottom: 6px; }
.modal-form footer { display: flex; justify-content: flex-end; gap: 10px; padding: 14px 24px 22px; flex-wrap: wrap; }
pre.logs { margin: 0; background: var(--bg); border: 1px solid var(--line); border-radius: 12px; padding: 12px 14px; height: min(60vh, 520px); overflow: auto; font-size: 12px; line-height: 1.5; font-family: var(--mono); direction: ltr; text-align: left; white-space: pre-wrap; word-break: break-all; }

dialog.sheet { border: 0; padding: 0; background: transparent; margin: auto 0 0; max-width: none; width: 100%; max-height: 88dvh; color: var(--ink); }
dialog.sheet::backdrop { background: rgba(3, 7, 12, .6); backdrop-filter: blur(4px); }
.sheet-card {
  background: var(--surface); border: 1px solid var(--line-2); border-bottom: 0; border-radius: 22px 22px 0 0; padding: 10px 16px calc(18px + env(safe-area-inset-bottom, 0px));
  box-shadow: var(--shadow-pop); animation: rise .22s ease-out; max-height: 88dvh; overflow-y: auto;
}
.sheet-card::before { content: ""; display: block; width: 40px; height: 4px; border-radius: 4px; background: var(--line-2); margin: 0 auto 14px; }
.sheet-card h3 { margin: 4px 6px 12px; font-size: 13px; color: var(--faint); letter-spacing: .1em; text-transform: uppercase; }
.sheet-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 10px; }
.sheet-grid button {
  display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px; min-height: 84px; padding: 10px 6px; border-radius: 16px;
  background: var(--surface-2); border: 1px solid var(--line); color: var(--ink); font-weight: 650; font-size: 12.5px; cursor: pointer; text-align: center;
}
.sheet-grid button .ico { width: 22px; height: 22px; color: var(--accent); }
.sheet-grid button.active { border-color: color-mix(in srgb, var(--accent) 45%, transparent); background: var(--accent-soft); }
@keyframes rise { from { transform: translateY(40px); opacity: 0; } }

.toasts { position: fixed; inset-inline-end: 18px; bottom: 18px; display: grid; gap: 8px; z-index: 80; max-width: min(420px, calc(100vw - 32px)); }
.toast {
  display: flex; gap: 10px; align-items: flex-start; padding: 13px 16px; border-radius: 14px; background: var(--surface); border: 1px solid var(--line-2);
  border-inline-start: 3px solid var(--s-good); box-shadow: var(--shadow-pop); animation: toast-in .2s ease-out; overflow-wrap: anywhere;
}
.toast.bad { border-inline-start-color: var(--s-bad); }
.toast.warn { border-inline-start-color: var(--s-warn); }
@keyframes toast-in { from { transform: translateY(8px); opacity: 0; } }

/* ================================================================== bottom tab bar (phones) */
.tabbar { display: none; }

/* ================================================================== login */
.login-page { min-height: 100vh; min-height: 100dvh; display: grid; place-items: center; padding: 24px max(16px, env(safe-area-inset-left, 0px)) 24px max(16px, env(safe-area-inset-right, 0px)); }
.login-card { width: 100%; max-width: 420px; padding: 34px 32px 30px; position: relative; overflow: hidden; border-radius: 24px; }
.login-card::before {
  content: ""; position: absolute; inset-inline: 0; top: 0; height: 3px; background: linear-gradient(90deg, transparent, var(--accent), transparent);
}
.login-card .brand { flex-direction: column; text-align: center; padding: 0 0 26px; gap: 14px; }
.login-card .logo { width: 62px; height: 62px; border-radius: 20px; }
.login-card .logo .ico { width: 32px; height: 32px; }
.login-card .brand h1 { font-size: 22px; }
.login-card .brand small { font-size: 13.5px; white-space: normal; }
.login-card .btn.primary { width: 100%; height: 48px; font-size: 15px; }
.login-card .field input { height: 48px; }

/* ================================================================== responsive */
@media (max-width: 1280px) {
  .gauges { grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); }
}

/* icon rail */
@media (max-width: 1099px) {
  :root { --side-w: 82px; }
  .sidebar { padding: 18px 12px; align-items: stretch; }
  .brand { padding: 0 0 18px; justify-content: center; }
  .brand-text, .sidebar h2, .side-foot { display: none; }
  .nav a { justify-content: center; padding: 0; min-height: 48px; }
  .nav a .name { display: none; }
  .nav a .badge { position: absolute; top: 3px; inset-inline-end: 2px; min-width: 18px; padding: 0 5px; text-align: center; font-size: 10.5px; line-height: 17px; }
  .nav a.active::before { inset-inline-start: -13px; }
  .nav + .nav { margin-top: 14px; padding-top: 14px; border-top: 1px solid var(--line); }
  .charts { grid-template-columns: minmax(0, 1fr); }
}

/* phones */
@media (max-width: 699px) {
  :root { --side-w: 0px; }
  .app { display: block; }
  .sidebar { display: none; }
  .topbar { min-height: 58px; padding-block: 8px; padding-inline: max(14px, env(safe-area-inset-left, 0px)) max(14px, env(safe-area-inset-right, 0px)); top: 0; padding-top: calc(8px + env(safe-area-inset-top, 0px)); }
  .top-brand { display: grid; width: 36px; height: 36px; border-radius: 11px; }
  .top-brand .ico { width: 20px; height: 20px; }
  .live { display: none; }
  .actions { gap: 6px; }
  .actions .btn { width: 42px; height: 42px; padding: 0; }
  .btn .txt { display: none; }
  .content { padding-inline: max(14px, env(safe-area-inset-left, 0px)) max(14px, env(safe-area-inset-right, 0px)); padding-bottom: calc(var(--tab-h) + 34px + env(safe-area-inset-bottom, 0px)); gap: 14px; }
  .panel { padding: 16px 14px; }
  .panel-head h2 { font-size: 18px; }
  .hero { padding: 18px 16px; gap: 14px; }
  .hero-icon { width: 50px; height: 50px; border-radius: 16px; }
  .gauges { grid-template-columns: minmax(0, 1fr); }
  .stat.gauge { padding: 14px 16px; }
  .ring, .ring svg { width: 92px; height: 92px; }
  .ring .center { font-size: 21px; }
  .tiles { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px; }
  .stat { padding: 14px; }
  .stat .value { font-size: 23px; }
  .stat .value.tight { font-size: 17px; }
  .field-row { grid-template-columns: minmax(0, 1fr); }
  .subcard { padding: 16px; }
  .plot svg, .plot { min-height: 170px; }
  .plot svg { height: 170px; }
  .chart { padding: 14px 12px 10px; }

  .tabbar {
    position: fixed; z-index: 40; inset-inline: 0; bottom: 0; display: grid; grid-template-columns: repeat(5, minmax(0, 1fr));
    padding: 6px max(8px, env(safe-area-inset-left, 0px)) calc(6px + env(safe-area-inset-bottom, 0px)) max(8px, env(safe-area-inset-right, 0px));
    background: color-mix(in srgb, var(--surface) 90%, transparent); backdrop-filter: blur(18px) saturate(1.4);
    border-top: 1px solid var(--line-2); box-shadow: 0 -10px 30px -18px rgba(0, 0, 0, .6);
  }
  .tabbar button {
    position: relative; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 3px; min-height: 50px;
    background: none; border: 0; border-radius: 14px; color: var(--muted); font-size: 11px; font-weight: 650; cursor: pointer; padding: 4px 2px;
  }
  .tabbar button .ico { width: 22px; height: 22px; }
  .tabbar button .lbl { max-width: 100%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .tabbar button.active { color: var(--accent); }
  .tabbar button.active::before { content: ""; position: absolute; top: -7px; width: 28px; height: 3px; border-radius: 0 0 4px 4px; background: var(--accent); box-shadow: 0 0 10px var(--accent); }
  .tabbar .dot { position: absolute; top: 5px; inset-inline-start: calc(50% + 6px); min-width: 16px; height: 16px; padding: 0 4px; border-radius: 999px; background: var(--s-bad); color: #fff; font-size: 10px; line-height: 16px; text-align: center; font-weight: 800; }

  /* tables become card lists */
  .table-wrap { border: 0; background: none; overflow: visible; }
  table, thead, tbody, tr, td { display: block; }
  table { min-width: 0; }
  thead { display: none; }
  tbody tr { border: 1px solid var(--line); border-radius: 16px; background: var(--surface-2); padding: 12px 14px; margin-bottom: 10px; }
  tbody tr:hover td { background: none; }
  td { display: flex; align-items: center; justify-content: space-between; gap: 14px; padding: 7px 0; border: 0; white-space: normal; text-align: end; min-width: 0; }
  td::before { content: attr(data-label); color: var(--muted); font-size: 12px; font-weight: 600; text-align: start; flex: none; }
  td:first-child { display: block; text-align: start; padding-top: 0; padding-bottom: 8px; margin-bottom: 4px; border-bottom: 1px solid var(--line); font-size: 15px; }
  td:first-child::before { display: none; }
  td.wrap-cell { min-width: 0; }
  td .sub-line { max-width: none; }
  td .chips { justify-content: flex-end; }
  td .mini-bar { min-width: 0; width: 100%; max-width: 190px; }
  td[data-label=""]::before, td:not([data-label])::before { display: none; }
  td:last-child:not(:first-child) { justify-content: flex-end; padding-top: 10px; margin-top: 4px; border-top: 1px solid var(--line); }
  td:last-child:not(:first-child)::before { display: none; }
  .row-actions { gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
  .row-actions .btn.small.icon { width: 42px; height: 42px; }
  .btn.small { height: 40px; }
  .tools .btn.small { height: 40px; }
  .chart-table { max-height: 170px; }
  .chart-table td, .chart-table th { display: table-cell; }
  .chart-table table { display: table; }
  .chart-table thead { display: table-header-group; }
  .chart-table tbody { display: table-row-group; }
  .chart-table tr { display: table-row; padding: 0; border: 0; margin: 0; background: none; border-radius: 0; }
  .chart-table td::before { display: none; }
  .chart-table td { text-align: start; padding: 7px 12px; border-bottom: 1px solid var(--line); }
  .chart-table td:first-child { display: table-cell; font-size: 12.5px; margin: 0; }

  /* dialogs become bottom sheets */
  dialog.modal, dialog.modal.wide { width: 100%; max-width: none; margin: auto 0 0; border-radius: 22px 22px 0 0; border-bottom: 0; max-height: 92dvh; animation: rise .22s ease-out; }
  .modal-form { max-height: 92dvh; }
  .modal-form header, .modal-body, .modal-form footer, .modal-form .form-error { padding-inline: 16px; }
  .modal-form footer { padding-bottom: calc(18px + env(safe-area-inset-bottom, 0px)); }
  .modal-form footer .btn { flex: 1; height: 46px; }
  .field input, .field select { height: 48px; font-size: 16px; }   /* 16px stops iOS zooming into inputs */
  .field textarea { font-size: 16px; }
  .toasts { inset-inline: 12px; bottom: calc(var(--tab-h) + 16px + env(safe-area-inset-bottom, 0px)); max-width: none; }
  .login-card { padding: 28px 22px 24px; }
}

@media (max-width: 380px) {
  .tiles { grid-template-columns: minmax(0, 1fr); }
  .top-title { font-size: 15px; }
}
@media (prefers-reduced-motion: reduce) { * { animation: none !important; transition: none !important; } }

/* sparklines inside tiles and gauges */
.spark { position: relative; }
.spark .sd { position: absolute; inset-inline-end: 0; width: 8px; height: 8px; margin-top: -4px; border-radius: 50%; transform: translateX(50%); box-shadow: 0 0 0 2px var(--surface); }
.spark:empty { display: none; }
.gauge .spark { grid-column: 1 / -1; }
#banner:empty { display: none; }
.gauge { align-content: center; }
__MONITORING_EOF__
  write_file panel/static/fonts.css 644 <<'__MONITORING_EOF__'
/* Vazirmatn (SIL Open Font License 1.1) - Latin + Persian/Arabic subset, embedded so the panel needs no external font host. */
@font-face {
  font-family: "Vazirmatn";
  font-style: normal;
  font-weight: 100 900;
  font-display: swap;
  src: url(data:font/woff2;base64,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) format("woff2");
}
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
