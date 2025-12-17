#!/usr/bin/env bash

# --- Bash Strict Mode ---
set -euo pipefail

# --- Color Definitions ---
R='\033[0;31m'    # Red
G='\033[0;32m'    # Green
Y='\033[1;33m'    # Yellow
B='\033[0;34m'    # Blue
P='\033[0;35m'    # Purple
C='\033[0;36m'    # Cyan
W='\033[1;37m'    # White
NC='\033[0m'      # No Color
BOLD='\033[1m'

# --- Simple Progress Helpers ---
step_init() {
    echo -ne " ${W}•${NC}  $1... \r"
}

step_done() {
    echo -e " ${G}✔${NC}  $1 ${G}Done${NC}"
}

step_fail() {
    echo -e " ${R}✘${NC}  $1 ${R}Failed${NC}"
    exit 1
}

# --- Variables ---
ZTN_DEB_URL="https://s3-us-west-1.amazonaws.com/key-networks/deb/ztncui/1/x86_64/ztncui_0.8.14_amd64.deb"
ZTN_DEB_FILE="/tmp/ztncui_0.8.14_amd64.deb"
ZTN_ENV_FILE="/opt/key-networks/ztncui/.env"
ZT_HOME="/var/lib/zerotier-one"
ZT_TOKEN_FILE="${ZT_HOME}/authtoken.secret"

# ==========================================
# 0. INITIAL CHECKS & DYNAMIC MENU
# ==========================================
if [[ $EUID -ne 0 ]]; then
   echo -e "${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
   echo -e "${R}${BOLD}  CRITICAL ERROR: ROOT PRIVILEGE REQUIRED${NC}"
   echo -e "${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
   echo -e "  Please restart with: ${G}sudo $0${NC}"
   exit 1
fi

MSG=""
while true; do
    clear
    echo -e "${B}${BOLD}"
    echo "  ███████╗███████╗██████╗  ██████╗ ████████╗██╗███████╗██████╗ "
    echo "  ╚══███╔╝██╔════╝██╔══██╗██╔═══██╗╚══██╔══╝██║██╔════╝██╔══██╗"
    echo "    ███╔╝ █████╗  ██████╔╝██║   ██║   ██║   ██║█████╗  ██████╔╝"
    echo "   ███╔╝  ██╔══╝  ██╔══██╗██║   ██║   ██║   ██║██╔══╝  ██╔══██╗"
    echo "  ███████╗███████╗██║  ██║╚██████╔╝   ██║   ██║███████╗██║  ██║"
    echo "  ╚══════╝╚══════╝╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═╝╚══════╝╚═╝  ╚═╝"
    echo -e "${NC}${P}               ZeroTier + ZTNCUI Auto-Installer${NC}\n"

    if [[ -n "$MSG" ]]; then
        echo -e "$MSG\n"
    fi

    echo -e "${W}${BOLD}Select Installation Type:${NC}"
    echo -e " 1) ${G}Full Stack${NC} (ZeroTier One + ZTNCUI)"
    echo -e " 2) ${B}Core Only${NC}  (ZeroTier One Only)"
    echo -e " 3) ${R}Exit${NC}"
    echo
    read -p " Selection [1-3]: " CHOICE

    case "$CHOICE" in
        1|2) break ;;
        3) exit 0 ;;
        "") MSG=" ${Y}⚠ WARNING: Input cannot be empty. Please choose an option.${NC}" ;;
        *) MSG=" ${R}✘ ERROR: Invalid choice '$CHOICE'. Please enter 1, 2, or 3.${NC}" ;;
    esac
done

# ==========================================
# 1. CORE DETECTION LOGIC
# ==========================================
SKIP_CORE=false
if command -v zerotier-cli >/dev/null 2>&1; then
    if [[ "$CHOICE" == "1" ]]; then
        echo -e "\n ${Y}! Detected: ZeroTier One is already installed.${NC}"
        while true; do
            read -p "   Install ZTNCUI interface only? [y/N]: " skip_confirm
            case "$skip_confirm" in
                [Yy]* ) SKIP_CORE=true; break ;;
                [Nn]* ) echo -e " ${R}Exiting script as requested.${NC}"; exit 0 ;;
                "" )    echo -e " ${Y}  ⚠ Please choose Y to continue or N to exit.${NC}" ;;
                * )     echo -e " ${R}  ✘ Invalid input.${NC}" ;;
            esac
        done
    fi
    ZT_INSTALLED=true
else
    ZT_INSTALLED=false
fi

echo -e "\n${BOLD}Applying Changes:${NC}"

# ==========================================
# 2. CORE INSTALLATION
# ==========================================
if [ "$SKIP_CORE" = false ]; then
    S1="Installing ZeroTier One Core"
    step_init "$S1"
    curl -s https://install.zerotier.com | bash > /dev/null 2>&1 || step_fail "$S1"
    step_done "$S1"

    S2="Starting ZeroTier Service"
    step_init "$S2"
    systemctl enable --now zerotier-one > /dev/null 2>&1 || step_fail "$S2"
    step_done "$S2"
else
    echo -e " ${B}ℹ${NC}  ZeroTier Core installation ${B}Skipped${NC} (Already present)"
fi

S3="Verifying Auth Token"
step_init "$S3"
TOKEN_FOUND=false
for i in {1..20}; do 
    if [[ -f "${ZT_TOKEN_FILE}" ]]; then
        TOKEN_FOUND=true
        break
    fi
    sleep 1
done

if [ "$TOKEN_FOUND" = true ]; then
    ZT_TOKEN=$(cat "${ZT_TOKEN_FILE}")
    step_done "$S3"
else
    step_fail "$S3"
fi

# ==========================================
# 3. ZTNCUI INSTALLATION (Choice 1 Only)
# ==========================================
if [[ "$CHOICE" == "1" ]]; then
    S4="Updating Package Cache"
    step_init "$S4"
    apt-get update -qq || step_fail "$S4"
    step_done "$S4"

    S5="Downloading ZTNCUI"
    step_init "$S5"
    curl -fSL "${ZTN_DEB_URL}" -o "${ZTN_DEB_FILE}" > /dev/null 2>&1 || step_fail "$S5"
    step_done "$S5"

    S6="Installing ZTNCUI"
    step_init "$S6"
    apt-get install -y "${ZTN_DEB_FILE}" > /dev/null 2>&1 || step_fail "$S6"
    step_done "$S6"
    
    S7="Configuring Environment"
    step_init "$S7"
    mkdir -p "$(dirname "${ZTN_ENV_FILE}")"
    cat > "${ZTN_ENV_FILE}" <<EOF
ZT_TOKEN=${ZT_TOKEN}
NODE_ENV=production
HTTPS_PORT=3443
EOF
    chmod 400 "${ZTN_ENV_FILE}"
    chown ztncui:ztncui "${ZTN_ENV_FILE}"
    systemctl enable ztncui > /dev/null 2>&1
    systemctl restart ztncui > /dev/null 2>&1
    rm -f "${ZTN_DEB_FILE}"
    step_done "$S7"
    
    S8="Verifying Web Access (3443)"
    step_init "$S8"
    sleep 2
    if timeout 2 bash -c "cat < /dev/null > /dev/tcp/127.0.0.1/3443" 2>/dev/null; then
        step_done "$S8"
    else
        step_fail "$S8"
    fi
fi

# ==========================================
# 4. FINAL SUMMARY
# ==========================================
MY_IP=$(hostname -I | awk '{print $1}')

echo -e "\n${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${G}${BOLD}           INSTALLATION COMPLETE!${NC}"
echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [[ "$CHOICE" == "1" ]]; then
    echo -e " ${W}Web UI URL:${NC}   ${C}https://${MY_IP}:3443${NC}"
    echo -e " ${W}Credentials:${NC}  ${Y}admin / password${NC}"
    echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e " ${Y}⚠ Change the admin password immediately.${NC}"
else
    echo -e " ${W}Node ID:${NC}      ${C}$(zerotier-cli status | awk '{print $3}')${NC}"
    echo -e " ${W}Join Cmd:${NC}     ${G}zerotier-cli join <network-id>${NC}"
    echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
fi