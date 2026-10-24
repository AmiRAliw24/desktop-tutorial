# مانیتورینگ کامل سرور

استک آماده‌ی مانیتورینگ با Docker Compose:

| سرویس | کار |
|---|---|
| **Prometheus** | جمع‌آوری و ذخیره متریک‌ها (۳۰ روز) |
| **پنل وب** | داشبورد اصلی و سبک با ظاهر اختصاصی (پورت 3000) |
| **Grafana** | نمودارهای پیشرفته (Server Overview به‌صورت خودکار نصب می‌شود) |
| **Alertmanager** | ارسال هشدار به تلگرام |
| **node_exporter** | متریک‌های سیستم: CPU، رم، دیسک، شبکه، load |
| **cAdvisor** | متریک کانتینرهای Docker |
| **Blackbox exporter** | چک آپتایم سایت‌ها، پورت‌ها و انقضای SSL |

## پنل وب (داشبورد اصلی)

علاوه بر Grafana، یک پنل وب اختصاصی نصب می‌شود (پوشه `panel/`): تم تیره/روشن، فارسی و انگلیسی (با راست‌به‌چپ)، کارت‌های آماری زنده، و بخش‌های نمای کلی، کانتینرها، سایت‌ها، دیسک‌ها، شبکه، تارگت‌ها و هشدارها.

- آدرس: `http://IP-SERVER:3000` (پورت با `PANEL_PORT` و پورت Grafana با `GRAFANA_PORT` در `.env` عوض می‌شود؛ اگر پورتی اشغال باشد، نصب‌کننده خودش پورت آزاد بعدی را انتخاب می‌کند)
- ورود: همان نام کاربری و رمز Grafana (`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`)
- داده‌ها را فقط‌خواندنی از Prometheus می‌گیرد؛ کوئیری دلخواه از بیرون پذیرفته نمی‌شود.
- ورود اشتباه با تأخیر یک‌ثانیه‌ای رد می‌شود، کوکی نشست `HttpOnly` است و با عوض شدن رمز همه‌ی نشست‌ها باطل می‌شوند.
- پورت پنل (3000) و Grafana (3001) باید در فایروال سرور و پنل هاستینگ باز باشند.
- برای HTTPS یک reverse proxy (مثلاً Caddy) جلوی پورت 3000 بگذارید.

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

اگر Grafana را روی `127.0.0.1` بگذارید، از کامپیوتر خودتان با `ssh -L 3000:127.0.0.1:3000 -L 3001:127.0.0.1:3001 root@SERVER` وصل شوید. با `0.0.0.0` (پیش‌فرض) پورت‌های 3000 و 3001 باید در فایروال سرور و پنل هاستینگ باز باشد، و برای محیط واقعی حتماً HTTPS جلویش بگذارید.

> `install.sh` از روی فایل‌های همین ریپو ساخته می‌شود. بعد از تغییر هر فایل، `./scripts/build-installer.sh` را اجرا کنید.

## راه‌اندازی دستی (بدون نصب‌کننده)

```bash
cp .env.example .env        # رمز Grafana و توکن/چت‌آیدی تلگرام را بنویسید
./scripts/render-config.sh  # ساخت alertmanager/alertmanager.yml از روی .env
docker compose up -d
```

- پنل وب: http://localhost:3000
- Grafana: http://localhost:3001
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
