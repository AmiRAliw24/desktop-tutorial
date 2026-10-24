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
      usage: "Usage", used_total: "Used / Total", iface: "Interface", speed: "Link speed", rate_in: "In", rate_out: "Out", total_in: "Total in", total_out: "Total out",
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
      usage: "مصرف", used_total: "مصرف / کل", iface: "کارت شبکه", speed: "سرعت لینک", rate_in: "دریافت", rate_out: "ارسال", total_in: "کل دریافت", total_out: "کل ارسال",
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
    grafanaPort: 3001,
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
    $("grafana").href = `${location.protocol}//${location.hostname}:${state.grafanaPort}/d/server-overview`;
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
        { h: "speed", cell: (r) => num(r.speed ? `${nf((r.speed * 8) / 1e6, 0)} Mbit/s` : "–") },
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
  api("/api/config").then((c) => { state.grafanaPort = c.grafana_port; applyLocale(); }).catch(() => { /* keep default */ });
  state.view = VIEWS.some((v) => v.id === location.hash.slice(1)) ? location.hash.slice(1) : "overview";
  renderNav();
  tick(true);
  setInterval(() => { if (!document.hidden) tick(false); }, 10000);
})();
