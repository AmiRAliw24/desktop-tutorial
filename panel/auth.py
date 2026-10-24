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
