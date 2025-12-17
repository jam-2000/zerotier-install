#!/bin/bash

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

# Helper function for dry-run execution
run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo -e "${P}[DRY-RUN] Executing:${NC} $@"
    else
        eval "$@"
    fi
}

# ==========================================
# 1. PRE-FLIGHT CONFLICT CHECK
# ==========================================
echo -e "${C}🔍 Checking for system conflicts...${NC}"

# Check for other DNS servers on Port 53 (excluding systemd-resolved)
PORT_53_PID=$(ss -lptn 'sport = :53' | grep -v "systemd-resolve" | grep "LISTEN" | awk '{print $6}' | cut -d',' -f2 | cut -d'=' -f2)

if [ ! -z "$PORT_53_PID" ]; then
    PROCESS_NAME=$(ps -p $PORT_53_PID -o comm=)
    echo -e "${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${R}  CONFLICT DETECTED: Port 53 is already in use!${NC}"
    echo -e "  Process: ${Y}$PROCESS_NAME${NC} (PID: $PORT_53_PID)"
    echo -e "${R}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Please stop or uninstall ${W}$PROCESS_NAME${NC} before proceeding."
    exit 1
fi

# Check for existing dnsmasq
if dpkg -l | grep -q dnsmasq; then
    echo -e "${Y}⚠️ Existing dnsmasq installation found. Configs will be purged.${NC}"
fi

# Detect ZeroTier
ZT_IFACE=$(zerotier-cli listnetworks -j | grep portDeviceName | cut -d '"' -f 4 | head -n 1)
if [ -z "$ZT_IFACE" ]; then
    echo -e "${R}❌ Error: No ZeroTier interface found. Please join a network first.${NC}"
    exit 1
fi
echo -e "${G}✅ No port conflicts found. ZeroTier interface: $ZT_IFACE${NC}"

# ==========================================
# 2. CLEANUP & INSTALLATION
# ==========================================
echo -e "\n${B}🛠️ Preparing dnsmasq...${NC}"
run_cmd "apt update -qq && apt install -y dnsmasq > /dev/null"
run_cmd "systemctl stop dnsmasq"

if [ "$DRY_RUN" = false ]; then
    # Wipe existing configs to ensure a clean state
    rm -f /etc/dnsmasq.conf
    rm -rf /etc/dnsmasq.d/*
    echo -e "${G}✅ Old dnsmasq configurations cleared.${NC}"
fi

# ==========================================
# 3. DNS SOURCE SELECTION
# ==========================================
echo -e "\n${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${W}  SELECT UPSTREAM DNS FORWARDER${NC}"
echo -e "${Y}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "1) ${C}Host's System DNS${NC} (via nmcli/resolv.conf)"
echo -e "2) ${C}Custom DNS${NC} (e.g., 8.8.8.8)"
read -p "Selection [1-2]: " DNS_CHOICE

if [ "$DNS_CHOICE" == "1" ]; then
    UPSTREAM_DNS=$(nmcli dev show | grep 'IP4.DNS\[1\]' | awk '{print $2}' | head -n 1)
    if [ -z "$UPSTREAM_DNS" ]; then
        UPSTREAM_DNS=$(grep -m 1 "nameserver" /etc/resolv.conf | awk '{print $2}')
    fi
    echo -e "${G}🎯 Auto-detected Upstream:${NC} $UPSTREAM_DNS"
else
    read -p "Enter custom DNS IP: " UPSTREAM_DNS
fi

# ==========================================
# 4. APPLY CONFIGURATION
# ==========================================
echo -e "\n${B}📝 Generating isolated dnsmasq configuration...${NC}"

# Configure dnsmasq to answer for ZT and Local only
# 'bind-dynamic' is often safer for virtual interfaces like ZeroTier
CONF_CONTENT="interface=$ZT_IFACE
interface=lo
bind-interfaces
server=$UPSTREAM_DNS
domain-needed
bogus-priv
no-resolv
cache-size=10000
log-queries"

if [ "$DRY_RUN" = true ]; then
    echo -e "${P}Proposed /etc/dnsmasq.conf:${NC}\n$CONF_CONTENT"
else
    echo "$CONF_CONTENT" > /etc/dnsmasq.conf
    
    # Resolve Port 53 conflict with systemd-resolved
    echo -e "${B}⚙️ Modifying systemd-resolved to release Port 53...${NC}"
    sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
    sed -i 's/DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
fi

# ==========================================
# 5. RESTART & VERIFY
# ==========================================
echo -e "\n${C}🚀 Restarting services...${NC}"
run_cmd "systemctl restart systemd-resolved"
run_cmd "systemctl enable dnsmasq"
run_cmd "systemctl restart dnsmasq"

if [ "$DRY_RUN" = false ]; then
    echo -e "\n${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${W}  SUCCESS: DNS forwarder is active on $ZT_IFACE${NC}"
    echo -e "${G}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Testing listener: $(ss -lptn 'sport = :53' | grep dnsmasq | awk '{print $4}')"
fi