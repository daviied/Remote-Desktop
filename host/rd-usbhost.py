#!/usr/bin/env python3
"""
rd-usbhost: attaches USB devices shared by RD clients (USB/IP) on the Windows host.
Needs usbip-win2 (usbip.exe). Listens on the private network address only (+ firewall rule).
Defense in depth: before it attaches a device, it reads the device's USB classes from the client
and refuses HID (keyboards / mice), network adapters, hubs, audio, video, Bluetooth (BadUSB guard),
even if the client asks for them.

  POST /attach {"busid": "1-2", "port": 3240}   attach a device from the calling client
  GET  /status                                   busids attached from the calling client
Header X-RD-Token must match %ProgramData%\\RD\\usb-token.txt.
The calling client's private-network IP is taken from the connection, never from the request.
"""
import hmac
import ipaddress
import json
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 47900
TS = os.environ.get("RD_TAILSCALE", r"C:\Program Files\Tailscale\tailscale.exe")
DATA = os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"), "RD")
USBIP = os.environ.get("RD_USBIP", r"C:\Program Files\USBip\usbip.exe")
BUSID_RE = re.compile(r"^[0-9]+-[0-9.]+$")
lock = threading.Lock()


def network():
    """network.json from install-host.ps1: {"mode": "wireguard"|"tailscale", "subnets": [...]}"""
    try:
        with open(os.path.join(DATA, "network.json"), encoding="utf-8-sig") as f:
            n = json.load(f)
    except (OSError, ValueError):
        n = {}
    subnets = n.get("subnets") or ["100.64.0.0/10"]
    if isinstance(subnets, str):
        subnets = [subnets]
    return n.get("mode", "tailscale"), [ipaddress.ip_network(s.strip(), strict=False) for s in subnets]


MODE, NETS = network()


def allowed_ip(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(a in n for n in NETS)

# Same rules as client rd-usb.py: (class, subclass, protocol); None = any
BLOCK_INTERFACES = [
    (0x03, None, None), (0x01, None, None), (0x0E, None, None), (0x09, None, None),
    (0xE0, 0x01, 0x01), (0xE0, 0x01, 0x03), (0xEF, 0x04, 0x01),
    (0x02, 0x06, None), (0x02, 0x0D, None), (0x02, 0x0A, None), (0x02, 0x0E, None),
    (0xFF, 0x5D, None), (0xFF, 0x47, None), (0x58, 0x42, None),
]
CLASS_RE = re.compile(r"\(([0-9a-fA-F]{2})/([0-9a-fA-F]{2})/([0-9a-fA-F]{2})\)\s*$")


def device_allowed(ip, busid):
    """Read the device's classes from the client's USB/IP export list. Unknown = refused."""
    try:
        out = subprocess.run([USBIP, "list", "-r", ip], capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return False, "cannot list client devices"
    return check_classes(out, busid)


def check_classes(out, busid):
    classes, inside = [], False
    for line in out.splitlines():
        s = line.strip()
        if re.match(r"^" + re.escape(busid) + r":", s):
            inside = True
            continue
        if inside:
            if not s.startswith(":"):
                break
            m = CLASS_RE.search(s)
            if m:
                classes.append(tuple(int(x, 16) for x in m.groups()))
    if len(classes) < 2:   # device line + at least one interface
        return False, "device classes unknown"
    for c, sc, p in classes:
        for bc, bs, bp in BLOCK_INTERFACES:
            if c == bc and (bs is None or sc == bs) and (bp is None or p == bp):
                return False, "blocked device class %02x/%02x/%02x" % (c, sc, p)
    return True, ""


def token():
    with open(os.path.join(DATA, "usb-token.txt")) as f:
        return f.read().strip()


def attached_from(ip):
    # usbip-win2 "usbip port" lists imported devices with their remote host and busid,
    # e.g. "-> usbip://100.64.0.3:3240/1-2"
    out = subprocess.run([USBIP, "port"], capture_output=True, text=True).stdout
    return sorted(set(m.group(1) for m in re.finditer(r"usbip://" + re.escape(ip) + r":\d+/(\S+)", out)))


class Handler(BaseHTTPRequestHandler):
    def _auth(self):
        if not allowed_ip(self.client_address[0]):   # second check after the firewall
            self._send(403, {"error": "address not allowed"})
            return False
        sent = self.headers.get("X-RD-Token", "")
        if not hmac.compare_digest(sent.encode(), token().encode()):
            self._send(403, {"error": "bad token"})
            return False
        return True

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self._auth():
            return
        if self.path == "/status":
            self._send(200, {"busids": attached_from(self.client_address[0])})
        else:
            self._send(404, {})

    def do_POST(self):
        if not self._auth():
            return
        try:
            n = min(int(self.headers.get("Content-Length", 0) or 0), 4096)
            body = json.loads(self.rfile.read(n) or b"{}") if n else {}
            if not isinstance(body, dict):
                raise ValueError
        except ValueError:
            return self._send(400, {"error": "bad json"})
        if self.path != "/attach":
            return self._send(404, {})
        busid = str(body.get("busid", ""))
        try:
            port = int(body.get("port", 3240))
        except (TypeError, ValueError):
            port = 0
        if not BUSID_RE.match(busid) or not (1 <= port <= 65535):
            return self._send(400, {"error": "bad busid/port"})
        ip = self.client_address[0]
        with lock:
            if busid in attached_from(ip):
                return self._send(200, {"result": "already attached"})
            ok, why = device_allowed(ip, busid)
            if not ok:
                self.log_message("refused %s: %s", busid, why)
                return self._send(403, {"result": "refused: " + why})
            r = subprocess.run([USBIP, "attach", "-r", ip, "-b", busid],
                               capture_output=True, text=True, timeout=30)
        self._send(200 if r.returncode == 0 else 500,
                   {"result": "attached" if r.returncode == 0 else (r.stderr or r.stdout).strip()})

    def log_message(self, fmt, *args):
        with open(os.path.join(DATA, "rd-usbhost.log"), "a") as f:
            f.write("%s %s\n" % (self.client_address[0], fmt % args))


def private_ip():
    """Wait for the WireGuard (Tailscale) address; listen only there."""
    while True:
        try:
            ip = subprocess.run([TS, "ip", "-4"], capture_output=True, text=True, timeout=10).stdout.split()[0]
            if ip.startswith("100."):
                return ip
        except Exception:
            pass
        time.sleep(10)


if __name__ == "__main__":
    os.makedirs(DATA, exist_ok=True)
    # tailscale: listen on the tailnet address only. wireguard: host is on the LAN; firewall + allowed_ip()
    listen = private_ip() if MODE == "tailscale" else "0.0.0.0"
    ThreadingHTTPServer((listen, PORT), Handler).serve_forever()
