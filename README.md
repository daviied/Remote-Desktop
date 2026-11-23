# RD — Private low-latency remote desktop

Laptop / desktop / Android tablet → Windows host (NVIDIA). Native apps, no browser.

Two network modes:
- **WireGuard (default)** — your own WireGuard tunnel to home. Host stays on the LAN. No coordinator needed.
- **Tailscale** — self-hosted headscale coordinator + relay. Host and clients need no port forwarding.

## Architecture

```
 Clients: RD Moonlight (Win/mac/Linux), RD Moonlight Android          rd-usb ──USB/IP──┐
    │  WireGuard mode: your tunnel → home router/server → LAN                           │
    │  Tailscale mode: WireGuard P2P (hole punched; HTTPS relay fallback)               ▼
 Windows host: RD Sunshine x3 (NVENC) ── rd-hostd (virtual displays, battery tray), rd-usbhost
    ▲
 Server (Docker, behind nginx): rd-power (smart outlet via Home Assistant / Tuya)
                                rd-coordinator (Tailscale mode only: auth, discovery, STUN, relay)
```

| Feature | How |
|---|---|
| Encryption | WireGuard + Sunshine AES-GCM forced on |
| Low latency | NVENC P1, no 2-pass/AQ, HAGS, direct UDP, hardware decode |
| Client-drawn cursor | Host sends cursor shapes, not pixels; client OS draws it at local refresh. Hidden host cursor (games) → relative mouse |
| Looks local | Each connection sets its host virtual display to the client's resolution + refresh |
| Virtual monitors | Virtual Display Driver (3 monitors), switched on/off per connection |
| Profiles | Per device: monitors (1–3), resolution, FPS, bitrate, codec, HDR, window mode. Default per device + toolbar chooser |
| Network rules | Ethernet / Wi-Fi SSIDs / tethered / cellular → switch profile or cap bitrate, FPS, height |
| Tablet 2nd/3rd monitor | Android client streams host display 2 or 3 |
| Client battery on host | Client sends battery level; host taskbar shows one icon per client |
| USB passthrough | Drives, serial / microcontroller boards, printers → host. Keyboards, mice, controllers, network adapters, webcams, audio, Bluetooth stay local |
| Smart outlet | Wake PC → outlet on (PC boots). Windows power-off → outlet off after PC is offline |
| Cross-platform | Windows, macOS, Linux, Android (USB passthrough: Windows/Linux clients only) |

Repo layout: [server/](server/) power + coordinator, [host/](host/) host setup + helpers, [client/](client/) client setup + USB agent, [patches/](patches/) changes to Sunshine / Moonlight, [forks/](forks/) script that builds them on GitHub.

## 0. Build the RD apps (once)

Needs `git` + GitHub CLI (`gh auth login`).
```powershell
.\forks\setup-forks.ps1
```
This forks Sunshine, moonlight-qt, moonlight-common-c, moonlight-android to `daviied`, applies [patches/](patches/), and starts CI. Download from each fork's **Actions** tab (latest run on branch `rd`):
- Sunshine → Windows installer (host)
- moonlight-qt → Windows installer, macOS .dmg, Linux AppImage
- moonlight-android → APK

### Installers (easiest)

After the fork CI runs succeed, tag this repo (`git tag v1.0.0 && git push --tags`) or run **Actions → Installers** by hand. The release gets:

| File | Where | What it does |
|---|---|---|
| `RD-Host-Setup-<v>.exe` | Windows host | Wizard: network mode, allowed subnets, smart-outlet URL/token. Installs RD Sunshine, rd-hostd, firewall, USB agent. Opens a summary with the **host address** and **USB token** |
| `RD-Client-Setup-<v>.exe` | Windows laptop / desktop | Wizard: network mode, host IP, USB token. Installs RD Moonlight + USB agent |
| `RD-Client-<v>.pkg` | Mac | Installs RD Moonlight in Applications |
| `rd-hostd.exe` | — | For `install-host.ps1` without the setup.exe |

Run the host installer first. The scripts in sections 3–4 do the same work by hand.

Unsigned builds: Windows SmartScreen → *More info* → *Run anyway*. macOS → right-click the .pkg → *Open*. Code signing needs paid certificates (Windows code-signing cert; Apple Developer ID, then set `PKG_SIGN_IDENTITY`).
Setup logs: `%TEMP%\rd-host-setup.log`, `%TEMP%\rd-client-setup.log`.

## 1. Network

### WireGuard mode (your tunnel)
Requirements:
- The tunnel ends on your router or a home server, and **routes** (no NAT / masquerade) into the LAN. The host must see each client's tunnel IP (e.g. `10.8.0.5`); USB passthrough connects back to it.
- The host's gateway must route the tunnel subnet back to the WireGuard server (automatic if WireGuard runs on the router; else add a static route on the router).
- Client tunnel config: `AllowedIPs` must include the home LAN (e.g. `192.168.1.0/24`).
- Give the host a **fixed LAN IP** (DHCP reservation).

### Tailscale mode
1. `docker compose --profile tailscale up -d` (or [casaos-compose-tailscale.yml](casaos-compose-tailscale.yml)). Router: forward **UDP 3478**.
2. Users, keys, API key:
   ```
   docker exec rd-coordinator headscale users create rd
   docker exec rd-coordinator headscale users list                       # note ID
   docker exec rd-coordinator headscale preauthkeys create --user <ID> --expiration 1h   # one per client device
   docker exec rd-coordinator headscale preauthkeys create --user <ID> --expiration 1h --tags tag:host   # the host only
   docker exec rd-coordinator headscale apikeys create --expiration 3650d               # -> HEADSCALE_API_KEY
   ```
Access policy ([server/policy.hujson](server/policy.hujson)): clients reach only the host stream ports and USB agent; the host reaches only clients' USB/IP port; clients cannot reach each other. Only a `--tags tag:host` key makes a host.

## 2. Server (smart outlet, optional)

1. Push this repo to GitHub. Actions build `ghcr.io/daviied/rd-power` (and `rd-coordinator`). Make the packages public (or `docker login ghcr.io`).
2. `cp .env.example .env` and edit, then `docker compose up -d`. Or paste [casaos-compose.yml](casaos-compose.yml) into CasaOS.
3. nginx: [server/nginx.conf.example](server/nginx.conf.example) (TLS required). WireGuard mode: use only the `/power/` block.
4. Host online check: WireGuard mode `HOST_ADDR=<host LAN IP>` (server must reach TCP 47989 on it). Tailscale mode `HEADSCALE_API_KEY`.
5. Outlet backend:
   - Home Assistant: `POWER_BACKEND=homeassistant`, `HA_URL`, `HA_TOKEN` (long-lived token), `HA_ENTITY` (e.g. `switch.pc_outlet`). Works with Tuya outlets added to HA.
   - Tuya direct, LAN: `POWER_BACKEND=tuya-local`, `TUYA_DEVICE_ID`, `TUYA_LOCAL_KEY` (`python -m tinytuya wizard`), `TUYA_IP` (fixed IP).
   - Tuya cloud: `POWER_BACKEND=tuya-cloud`, `TUYA_API_KEY`, `TUYA_API_SECRET`, `TUYA_REGION`.
- PC BIOS: **Restore on AC power loss = Power On**.
- Web page with a power button: `https://rd.example.com/power/` (log in with `RD_POWER_TOKEN`).
- Check `/power/status` shows `hostOnline: true` while the PC is on. If not, the wake button could power-cycle a running PC: fix `HOST_ADDR` first.
- Safety: power is cut only after a Windows **power-off** (restarts are ignored), once the host is offline for `OFF_GRACE_SECONDS`. A wake request cancels a pending power-off.

## 3. Windows host

1. Install [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver). Set **3 monitors**. Add every resolution + refresh rate your clients use.
2. Optional USB passthrough: install [usbip-win2](https://github.com/vadimgrn/usbip-win2/releases).
3. Admin PowerShell. WireGuard mode (`-AllowedSubnets` = your tunnel subnet + home LAN):
   ```powershell
   .\host\install-host.ps1 -AllowedSubnets 10.8.0.0/24,192.168.1.0/24 -SunshineInstaller <RD Sunshine installer> -PowerUrl https://rd.example.com -PowerToken <RD_POWER_TOKEN>
   ```
   Tailscale mode: add `-Network tailscale -LoginServer https://rd.example.com -AuthKey <tag:host key>` instead of `-AllowedSubnets`.
   Note the **USB token** and **host address** it prints.
4. **Host final steps**
   - `C:\ProgramData\RD\rd-hostd.exe display attach-all`
   - `https://localhost:47990`, `:48090`, `:48190` → create login → Audio/Video → Display = virtual display 1, 2, 3.
   - `C:\ProgramData\RD\rd-hostd.exe display init` (only display 1 stays on).
   - Disable the physical monitor if any (headless). NVIDIA Control Panel: Low Latency Mode = On. Windows: Hardware-accelerated GPU scheduling = On.
   - Virtual displays not found? `rd-hostd display list`; set env `RD_VDD_MATCH` to part of the VDD monitor name.

## 4. Clients

Windows (admin). WireGuard mode (`-HostName` = host LAN IP):
```powershell
.\client\install-client.ps1 -HostName 192.168.1.20 -MoonlightInstaller <RD Moonlight installer> -UsbToken <USB token>
```
Tailscale mode: `-Network tailscale -LoginServer https://rd.example.com -AuthKey <key>` instead of `-HostName`.

macOS / Linux: install the RD Moonlight build, then
- `./client/install-client.sh wireguard <host LAN IP> [usb-token]`
- `./client/install-client.sh tailscale https://rd.example.com <key> [usb-token]`

Connect the tunnel (WireGuard mode) before you start Moonlight. In Moonlight: **Add PC** `<host>` (display 1). For multi-monitor profiles also add `<host>:48089` and `<host>:48189`; pair each (PIN in host web UI 47990 / 48090 / 48190). `<host>` = host LAN IP (WireGuard) or `rd-host` (Tailscale).

**Profiles & network rules:** Settings → toolbar button *Profiles & network rules*.
- Profile: monitors (1–3) with resolution, FPS, host port, client screen; bitrate, codec, HDR, window mode, client-drawn cursor.
- *Make default on this device*: e.g. MacBook = 1 monitor 3024x1964@120; Desktop = 2 monitors 2560x1440@144 + 1920x1080@60.
- Toolbar chooser on the PC list: use another profile for the next connection only.
- Rules (first match wins): connection type `ethernet` / `wifi` / `tethered` / `cellular` / `any`, optional SSID list (`iPhone*`), then switch profile and/or cap bitrate, FPS, height, codec.
- SSID detection: Windows 11 24H2+ and macOS 14+ need Location permission on; otherwise Wi-Fi rules match by type only.
- *Host power*: server URL + `RD_POWER_TOKEN`. Then **Wake PC** on an offline host switches its outlet on.

**Battery / latency settings:** codec AV1 if the laptop decodes it, else HEVC; decoder = hardware; FPS = panel (60 on battery via a network/profile rule); fullscreen; bitrate 20–40 Mbps.

**USB passthrough:** `python %ProgramData%\RD\rd-usb.py list` (admin) shows SHARE / local per device. Override in `usb.json`: `"allow": ["303a:1001"]`, `"deny": ["0781:*"]`. A shared device is unavailable on the client while the host uses it.

## 5. Android tablet (extra monitor)

1. Network: WireGuard app with your tunnel (WireGuard mode), or Tailscale app → *Change server* → `https://rd.example.com` → pre-auth key.
2. Install the RD Moonlight APK. Add PC `<host>:48189` (display 3) or `<host>:48089`.
3. Settings → *Remote desktop mouse mode* on = client-drawn cursor with a mouse. Battery shows on the host taskbar.
4. Power on the host from a browser: `https://rd.example.com/power/`.

## Security

**Encryption over the internet: yes, two layers.**
1. WireGuard (Curve25519 + ChaCha20-Poly1305). WireGuard mode: client ↔ your home WireGuard server. Tailscale mode: client ↔ host, direct or through the relay (the relay only sees encrypted packets).
2. Sunshine stream encryption forced on (`lan/wan_encryption_mode = 2`): video, audio, input, control use AES-128-GCM with keys from the paired-certificate (TLS) handshake. A client must be paired with a PIN. This also covers the home-LAN hop in WireGuard mode.

WireGuard mode note: between your WireGuard server and the host, USB/IP data and the USB agent token cross your home LAN without WireGuard. The stream stays encrypted (layer 2). Use Tailscale mode if you do not trust devices on your LAN.

| Part | Protection |
|---|---|
| Power page | Token (16+ chars, constant-time compare, 1 s delay on failure), nginx rate limit 10/min, 4 KB body cap, CSP / no-frame / no-referrer headers |
| Host firewall | Every RD rule allows only the allowed subnets (WireGuard mode) or the Tailscale adapter **and** 100.64.0.0/10 (Tailscale mode). Nothing open to the internet |
| Sunshine | Web UI: private ranges only, login required. Streams: paired clients only |
| Host files | `C:\ProgramData\RD` writable by SYSTEM / Admins only (tasks run as SYSTEM). Tokens: Admins only. Python in Program Files, run with `-I` |
| USB | Token auth; caller IP must be in the allowed subnets (checked by firewall and agent). Host re-checks device classes and refuses HID / network / hub / audio / video / Bluetooth, even if a client asks (BadUSB guard). Client: only the host IP may reach USB/IP port 3240; agent sends its token only to the host address |
| Coordinator (Tailscale mode) | HTTPS only; device join needs a one-time pre-auth key (1 h); admin API `/api/` blocked at nginx; no public DERP servers; deny-by-default ACL; host tag only from a tagged key |
| Secrets | Only in `.env` / env vars / ProgramData, never in git |

**Do:**
- Use long random tokens: `openssl rand -hex 32`.
- Keep port 8090 (and 8080) off the router. Forward only nginx 443 (+ your WireGuard port; + UDP 3478 in Tailscale mode).
- Strong Sunshine web UI passwords. Keep Windows, NVIDIA driver, Sunshine, WireGuard / Tailscale up to date.
- Lost device: remove its WireGuard peer (or `headscale nodes delete -i <id>`), and unpair it in the Sunshine web UI.
- Tailscale mode: back up `/DATA/AppData/rd-coordinator` (coordinator private keys); keep it private.

## Status

- Not tested end to end: no build or run of the patched Sunshine / Moonlight apps yet (CI builds them). Patches apply cleanly to the pinned upstream commits.
- Tested here: `rd-hostd` compiles, lists displays and runs the tray; USB policy decisions and subnet checks; `rd-power` wake / shutdown logic and TCP host check.
- Display on/off (`rd-hostd attach/detach`) is untested on a real VDD setup.
- macOS client: no USB passthrough.
