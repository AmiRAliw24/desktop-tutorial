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
                         "locked": kind == "nodes" and t == LOCAL_NODE})
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


def probe_debug(kind, target):
    """Run one check right now through the blackbox exporter and return why it passed or failed."""
    if kind not in ("http", "tcp"):
        raise ConfigError("unknown kind")
    target = str(target or "").strip()
    if not any(r["target"] == target for r in list_targets(kind)):
        raise ConfigError("Only monitored addresses can be tested")
    query = urlencode({"module": "http_2xx" if kind == "http" else "tcp_connect", "target": target, "debug": "true"})
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


def classify_failure(reason, http_status):
    """Map a blackbox error to a short code the UI turns into a plain-language explanation."""
    r = reason.lower()
    if "connection reset" in r or "unexpected eof" in r or "eof" in r.split(":")[-1]:
        return "reset"
    if "connection refused" in r:
        return "refused"
    if "no such host" in r or "server misbehaving" in r or "lookup" in r:
        return "dns"
    if "timeout" in r or "deadline exceeded" in r:
        return "timeout"
    if "x509" in r or "certificate" in r or "tls:" in r:
        return "tls"
    if "network is unreachable" in r or "no route" in r:
        return "unreachable"
    if http_status and not reason:
        return "status"
    return "status" if http_status else "other"


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
