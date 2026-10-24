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
