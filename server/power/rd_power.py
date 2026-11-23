#!/usr/bin/env python3
"""
rd-power: turns the host PC's smart outlet on when a client wants to connect, and off
after the host shuts down. Outlet control: Home Assistant, Tuya local (LAN) or Tuya cloud.

The PC BIOS must be set to "Restore on AC power loss: Power On", so outlet on = PC boots.

Endpoints (behind nginx at /power/):
  GET  /power/            small web page (log in with the token)
  GET  /power/status      {"outlet": true/false/null, "hostOnline": bool, "pending": "..."}
  POST /power/wake        outlet on (if the host is offline)
  POST /power/shutdown    {"type": "poweroff"} from the host; outlet off once it is offline
Auth: header "Authorization: Bearer <RD_POWER_TOKEN>".
"""
import hmac
import json
import os
import socket
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ENV = os.environ.get
TOKEN = ENV("RD_POWER_TOKEN", "")
BACKEND = ENV("POWER_BACKEND", "homeassistant")   # homeassistant | tuya-local | tuya-cloud
HOST_NODE = ENV("HOST_NODE", "rd-host")             # headscale node name of the host
HEADSCALE_URL = ENV("HEADSCALE_URL", "http://rd-coordinator:8080")
HEADSCALE_API_KEY = ENV("HEADSCALE_API_KEY", "")
# WireGuard mode: host LAN address; online = Sunshine port answers (Sunshine runs as a service at boot)
HOST_ADDR = ENV("HOST_ADDR", "")
OFF_GRACE = int(ENV("OFF_GRACE_SECONDS", "60"))      # wait after host goes offline
OFF_TIMEOUT = int(ENV("OFF_TIMEOUT_SECONDS", "900"))  # give up if host never goes offline
WAKE_COOLDOWN = 20

state = {"pending": "", "last_wake": 0.0, "shutdown_id": 0}
lock = threading.Lock()


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)

# ---------------------------------------------------------------- outlet backends


def http_json(url, method="GET", body=None, headers=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}


class HomeAssistant:
    def __init__(self):
        self.url = ENV("HA_URL", "").rstrip("/")
        self.token = ENV("HA_TOKEN", "")
        self.entity = ENV("HA_ENTITY", "")  # e.g. switch.pc_outlet

    def _h(self):
        return {"Authorization": f"Bearer {self.token}"}

    def set(self, on):
        domain = self.entity.split(".")[0]
        http_json(f"{self.url}/api/services/{domain}/turn_{'on' if on else 'off'}", "POST",
                  {"entity_id": self.entity}, self._h())

    def get(self):
        return http_json(f"{self.url}/api/states/{self.entity}", headers=self._h()).get("state") == "on"


class TuyaLocal:
    def __init__(self):
        import tinytuya
        self.dev = tinytuya.OutletDevice(ENV("TUYA_DEVICE_ID"), ENV("TUYA_IP", "Auto"), ENV("TUYA_LOCAL_KEY"))
        self.dev.set_version(float(ENV("TUYA_VERSION", "3.3")))
        self.dps = int(ENV("TUYA_SWITCH_DPS", "1"))

    def set(self, on):
        (self.dev.turn_on if on else self.dev.turn_off)(switch=self.dps)

    def get(self):
        return bool(self.dev.status().get("dps", {}).get(str(self.dps)))


class TuyaCloud:
    def __init__(self):
        import tinytuya
        self.cloud = tinytuya.Cloud(apiRegion=ENV("TUYA_REGION", "us"), apiKey=ENV("TUYA_API_KEY"),
                                    apiSecret=ENV("TUYA_API_SECRET"))
        self.id = ENV("TUYA_DEVICE_ID")
        self.code = ENV("TUYA_SWITCH_CODE", "switch_1")

    def set(self, on):
        self.cloud.sendcommand(self.id, {"commands": [{"code": self.code, "value": on}]})

    def get(self):
        for s in self.cloud.getstatus(self.id).get("result", []):
            if s.get("code") == self.code:
                return bool(s.get("value"))
        return None


outlet = {"homeassistant": HomeAssistant, "tuya-local": TuyaLocal, "tuya-cloud": TuyaCloud}[BACKEND]()


def outlet_get():
    try:
        return outlet.get()
    except Exception as e:
        log(f"outlet status failed: {e}")
        return None


def outlet_set(on):
    try:
        outlet.set(on)
        log(f"outlet {'ON' if on else 'OFF'}")
        return True
    except Exception as e:
        log(f"outlet set failed: {e}")
        return False

# ---------------------------------------------------------------- host state (headscale)


def host_online():
    if HOST_ADDR:
        h, _, p = HOST_ADDR.rpartition(":") if HOST_ADDR.count(":") == 1 else (HOST_ADDR, "", "")
        try:
            socket.create_connection((h, int(p or 47989)), timeout=3).close()
            return True
        except OSError:
            # retry once: never report "offline" on a single lost packet
            try:
                socket.create_connection((h, int(p or 47989)), timeout=5).close()
                return True
            except OSError:
                return False
    try:
        nodes = http_json(f"{HEADSCALE_URL}/api/v1/node", headers={"Authorization": f"Bearer {HEADSCALE_API_KEY}"}).get("nodes", [])
    except Exception as e:
        log(f"headscale query failed: {e}")
        return True  # unknown: never cut power on uncertainty
    for n in nodes:
        if HOST_NODE in (n.get("name"), n.get("givenName")):
            return bool(n.get("online"))
    return False


def shutdown_worker(my_id):
    """Wait for the host to go offline, wait the grace period, re-check, then cut power."""
    start = time.time()
    while time.time() - start < OFF_TIMEOUT:
        if state["shutdown_id"] != my_id:
            return  # cancelled by a wake
        if not host_online():
            time.sleep(OFF_GRACE)
            if state["shutdown_id"] == my_id and not host_online():
                outlet_set(False)
            break
        time.sleep(5)
    with lock:
        if state["shutdown_id"] == my_id:
            state["pending"] = ""

# ---------------------------------------------------------------- HTTP

PAGE = """<!doctype html><html><head><meta name=viewport content="width=device-width,initial-scale=1">
<title>RD Power</title><style>body{font-family:system-ui;max-width:420px;margin:40px auto;padding:0 16px}
button{font-size:1.1em;padding:10px 18px;margin:6px 6px 0 0}#s{margin:16px 0;font-size:1.1em}</style></head><body>
<h2>RD host power</h2><div id=login><input id=t type=password placeholder="Token" size=30>
<button onclick="localStorage.rdt=t.value;go()">Log in</button></div>
<div id=main hidden><div id=s>...</div><button onclick="call('wake')">Power on host</button>
<button onclick="refresh()">Refresh</button></div><script>
async function call(p,m){const r=await fetch('/power/'+p,{method:m||'POST',headers:{Authorization:'Bearer '+localStorage.rdt}});
if(r.status==401){login.hidden=false;main.hidden=true;throw 0}return r.json()}
async function refresh(){const j=await call('status','GET');s.textContent='Host: '+(j.hostOnline?'online':'offline')+
' | Outlet: '+(j.outlet===null?'unknown':j.outlet?'on':'off')+(j.pending?' | '+j.pending:'')}
function go(){login.hidden=true;main.hidden=false;refresh();setInterval(refresh,5000)}if(localStorage.rdt)go()
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj, ctype="application/json"):
        body = obj.encode() if isinstance(obj, str) else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'")
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        sent = self.headers.get("Authorization", "")[len("Bearer "):]
        if TOKEN and hmac.compare_digest(sent.encode(), TOKEN.encode()):
            return True
        time.sleep(1)  # slow down guessing
        self._send(401, {"error": "unauthorized"})
        return False

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/")
        if path in ("/power", ""):
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if path == "/power/status":
            if self._auth():
                self._send(200, {"outlet": outlet_get(), "hostOnline": host_online(), "pending": state["pending"]})
            return
        self._send(404, {})

    def do_POST(self):
        path = self.path.split("?")[0].rstrip("/")
        if not self._auth():
            return
        try:
            length = min(int(self.headers.get("Content-Length", 0) or 0), 4096)
        except ValueError:
            length = 0
        try:
            body = json.loads(self.rfile.read(length) or b"{}") if length else {}
        except ValueError:
            body = {}

        if path == "/power/wake":
            with lock:
                state["shutdown_id"] += 1  # cancel any pending power-off
                state["pending"] = ""
                if time.time() - state["last_wake"] < WAKE_COOLDOWN:
                    return self._send(200, {"result": "wake already requested"})
                state["last_wake"] = time.time()
            if host_online():
                return self._send(200, {"result": "host already online"})
            if outlet_get():
                # Outlet already on but PC is off: cycle power so the BIOS sees AC return and boots.
                outlet_set(False)
                time.sleep(5)
            ok = outlet_set(True)
            return self._send(200 if ok else 502, {"result": "outlet on" if ok else "outlet error"})

        if path == "/power/shutdown":
            if str(body.get("type", "poweroff")).lower() != "poweroff":
                return self._send(200, {"result": "ignored (restart)"})
            with lock:
                state["shutdown_id"] += 1
                my_id = state["shutdown_id"]
                state["pending"] = "power off after host shuts down"
            threading.Thread(target=shutdown_worker, args=(my_id,), daemon=True).start()
            return self._send(200, {"result": "scheduled"})

        self._send(404, {})

    def log_message(self, fmt, *args):
        log("%s %s" % (self.headers.get("X-Real-IP", self.client_address[0]), fmt % args))


if __name__ == "__main__":
    if len(TOKEN) < 16:
        raise SystemExit("Set RD_POWER_TOKEN (16+ characters).")
    log(f"rd-power: backend={BACKEND} host={HOST_ADDR or HOST_NODE} check={'tcp' if HOST_ADDR else 'headscale'}")
    ThreadingHTTPServer(("0.0.0.0", int(ENV("PORT", "8090"))), Handler).serve_forever()
