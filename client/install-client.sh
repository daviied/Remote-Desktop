#!/usr/bin/env sh
# macOS / Linux client setup.
# Usage:
#   WireGuard (your own tunnel):  ./install-client.sh wireguard <host-LAN-IP> [usb-token]
#   Tailscale / headscale:        ./install-client.sh tailscale https://rd.example.com <preauth-key> [usb-token]
# Install the RD Moonlight build (your moonlight-qt fork's Actions: .dmg / AppImage) yourself;
# this script installs stock Moonlight only if no moonlight is found.
set -eu
MODE="${1:-}"
case "$MODE" in
  wireguard) HOST="${2:?host LAN IP}"; USB_TOKEN="${3:-}"; SUBNET="$HOST/32" ;;
  tailscale) LOGIN_SERVER="${2:?login server}"; AUTH_KEY="${3:?pre-auth key}"; USB_TOKEN="${4:-}"
             HOST="rd-host"; SUBNET="100.64.0.0/10" ;;
  *) echo "Usage: $0 wireguard <host-LAN-IP> [usb-token] | tailscale <url> <key> [usb-token]"; exit 1 ;;
esac
HERE="$(cd "$(dirname "$0")" && pwd)"

case "$(uname -s)" in
  Darwin)
    [ -d /Applications/Moonlight.app ] || brew install --cask moonlight
    if [ "$MODE" = tailscale ]; then
      brew install --cask tailscale
      open -a Tailscale; sleep 5
      /Applications/Tailscale.app/Contents/MacOS/Tailscale up --login-server "$LOGIN_SERVER" --authkey "$AUTH_KEY" --reset
    fi
    if [ -n "$USB_TOKEN" ]; then echo "Note: USB passthrough is not available on macOS (no USB/IP server)."; fi
    ;;
  Linux)
    command -v moonlight >/dev/null 2>&1 || flatpak install -y flathub com.moonlight_stream.Moonlight
    if [ "$MODE" = tailscale ]; then
      curl -fsSL https://tailscale.com/install.sh | sh
      sudo tailscale up --login-server "$LOGIN_SERVER" --authkey "$AUTH_KEY" --reset
    fi
    if [ -n "$USB_TOKEN" ]; then
      # usbip tools: Debian/Ubuntu "usbip" or "linux-tools-generic", Fedora "usbip"
      (sudo apt-get install -y usbip || sudo apt-get install -y linux-tools-generic || sudo dnf install -y usbip) || true
      sudo install -D -m 755 "$HERE/rd-usb.py" /opt/rd/rd-usb.py
      sudo install -d -m 700 /root/.config/rd
      printf '{"host":"%s","port":47900,"token":"%s","subnets":["%s"],"allow":[],"deny":[]}\n' "$HOST" "$USB_TOKEN" "$SUBNET" \
        | sudo tee /root/.config/rd/usb.json >/dev/null
      sudo chmod 600 /root/.config/rd/usb.json
      sudo tee /etc/systemd/system/rd-usb.service >/dev/null <<'EOF'
[Unit]
Description=RD USB share
After=network-online.target

[Service]
ExecStart=/usr/bin/python3 -I /opt/rd/rd-usb.py run
Restart=always
RestartSec=10
Nice=10

[Install]
WantedBy=multi-user.target
EOF
      sudo systemctl daemon-reload
      sudo systemctl enable --now rd-usb
      # usbipd listens on 3240: only the host may connect
      if command -v ufw >/dev/null 2>&1; then
        if [ "$MODE" = tailscale ]; then
          sudo ufw allow in on tailscale0 from "$SUBNET" to any port 3240 proto tcp
        else
          sudo ufw allow from "$HOST" to any port 3240 proto tcp
        fi
        sudo ufw deny 3240/tcp
      else
        echo "WARNING: no ufw. Allow TCP 3240 only from $SUBNET with your firewall."
      fi
    fi
    ;;
  *) echo "Unsupported OS"; exit 1 ;;
esac

if [ "$MODE" = wireguard ]; then echo "WireGuard mode: connect your tunnel before you start Moonlight."; fi
echo "Done. Moonlight -> Add PC: $HOST (and $HOST:48089 / $HOST:48189 for displays 2 and 3)."
