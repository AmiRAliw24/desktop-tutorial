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

## راه‌اندازی

```bash
cp .env.example .env        # رمز Grafana و توکن/چت‌آیدی تلگرام را بنویسید
./scripts/render-config.sh  # ساخت alertmanager/alertmanager.yml از روی .env
docker compose up -d
```

- Grafana: http://localhost:3000
- Prometheus: http://localhost:9090
- Alertmanager: http://localhost:9093

پورت‌ها فقط روی `127.0.0.1` باز می‌شوند. برای دسترسی از بیرون از reverse proxy (مثلاً Nginx/Caddy با HTTPS و احراز هویت) استفاده کنید، نه باز کردن مستقیم پورت.

## تنظیمات

- **سایت‌ها و پورت‌ها:** در `prometheus/prometheus.yml` بخش `blackbox-http` و `blackbox-tcp` آدرس‌ها را عوض کنید (فعلاً `https://example.com` است)، سپس `docker compose restart prometheus`.
- **سرور اضافه:** `node_exporter` را روی سرور دیگر نصب کنید و `IP:9100` را به job به نام `node` اضافه کنید.
- **هشدارها:** `prometheus/rules/alerts.yml` شامل ۱۲ قانون است: خاموشی هدف، CPU/رم/دیسک بالا، پر شدن دیسک تا ۲۴ ساعت آینده، load، ری‌استارت سرور، مصرف کانتینر، قطعی سایت، کندی پاسخ و انقضای SSL (کمتر از ۱۴ روز).
- **ایمیل یا Slack:** در `alertmanager/alertmanager.yml.tmpl` یک receiver جدید اضافه کنید.

## تست هشدار

```bash
curl -XPOST http://localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","severity":"warning"},"annotations":{"summary":"تست هشدار"}}]'
```
