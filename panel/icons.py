"""Renders the panel icon (shield with a pulse line) as PNG / ICO using only the standard library.

Browsers differ in which icon format they pick up (SVG, /favicon.ico, PNG, Apple touch icon), so the
panel serves all of them, generated here once and cached.
"""
import math
import struct
import zlib

BG = (14, 21, 32)      # card colour
FG = (46, 230, 166)    # accent colour

# Shapes in unit coordinates (0..1).
SHIELD = [(0.5, 0.15), (0.80, 0.27), (0.80, 0.52), (0.5, 0.85), (0.20, 0.52), (0.20, 0.27), (0.5, 0.15)]
PULSE = [(0.29, 0.50), (0.42, 0.50), (0.50, 0.34), (0.58, 0.64), (0.66, 0.50), (0.71, 0.50)]
_cache = {}


def _dist_to_segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    length2 = dx * dx + dy * dy
    t = 0.0 if length2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length2))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(px - cx, py - cy)


def _in_rounded_square(x, y, size, radius):
    half = size / 2
    qx, qy = abs(x - half) - (half - radius), abs(y - half) - (half - radius)
    return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) <= radius


def _png(size, rows):
    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + bytes(row) for row in rows)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def png(size):
    """RGBA PNG of the icon at size x size pixels."""
    if size in _cache:
        return _cache[size]
    ss = 4 if size <= 64 else 2                      # supersampling factor for smooth edges
    stroke = max(1.2, size * 0.075)
    pulse_stroke = max(1.0, size * 0.06)
    shield = [(x * size, y * size) for x, y in SHIELD]
    pulse = [(x * size, y * size) for x, y in PULSE]
    radius = size * 0.22
    rows = []
    for py in range(size):
        row = bytearray()
        for px in range(size):
            r = g = b = a = 0
            for sy in range(ss):
                for sx in range(ss):
                    x, y = px + (sx + 0.5) / ss, py + (sy + 0.5) / ss
                    if not _in_rounded_square(x, y, size, radius):
                        continue
                    on_shield = any(_dist_to_segment(x, y, *shield[i], *shield[i + 1]) <= stroke / 2 for i in range(len(shield) - 1))
                    on_pulse = any(_dist_to_segment(x, y, *pulse[i], *pulse[i + 1]) <= pulse_stroke / 2 for i in range(len(pulse) - 1))
                    colour = FG if (on_shield or on_pulse) else BG
                    r, g, b, a = r + colour[0], g + colour[1], b + colour[2], a + 1
            total = ss * ss
            if a:
                row += bytes((r // a, g // a, b // a, round(255 * a / total)))
            else:
                row += b"\x00\x00\x00\x00"
        rows.append(row)
    _cache[size] = _png(size, rows)
    return _cache[size]


def ico():
    """A .ico wrapping a 32x32 PNG (supported by every current browser)."""
    data = png(32)
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack("<BBBBHHII", 32, 32, 0, 0, 1, 32, len(data), 22)
    return header + entry + data
