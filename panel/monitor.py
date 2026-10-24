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
