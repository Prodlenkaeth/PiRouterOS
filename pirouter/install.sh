#!/usr/bin/env bash
# ==========================================================================
#  pirouter installer  -  turns a fresh Raspberry Pi OS Lite (64-bit) into a
#  VPN travel router with kill switch and a whiptail control panel.
#
#  Run on the Pi (over SSH or console):
#      sudo bash install.sh
# ==========================================================================
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo bash install.sh"; exit 1; }

echo "==> pirouter installer"
echo "    source: $SRC"

# ---------------------------------------------------------------- packages
echo "==> Installing packages (this may take a few minutes)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends \
  hostapd dnsmasq iptables netfilter-persistent iptables-persistent \
  openvpn strongswan strongswan-pki libcharon-extra-plugins \
  xl2tpd ppp \
  python3 whiptail rfkill dnsutils curl unzip ca-certificates jq \
  procps iproute2

# ---------------------------------------------------------------- xray-core
install_xray() {
  if command -v xray >/dev/null 2>&1 && [ -x /usr/local/bin/xray ]; then
    echo "==> xray already installed: $(/usr/local/bin/xray version | head -1)"
    return
  fi
  local arch zip
  case "$(uname -m)" in
    aarch64|arm64) arch="arm64-v8a" ;;
    armv7l|armv6l) arch="arm32-v7a" ;;
    x86_64)        arch="64" ;;
    *) echo "!! unknown arch $(uname -m); skipping xray"; return ;;
  esac
  echo "==> Installing xray-core ($arch)..."
  local url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
  local tmp; tmp="$(mktemp -d)"
  if curl -fsSL "$url" -o "$tmp/xray.zip"; then
    unzip -o "$tmp/xray.zip" -d "$tmp" >/dev/null
    install -m 0755 "$tmp/xray" /usr/local/bin/xray
    mkdir -p /usr/local/share/xray
    cp -f "$tmp"/*.dat /usr/local/share/xray/ 2>/dev/null || true
    echo "    installed: $(/usr/local/bin/xray version | head -1)"
  else
    echo "!! Could not download xray (no internet?). VLESS/Proxy will be unavailable until you re-run installer."
  fi
  rm -rf "$tmp"
}
install_xray

# ---------------------------------------------------------------- copy files
echo "==> Installing pirouter files..."
mkdir -p /etc/pirouter/openvpn /etc/pirouter/xray
cp -rf "$SRC/files/usr/local/lib/pirouter" /usr/local/lib/
cp -f  "$SRC/files/usr/local/sbin/"pirouter* /usr/local/sbin/
cp -f  "$SRC/files/etc/systemd/system/"*.service /etc/systemd/system/
chmod +x /usr/local/sbin/pirouter /usr/local/sbin/pirouter-* /usr/local/lib/pirouter/*.py

# keep existing config on re-install
if [ ! -f /etc/pirouter/pirouter.conf ]; then
  cp -f "$SRC/files/etc/pirouter/pirouter.conf" /etc/pirouter/pirouter.conf
  echo "    wrote default config /etc/pirouter/pirouter.conf"
else
  echo "    keeping existing /etc/pirouter/pirouter.conf"
fi

# ---------------------------------------------------------------- free wlan0
echo "==> Releasing wlan0 from the OS network manager..."
if systemctl list-unit-files | grep -q '^NetworkManager.service'; then
  mkdir -p /etc/NetworkManager/conf.d
  cat >/etc/NetworkManager/conf.d/pirouter-unmanaged.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:wlan0
EOF
  systemctl restart NetworkManager 2>/dev/null || true
fi
if [ -f /etc/dhcpcd.conf ] && ! grep -q 'denyinterfaces wlan0' /etc/dhcpcd.conf; then
  echo 'denyinterfaces wlan0' >>/etc/dhcpcd.conf
fi
# stop wpa_supplicant fighting over wlan0 (eth0 WAN is unaffected)
systemctl disable --now wpa_supplicant 2>/dev/null || true
rfkill unblock wlan 2>/dev/null || true

# ---------------------------------------------------------------- services
echo "==> Enabling services..."
systemctl unmask hostapd 2>/dev/null || true
systemctl enable hostapd dnsmasq netfilter-persistent pirouter 2>/dev/null || true
# do not enable xray globally; pirouter-vpn manages it on demand
systemctl daemon-reload

echo
echo "=========================================================="
echo " pirouter installed."
echo
echo " Manage it any time with:   sudo pirouter"
echo
echo " Default Wi-Fi SSID : PiRouter"
echo " Default Wi-Fi pass : changeme123   (change it!)"
echo " Router LAN IP      : 192.168.33.1"
echo
echo " Reboot now to bring everything up:   sudo reboot"
echo "=========================================================="
