#!/usr/bin/env bash
set -euo pipefail

#######################################################################
# CONFIGURATION
#######################################################################

# Enable/disable UFW hardening (firewall)
ENABLE_UFW=1

# Enable/disable Nginx reverse proxy + (optionally) Let's Encrypt
ENABLE_NGINX=1

# FQDN for the controller UI (must resolve to this server's public IP)
LE_DOMAIN="vpn.example.com"

# Email for Let's Encrypt registration (required if LE_DOMAIN is set)
LE_EMAIL="admin@example.com"

#######################################################################
# CONSTANTS
#######################################################################

ZTN_DEB_URL="https://s3-us-west-1.amazonaws.com/key-networks/deb/ztncui/1/x86_64/ztncui_0.8.14_amd64.deb"
ZTN_DEB_FILE="/tmp/ztncui_0.8.14_amd64.deb"
ZTN_ENV_FILE="/opt/key-networks/ztncui/.env"

ZT_HOME="/var/lib/zerotier-one"
ZT_TOKEN_FILE="${ZT_HOME}/authtoken.secret"

NGINX_SITE="/etc/nginx/sites-available/ztncui.conf"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/ztncui.conf"

echo "=== ZeroTier + ZTNCUI + UFW + Nginx installer for Ubuntu 22.04 ==="

#######################################################################
# BASIC CHECKS
#######################################################################

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

#######################################################################
# 1. INSTALL ZEROTIER ONE
#######################################################################

echo
echo ">>> Installing ZeroTier One (controller capable)..."
echo

/usr/bin/curl -s https://install.zerotier.com | bash

echo
echo ">>> Enabling and starting zerotier-one.service..."
echo

systemctl enable --now zerotier-one

echo
echo ">>> Waiting for ZeroTier to generate identity and authtoken.secret..."
echo

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

#######################################################################
# 2. INSTALL ZTNCUI (DEB PACKAGE)
#######################################################################

echo
echo ">>> Installing ZTNCUI..."
echo

apt-get update -y

if [[ ! -f "${ZTN_DEB_FILE}" ]]; then
  cd /tmp
  curl -fSL "${ZTN_DEB_URL}" -o "${ZTN_DEB_FILE}"
fi

apt-get install -y "${ZTN_DEB_FILE}"

#######################################################################
# 3. CONFIGURE ZTNCUI (.env)
#######################################################################

echo
echo ">>> Configuring ZTNCUI environment in ${ZTN_ENV_FILE}..."
echo

mkdir -p "$(dirname "${ZTN_ENV_FILE}")"

cat > "${ZTN_ENV_FILE}" <<EOF
# ZeroTier controller API auth token
ZT_TOKEN=${ZT_TOKEN}

# Run ZTNCUI in production mode
NODE_ENV=production

# HTTP listener (local only, reverse proxied by Nginx)
HTTP_PORT=3000
EOF

chmod 400 "${ZTN_ENV_FILE}"
chown ztncui:ztncui "${ZTN_ENV_FILE}"

echo
echo ">>> Enabling and restarting ztncui.service..."
echo

systemctl enable ztncui
systemctl restart ztncui

#######################################################################
# 4. OPTIONAL: NGINX REVERSE PROXY + LET'S ENCRYPT
#######################################################################

if [[ "${ENABLE_NGINX}" -eq 1 ]]; then
  echo
  echo ">>> Installing Nginx and Certbot..."
  echo

  apt-get install -y nginx python3-certbot-nginx

  echo
  echo ">>> Configuring Nginx reverse proxy for ZTNCUI..."
  echo

  # Create Nginx site config
  cat > "${NGINX_SITE}" <<EOF
server {
    listen 80;
    server_name ${LE_DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

  ln -sf "${NGINX_SITE}" "${NGINX_SITE_LINK}"
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi

  nginx -t
  systemctl reload nginx

  # Let's Encrypt certificate via Certbot (only if domain + email configured)
  if [[ -n "${LE_DOMAIN}" && -n "${LE_EMAIL}" ]]; then
    echo
    echo ">>> Requesting Let's Encrypt certificate for ${LE_DOMAIN}..."
    echo

    certbot --nginx -d "${LE_DOMAIN}" \
      --non-interactive --agree-tos -m "${LE_EMAIL}" --redirect || {
        echo "WARNING: Certbot failed. Nginx is still serving HTTP on port 80."
      }
  else
    echo
    echo ">>> LE_DOMAIN or LE_EMAIL empty - skipping automatic Let's Encrypt."
    echo "    You can later run certbot manually, e.g.:"
    echo "      certbot --nginx -d your.domain.tld -m you@domain.tld --agree-tos --redirect"
  fi
fi

#######################################################################
# 5. OPTIONAL: UFW FIREWALL HARDENING
#######################################################################

if [[ "${ENABLE_UFW}" -eq 1 ]]; then
  echo
  echo ">>> Configuring UFW firewall..."
  echo

  apt-get install -y ufw

  # Allow SSH to avoid locking yourself out
  ufw allow OpenSSH

  # Allow Nginx HTTP/HTTPS if enabled
  if [[ "${ENABLE_NGINX}" -eq 1 ]]; then
    ufw allow 'Nginx Full'
  fi

  # Allow ZeroTier UDP port (controller / peers)
  ufw allow 9993/udp

  # Enable UFW (non-interactive)
  ufw --force enable
fi

#######################################################################
# SUMMARY
#######################################################################

echo
echo "==========================================================="
echo "INSTALLATION COMPLETE"
echo
echo "Services:"
echo "  - ZeroTier One:  systemctl status zerotier-one"
echo "  - ZTNCUI:        systemctl status ztncui"
if [[ "${ENABLE_NGINX}" -eq 1 ]]; then
  echo "  - Nginx:         systemctl status nginx"
fi
echo

if [[ "${ENABLE_NGINX}" -eq 1 && -n "${LE_DOMAIN}" ]]; then
  echo "Web UI via reverse proxy:"
  echo "  https://${LE_DOMAIN}"
  echo
else
  echo "Web UI directly (no reverse proxy / or HTTP only):"
  echo "  http://<this-server-ip>:3000"
  echo
fi

echo "ZTNCUI default login (change immediately):"
echo "  user:     admin"
echo "  password: password"
echo
echo "Security notes:"
echo "  - Change the default admin password right after first login."
echo "  - Restrict access to the UI (VPN, trusted IPs, security groups, etc.)."
echo "  - Review UFW rules: ufw status verbose"
echo "==========================================================="
