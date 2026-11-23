#!/usr/bin/env python3
"""
rd-usb: share selected USB devices from this client to the RD host (USB/IP).

Passed through by default: USB drives, serial / microcontroller boards (CDC-ACM, FTDI,
CH340, CP210x, ESP32, RP2040, Arduino...), printers, scanners, smart-card readers,
DFU / vendor-specific tools.
Kept local by default: keyboards, mice and other HID, game controllers, network
adapters (Ethernet / Wi-Fi / RNDIS / CDC-ECM/NCM), Bluetooth, audio, webcams, hubs.

Usage:
  rd-usb.py list                 show devices and the decision for each
  rd-usb.py run                  agent: keep allowed devices attached to the host
Config (JSON): Windows %ProgramData%\\RD\\usb.json (admins only), Linux ~/.config/rd/usb.json
  { "host": "rd-host", "port": 47900, "token": "<from host>",
    "allow": ["303a:1001"], "deny": ["0781:*"] }
"allow"/"deny" take "vid:pid" (hex, * wildcard) and override the class rules.
Server side: Windows needs usbipd-win; Linux needs usbip tools (usbip-host module).
macOS has no USB/IP server, so it is not supported.
"""
import fnmatch
import ipaddress
import json
import os
import platform
import re
import socket
import subprocess
import sys
import time
import urllib.request

USBIP_PORT = 3240
POLL_SECONDS = 5

# ---------------------------------------------------------------- policy

# (class, subclass, protocol) patterns; None = any
BLOCK_INTERFACES = [
    (0x03, None, None, "HID (keyboard / mouse / gamepad)"),
    (0x01, None, None, "audio"),
    (0x0E, None, None, "video / webcam"),
    (0x09, None, None, "hub"),
    (0xE0, 0x01, 0x01, "Bluetooth"),
    (0xE0, 0x01, 0x03, "RNDIS network"),
    (0xEF, 0x04, 0x01, "RNDIS network"),
    (0x02, 0x06, None, "CDC-ECM network"),
    (0x02, 0x0D, None, "CDC-NCM network"),
    (0x02, 0x0A, None, "CDC-EEM network"),
    (0x02, 0x0E, None, "CDC-MBIM modem"),
    (0xFF, 0x5D, None, "Xbox controller"),
    (0xFF, 0x47, None, "Xbox controller"),
    (0x58, 0x42, None, "Xbox controller"),
]

# vid -> pid glob list ("*" = whole vendor)
BLOCK_IDS = {
    "054c": ["*"],                  # Sony (DualShock / DualSense)
    "057e": ["*"],                  # Nintendo controllers
    "28de": ["*"],                  # Valve / Steam controller
    "045e": ["02*", "0b1*", "0b2*"],  # Microsoft Xbox controllers / adapters
    "0b95": ["*"],                  # ASIX USB Ethernet
    "0bda": ["81*", "88*", "b8*", "c8*", "f1*", "a8*"],  # Realtek USB Ethernet / Wi-Fi
    "148f": ["*"],                  # Ralink / MediaTek Wi-Fi
    "0e8d": ["79*", "76*"],         # MediaTek Wi-Fi
    "2357": ["01*", "0106", "010c"],  # TP-Link Wi-Fi
    "0cf3": ["*"],                  # Qualcomm Atheros Wi-Fi / BT
    "8087": ["*"],                  # Intel Bluetooth
}


def id_matches(vid, pid, patterns):
    key = f"{vid}:{pid}"
    return any(fnmatch.fnmatch(key, p.lower()) for p in patterns)


def decide(dev, cfg):
    """Return (allowed, reason)."""
    vid, pid = dev["vid"], dev["pid"]
    if id_matches(vid, pid, cfg.get("deny", [])):
        return False, "deny list"
    if id_matches(vid, pid, cfg.get("allow", [])):
        return True, "allow list"
    for pat in BLOCK_IDS.get(vid, []):
        if fnmatch.fnmatch(pid, pat):
            return False, "known controller / network adapter"
    for (c, s, p) in dev["ifaces"]:
        for (bc, bs, bp, why) in BLOCK_INTERFACES:
            if c == bc and (bs is None or s == bs) and (bp is None or p == bp):
                return False, why
    if not dev["ifaces"]:
        return False, "unknown interfaces"
    return True, "storage / serial / other"

# ---------------------------------------------------------------- enumeration


def run(cmd, check=False):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}: {r.stderr.strip()}")
    return r.stdout


def list_linux():
    base = "/sys/bus/usb/devices"
    devs = []
    for name in os.listdir(base):
        if ":" in name or name.startswith("usb"):
            continue
        d = os.path.join(base, name)
        try:
            vid = open(os.path.join(d, "idVendor")).read().strip().lower()
            pid = open(os.path.join(d, "idProduct")).read().strip().lower()
        except OSError:
            continue
        product = ""
        try:
            product = open(os.path.join(d, "product")).read().strip()
        except OSError:
            pass
        ifaces = []
        for sub in os.listdir(d):
            if sub.startswith(name + ":"):
                try:
                    rd = lambda f: int(open(os.path.join(d, sub, f)).read().strip(), 16)
                    ifaces.append((rd("bInterfaceClass"), rd("bInterfaceSubClass"), rd("bInterfaceProtocol")))
                except OSError:
                    pass
        devs.append({"busid": name, "vid": vid, "pid": pid, "name": product, "ifaces": ifaces})
    return devs


_win_iface_cache = {}


def win_ifaces(instance_id):
    if instance_id in _win_iface_cache:
        return _win_iface_cache[instance_id]
    m = re.match(r"USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})", instance_id, re.I)
    if not m:
        return []
    prefix = f"USB\\VID_{m.group(1)}&PID_{m.group(2)}"
    ps = ("Get-PnpDevice | Where-Object { $_.InstanceId -like '" + prefix + "*' } | ForEach-Object { "
          "(Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_CompatibleIds -ErrorAction SilentlyContinue).Data }")
    out = run(["powershell", "-NoProfile", "-Command", ps])
    ifaces = set()
    for cls, sub, prot in re.findall(r"USB\\Class_([0-9A-F]{2})&SubClass_([0-9A-F]{2})&Prot_([0-9A-F]{2})", out, re.I):
        ifaces.add((int(cls, 16), int(sub, 16), int(prot, 16)))
    _win_iface_cache[instance_id] = sorted(ifaces)
    return _win_iface_cache[instance_id]


def list_windows():
    state = json.loads(run(["usbipd", "state"], check=True) or "{}")
    devs = []
    for d in state.get("Devices", []):
        busid = d.get("BusId")
        inst = d.get("InstanceId", "")
        m = re.match(r"USB\\VID_([0-9A-F]{4})&PID_([0-9A-F]{4})", inst, re.I)
        if not busid or not m:
            continue  # not connected
        devs.append({"busid": busid, "vid": m.group(1).lower(), "pid": m.group(2).lower(),
                     "name": d.get("Description", ""), "ifaces": win_ifaces(inst),
                     "bound": d.get("PersistedGuid") is not None})
    return devs


def list_devices():
    system = platform.system()
    if system == "Linux":
        return list_linux()
    if system == "Windows":
        return list_windows()
    raise SystemExit("USB passthrough needs a USB/IP server: supported on Windows (usbipd-win) and Linux only.")


def bind(dev):
    if platform.system() == "Windows":
        if not dev.get("bound"):
            run(["usbipd", "bind", "--busid", dev["busid"]], check=True)
    else:
        run(["usbip", "bind", "-b", dev["busid"]])  # error if already bound is fine

# ---------------------------------------------------------------- host API


def config_path():
    if platform.system() == "Windows":
        return os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"), "RD", "usb.json")
    return os.path.expanduser("~/.config/rd/usb.json")


def load_config():
    try:
        with open(config_path()) as f:
            return json.load(f)
    except OSError:
        return {}


def host_ip(name):
    """The host must be on the private network (WireGuard). Never send the token anywhere else."""
    nets = [ipaddress.ip_network(s, strict=False) for s in CFG_SUBNETS or ["100.64.0.0/10"]]
    for info in socket.getaddrinfo(name, None, socket.AF_INET, socket.SOCK_STREAM):
        ip = info[4][0]
        if any(ipaddress.ip_address(ip) in n for n in nets):
            return ip
    raise RuntimeError(f"{name} is not in the allowed host range {CFG_SUBNETS}; refusing")


CFG_SUBNETS = []


def host_call(cfg, method, path, body=None):
    global CFG_SUBNETS
    CFG_SUBNETS = cfg.get("subnets") or ["100.64.0.0/10"]
    url = f"http://{host_ip(cfg['host'])}:{int(cfg.get('port', 47900))}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"X-RD-Token": cfg.get("token", ""), "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read() or b"{}")

# ---------------------------------------------------------------- commands


def cmd_list(cfg):
    for d in sorted(list_devices(), key=lambda x: x["busid"]):
        ok, why = decide(d, cfg)
        print(f"{'SHARE' if ok else 'local':5}  {d['busid']:8} {d['vid']}:{d['pid']}  {d['name'][:40]:40}  ({why})")


def cmd_run(cfg):
    if not cfg.get("host"):
        raise SystemExit(f"Set 'host' and 'token' in {config_path()}")
    if platform.system() == "Linux":
        run(["modprobe", "usbip-host"])
        if "usbipd" not in run(["ps", "-e"]):
            subprocess.Popen(["usbipd", "-D"])
    print(f"rd-usb: sharing allowed devices with {cfg['host']}")
    while True:
        try:
            devs = [d for d in list_devices() if decide(d, cfg)[0]]
            attached = set(host_call(cfg, "GET", "/status").get("busids", []))
            for d in devs:
                if d["busid"] not in attached:
                    bind(d)
                    res = host_call(cfg, "POST", "/attach", {"busid": d["busid"], "port": USBIP_PORT})
                    print(f"attach {d['busid']} {d['name']}: {res.get('result')}")
        except Exception as e:  # host offline, not streaming, etc.
            print(f"rd-usb: {e}")
            time.sleep(POLL_SECONDS * 3)
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    {"list": cmd_list, "run": cmd_run}.get(cmd, lambda c: print(__doc__))(load_config())
