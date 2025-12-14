#!/usr/bin/env bash
set -euo pipefail

### Simple installer for:
# - ZeroTier One (controller-capable)
# - ZTNCUI (ZeroTier Network Controller UI) on Ubuntu 22.04

ZTN_DEB_URL="https://s3-us-west-1.amazonaws.com/key-networks/deb/ztncui/1/x86_64/ztncui_0.8.14_amd64.deb"
ZTN_DEB_FILE="/tmp/ztncui_0.8.14_amd64.deb"
ZTN_ENV_FILE="/opt/key-networks/ztncui/.env"
ZT_HOME="/var/lib/zerotier-one"
ZT_TOKEN_FILE="${ZT_HOME}/authtoken.secret"

echo "=== ZeroTier + ZTNCUI installer for Ubuntu 22.04 ==="

## 1. Basic checks
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo -i)."
  exit 1
fi

if command -v lsb_release >/dev/null 2>&1; then
  DISTRO=$(lsb_release -is || true)
  RELEASE=$(lsb_release -rs || true)
  if [[ "${DISTRO}" != "Ubuntu" || "${RELEASE}" != "22.04" ]]; then
    echo "WARNING: Detected ${DISTRO} ${RELEASE}, but this script is written for Ubuntu 22.04."
    echo "         Continuing anyway in 5 seconds... (Ctrl+C to abort)"
    sleep 5
  fi
fi

echo
echo ">>> Installing ZeroTier One (controller capable)..."
echo

## 2. Install ZeroTier One (official installer)
# This adds the repo and installs zerotier-one from it.
/usr/bin/curl -s https://install.zerotier.com | bash

echo
echo ">>> Enabling and starting zerotier-one.service..."
echo

systemctl enable --now zerotier-one

echo
echo ">>> Waiting for ZeroTier to generate identity and authtoken.secret..."
echo

# Wait up to ~15 seconds for authtoken.secret to appear
for i in {1..15}; do
  if [[ -f "${ZT_TOKEN_FILE}" ]]; then
    break
  fi
  sleep 1
done

if [[ ! -f "${ZT_TOKEN_FILE}" ]]; then
  echo "ERROR: ${ZT_TOKEN_FILE} not found. zerotier-one may have failed to start."
  echo "Check: systemctl status zerotier-one"
  exit 1
fi

ZT_TOKEN=$(cat "${ZT_TOKEN_FILE}")

echo
echo ">>> ZeroTier is installed and running. Controller data dir: ${ZT_HOME}"
echo

## 3. Install ZTNCUI (DEB package)

echo
echo ">>> Downloading ZTNCUI DEB package..."
echo

apt-get update -y

if [[ ! -f "${ZTN_DEB_FILE}" ]]; then
  cd /tmp
  curl -fSL "${ZTN_DEB_URL}" -o "${ZTN_DEB_FILE}"
fi

echo
echo ">>> Installing ZTNCUI from ${ZTN_DEB_FILE}..."
echo

apt-get install -y "${ZTN_DEB_FILE}"

## 4. Configure ZTNCUI environment (.env)

echo
echo ">>> Configuring ZTNCUI environment in ${ZTN_ENV_FILE}..."
echo

mkdir -p "$(dirname "${ZTN_ENV_FILE}")"

cat > "${ZTN_ENV_FILE}" <<EOF
# ZeroTier controller API auth token
ZT_TOKEN=${ZT_TOKEN}

# Run ZTNCUI in production mode
NODE_ENV=production

# HTTPS listener for web UI (self-signed cert by default)
HTTPS_PORT=3443
EOF

chmod 400 "${ZTN_ENV_FILE}"
chown ztncui:ztncui "${ZTN_ENV_FILE}"

## 5. Enable and restart ZTNCUI service

echo
echo ">>> Enabling and restarting ztncui.service..."
echo

systemctl enable ztncui
systemctl restart ztncui

echo
echo "==========================================================="
echo "INSTALLATION COMPLETE"
echo
echo "Services:"
echo "  - ZeroTier One:  systemctl status zerotier-one"
echo "  - ZTNCUI:        systemctl status ztncui"
echo
echo "Web UI (HTTPS, self-signed cert):"
echo "  https://<this-server-ip>:3443"
echo
echo "Default login:"
echo "  user:     admin"
echo "  password: password"
echo
echo "Security reminder:"
echo "  - Change the default admin password immediately."
echo "  - Restrict access to port 3443 using your firewall (ufw/iptables/load balancer)."
echo "==========================================================="
