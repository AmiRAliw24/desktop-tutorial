"""Finds this server's public IPv4 / IPv6 address for the dashboard.

Runs in its own container with host networking, so the lookups leave through the server's real
interfaces (a bridged container usually has no IPv6 route). The result is written to a small JSON
file that the panel reads. Set PUBLIC_IP_LOOKUP=0 in .env to switch the lookups off.
"""
import ipaddress
import json
import os
import time
import urllib.request

OUT = os.environ.get("OUT", "/data/public-ip.json")
SOURCES = {
    4: ["https://api4.ipify.org", "https://ipv4.icanhazip.com", "https://v4.ident.me"],
    6: ["https://api6.ipify.org", "https://ipv6.icanhazip.com", "https://v6.ident.me"],
}


def lookup(version):
    for url in SOURCES[version]:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "server-monitor"})
            with urllib.request.urlopen(req, timeout=6) as resp:
                ip = ipaddress.ip_address(resp.read(100).decode().strip())
            if ip.version == version and ip.is_global:
                return str(ip)
        except Exception:
            continue
    return None


def write(data):
    tmp = OUT + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, OUT)


def main():
    if os.environ.get("PUBLIC_IP_LOOKUP", "1") == "0":
        write({"disabled": True})
        while True:
            time.sleep(86400)
    while True:
        v4, v6 = lookup(4), lookup(6)
        write({"v4": v4, "v6": v6, "checked": int(time.time())})
        time.sleep(600 if (v4 or v6) else 60)


if __name__ == "__main__":
    main()
