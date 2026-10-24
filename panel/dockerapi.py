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
