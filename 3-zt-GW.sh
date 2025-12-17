#!/bin/bash

# --- Bash Strict Mode ---
set -euo pipefail

# --- Enhanced Color Palette ---
R='\033[0;31m'    # Red
G='\033[0;32m'    # Green
Y='\033[1;33m'    # Yellow
B='\033[0;34m'    # Blue
P='\033[0;35m'    # Purple
C='\033[0;36m'    # Cyan
W='\033[1;37m'    # White
NC='\033[0m'      # No Color

# ==========================================
# 0. ROOT PRIVILEGE CHECK
# ==========================================
if [[ $EUID -ne 0 ]]; then
   echo -e "${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
   echo -e "${R}  CRITICAL ERROR: ACCESS DENIED${NC}"
   echo -e "${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
   echo -e "  Please restart with: ${G}sudo $0${NC}"
   echo -e "${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
   exit 1
fi

# Check for dry-run flag
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo -e "${P}>>> DRY RUN MODE ENABLED: No changes will be applied. <<<${NC}\n"
fi

echo -e "${B}============================================================${NC}"
echo -e "${W}      ZeroTier Router Setup Script${NC}"
echo -e "${B}============================================================${NC}"

# --- CONFIGURATION START ---
echo -e "${C}1. Detecting Network Interfaces...${NC}"

# Improved detection: strips @ifXXX and cleans up whitespace
AVAILABLE_INTERFACES=$(ip -o link show | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep -vE 'lo|zt' | xargs)

if [ -z "$AVAILABLE_INTERFACES" ]; then
    echo -e "${R}!!! ERROR !!! No physical network interfaces found.${NC}"
    exit 1
fi

# Convert string to array safely
read -ra INT_ARRAY <<< "$AVAILABLE_INTERFACES"
DEFAULT_INT=${INT_ARRAY[0]}

echo -e "${Y}Available interfaces found:${NC}"
for i in "${!INT_ARRAY[@]}"; do
    if [ $i -eq 0 ]; then
        echo -e "  $i) ${G}${INT_ARRAY[$i]} (Recommended Default)${NC}"
    else
        echo -e "  $i) ${W}${INT_ARRAY[$i]}${NC}"
    fi
done

echo -en "\n${Y}Choose the PUBLIC interface (Internet exit) [${G}$DEFAULT_INT${Y}]: ${NC}"
read -r USER_INPUT

if [ -z "$USER_INPUT" ]; then
    PUBLIC_INTERFACE=$DEFAULT_INT
elif [[ "$USER_INPUT" =~ ^[0-9]+$ ]] && [ "$USER_INPUT" -lt "${#INT_ARRAY[@]}" ]; then
    PUBLIC_INTERFACE=${INT_ARRAY[$USER_INPUT]}
else
    # Also strip @ from manual input just in case
    PUBLIC_INTERFACE=$(echo "$USER_INPUT" | cut -d'@' -f1)
fi

# Final check for validity
if ! ip link show "$PUBLIC_INTERFACE" > /dev/null 2>&1; then
    echo -e "${R}Error: Interface '$PUBLIC_INTERFACE' is not valid.${NC}"
    exit 1
fi

echo -e "${G}✅ Selected Public Interface: ${W}${PUBLIC_INTERFACE}${NC}"

# --- Automatic ZeroTier Detection ---
echo -e "\n${C}2. Searching for ZeroTier interface...${NC}"
ZT_INTERFACE=$(ip -o link show | awk '/zt/{print $2}' | cut -d'@' -f1 | sed 's/://' | head -n 1 | xargs || echo "")

if [ -z "$ZT_INTERFACE" ]; then
    echo -e "${R}!!! ERROR !!! Could not find an active ZeroTier interface (zt*).${NC}"
    exit 1
fi

echo -e "${G}✅ Auto-Detected ZeroTier Interface: ${W}${ZT_INTERFACE}${NC}"
echo -e "${B}----------------------------------------------${NC}"

# 1. IP Forwarding
echo -e "\n${C}3. Enabling IP forwarding...${NC}"
if $DRY_RUN; then
    echo -e "${P}[DRY-RUN] Would add 'net.ipv4.ip_forward = 1' to /etc/sysctl.conf${NC}"
else
    LINE_TO_ADD="net.ipv4.ip_forward = 1"
    if grep -qF "$LINE_TO_ADD" /etc/sysctl.conf; then
        echo -e "  -> ${Y}net.ipv4.ip_forward is already set.${NC}"
    else
        echo "$LINE_TO_ADD" | sudo tee -a /etc/sysctl.conf > /dev/null
        echo -e "  -> ${G}Forwarding enabled in /etc/sysctl.conf.${NC}"
    fi
    sudo sysctl -p > /dev/null
fi

# 2. Persistence Tools
echo -e "\n${C}4. Checking persistence tools...${NC}"
if ! command -v netfilter-persistent &> /dev/null; then
    if $DRY_RUN; then
        echo -e "${P}[DRY-RUN] Would install iptables-persistent and netfilter-persistent${NC}"
    else
        echo -e "  -> ${W}Installing tools...${NC}"
        sudo apt update && sudo DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent netfilter-persistent
    fi
else
    echo -e "  -> ${Y}Persistence tools already present.${NC}"
fi

# 3. Apply Rules
echo -e "\n${C}5. Configuring NAT/Routing Rules...${NC}"
if $DRY_RUN; then
    echo -e "${P}[DRY-RUN] sudo iptables -t nat -A POSTROUTING -o ${PUBLIC_INTERFACE} -j MASQUERADE${NC}"
    echo -e "${P}[DRY-RUN] sudo iptables -A FORWARD -i ${ZT_INTERFACE} -o ${PUBLIC_INTERFACE} -j ACCEPT${NC}"
    echo -e "${P}[DRY-RUN] sudo iptables -A FORWARD -i ${PUBLIC_INTERFACE} -o ${ZT_INTERFACE} -m state --state RELATED,ESTABLISHED -j ACCEPT${NC}"
else
    # Clean old rules to prevent duplicates
    sudo iptables -t nat -D POSTROUTING -o "${PUBLIC_INTERFACE}" -j MASQUERADE 2>/dev/null || true
    sudo iptables -D FORWARD -i "${ZT_INTERFACE}" -o "${PUBLIC_INTERFACE}" -j ACCEPT 2>/dev/null || true
    sudo iptables -D FORWARD -i "${PUBLIC_INTERFACE}" -o "${ZT_INTERFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    
    # Apply new rules
    sudo iptables -t nat -A POSTROUTING -o "${PUBLIC_INTERFACE}" -j MASQUERADE
    sudo iptables -A FORWARD -i "${ZT_INTERFACE}" -o "${PUBLIC_INTERFACE}" -j ACCEPT
    sudo iptables -A FORWARD -i "${PUBLIC_INTERFACE}" -o "${ZT_INTERFACE}" -m state --state RELATED,ESTABLISHED -j ACCEPT
    echo -e "  -> ${G}Rules applied.${NC}"
fi

# 4. Save Rules
echo -e "\n${C}6. Making rules persistent...${NC}"
if $DRY_RUN; then
    echo -e "${P}[DRY-RUN] Would run: sudo netfilter-persistent save${NC}"
else
    sudo netfilter-persistent save > /dev/null
    echo -e "  -> ${G}Rules saved successfully.${NC}"
fi

echo -e "\n${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${G}✅ SETUP COMPLETE!${NC}"
echo -e "  ${W}Public Int:${NC}  ${C}${PUBLIC_INTERFACE}${NC}"
echo -e "  ${W}ZeroTier Int:${NC} ${C}${ZT_INTERFACE}${NC}"
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"