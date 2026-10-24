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
