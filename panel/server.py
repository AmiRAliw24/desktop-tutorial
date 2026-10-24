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
    "/api/checks/add": post_checks_add, "/api/checks/remove": post_checks_remove, "/api/checks/probe": post_checks_probe,
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
