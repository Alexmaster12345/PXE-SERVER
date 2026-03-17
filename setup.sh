#!/usr/bin/env bash
# =============================================================================
# setup.sh — PXE Network Boot Server Setup
# =============================================================================
# Installs and configures:
#   - dnsmasq  (DHCP + TFTP)
#   - nginx    (HTTP file server for kernels, kickstart files)
#   - syslinux (PXE bootloader files)
# Supports: Rocky Linux / RHEL / CentOS, Ubuntu / Debian
# Run as root: sudo bash setup.sh
# =============================================================================

set -euo pipefail

# ─── CONFIGURATION ────────────────────────────────────────────────────────────
# [EDIT] Set these for your environment
LAN_INTERFACE="ens160"
SERVER_IP="192.168.50.225"
DHCP_RANGE_START="192.168.50.100"
DHCP_RANGE_END="192.168.50.200"
SUBNET_MASK="255.255.255.0"
GATEWAY="192.168.50.1"
TFTP_ROOT="/var/lib/tftpboot"
HTTP_ROOT="/var/www/pxe"
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/var/log/pxe-setup.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*" | tee -a "$LOG_FILE"; }
success() { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }

# ─── ROOT CHECK ───────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Run this script as root: sudo bash setup.sh"

# ─── DETECT OS ────────────────────────────────────────────────────────────────
if command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
    SYSLINUX_PKG="syslinux"
    TFTP_PKG="tftp-server"
elif command -v apt-get &>/dev/null; then
    PKG_MGR="apt-get"
    SYSLINUX_PKG="syslinux syslinux-common pxelinux"
    TFTP_PKG="tftpd-hpa"
else
    error "Unsupported OS. Use Rocky Linux / RHEL / Ubuntu / Debian."
fi

info "Detected package manager: $PKG_MGR"
info "Server IP: $SERVER_IP  |  Interface: $LAN_INTERFACE"
info "TFTP root: $TFTP_ROOT  |  HTTP root: $HTTP_ROOT"

# ─── INSTALL PACKAGES ─────────────────────────────────────────────────────────
info "Installing packages..."
if [[ "$PKG_MGR" == "dnf" ]]; then
    dnf install -y dnsmasq nginx syslinux-tftpboot tftp-server memtest86+ 2>>"$LOG_FILE"
else
    apt-get update -qq
    apt-get install -y dnsmasq nginx syslinux syslinux-common pxelinux tftpd-hpa memtest86+ 2>>"$LOG_FILE"
fi
success "Packages installed."

# ─── CREATE DIRECTORY STRUCTURE ───────────────────────────────────────────────
info "Creating directory structure..."
mkdir -p "$TFTP_ROOT/pxelinux.cfg"
mkdir -p "$TFTP_ROOT/images/rocky9"
mkdir -p "$TFTP_ROOT/images/ubuntu2404"
mkdir -p "$TFTP_ROOT/images/memtest"
mkdir -p "$HTTP_ROOT/ks"
mkdir -p "$HTTP_ROOT/rocky9"
mkdir -p "$HTTP_ROOT/ubuntu2404"
success "Directories created."

# ─── COPY SYSLINUX FILES ──────────────────────────────────────────────────────
info "Copying PXE bootloader files (syslinux)..."
SYSLINUX_DIRS=(
    "/usr/share/syslinux"
    "/usr/lib/syslinux/modules/bios"
    "/usr/lib/syslinux"
    "/tftpboot"
)
SYSLINUX_FILES=(pxelinux.0 menu.c32 ldlinux.c32 libcom32.c32 libutil.c32 reboot.c32 vesamenu.c32)

for f in "${SYSLINUX_FILES[@]}"; do
    found=0
    for dir in "${SYSLINUX_DIRS[@]}"; do
        if [[ -f "$dir/$f" ]]; then
            cp "$dir/$f" "$TFTP_ROOT/"
            found=1
            break
        fi
    done
    if [[ $found -eq 0 ]]; then
        warn "Could not find $f — some menu features may not work."
    fi
done
success "Syslinux files copied."

# ─── COPY MEMTEST ─────────────────────────────────────────────────────────────
for mt in /boot/memtest86+ /boot/memtest86+-*.bin /usr/share/memtest86+/memtest.bin; do
    if [[ -f "$mt" ]]; then
        cp "$mt" "$TFTP_ROOT/images/memtest/memtest86+.bin"
        success "Memtest86+ copied."
        break
    fi
done

# ─── WRITE PXELINUX BOOT MENU ─────────────────────────────────────────────────
info "Writing PXE boot menu..."
sed "s/SERVER_IP/$SERVER_IP/g" "$SCRIPT_DIR/tftpboot/pxelinux.cfg/default" \
    > "$TFTP_ROOT/pxelinux.cfg/default"
success "Boot menu written to $TFTP_ROOT/pxelinux.cfg/default"

# ─── CONFIGURE DNSMASQ ────────────────────────────────────────────────────────
info "Configuring dnsmasq..."
cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak.$(date +%Y%m%d%H%M%S) 2>/dev/null || true

cat > /etc/dnsmasq.conf <<EOF
interface=${LAN_INTERFACE}
bind-interfaces
dhcp-range=${DHCP_RANGE_START},${DHCP_RANGE_END},${SUBNET_MASK},12h
dhcp-option=3,${GATEWAY}
dhcp-option=6,8.8.8.8,8.8.4.4
enable-tftp
tftp-root=${TFTP_ROOT}
dhcp-boot=pxelinux.0
log-dhcp
log-queries
log-facility=/var/log/dnsmasq-pxe.log
port=0
EOF
success "dnsmasq configured."

# ─── CONFIGURE NGINX ──────────────────────────────────────────────────────────
info "Configuring nginx as HTTP file server..."
cat > /etc/nginx/conf.d/pxe.conf <<EOF
server {
    listen 80;
    server_name _;
    root ${HTTP_ROOT};
    autoindex on;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

# Copy kickstart files into HTTP root
cp -v "$SCRIPT_DIR/http/ks/"*.cfg "$HTTP_ROOT/ks/" 2>>"$LOG_FILE" || true
# Substitute SERVER_IP in kickstart files
find "$HTTP_ROOT/ks" -name "*.cfg" -exec sed -i "s/SERVER_IP/$SERVER_IP/g" {} +
success "Nginx configured. Kickstart files deployed."

# ─── SET PERMISSIONS ──────────────────────────────────────────────────────────
chown -R nobody:nobody "$TFTP_ROOT" 2>/dev/null || chown -R tftp:tftp "$TFTP_ROOT" 2>/dev/null || true
chmod -R 755 "$TFTP_ROOT"
chmod -R 755 "$HTTP_ROOT"

# ─── FIREWALL ─────────────────────────────────────────────────────────────────
info "Opening firewall ports (DHCP:67, TFTP:69, HTTP:80)..."
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-service=dhcp   2>>"$LOG_FILE" || true
    firewall-cmd --permanent --add-service=tftp   2>>"$LOG_FILE" || true
    firewall-cmd --permanent --add-service=http   2>>"$LOG_FILE" || true
    firewall-cmd --reload 2>>"$LOG_FILE" || true
    success "firewalld rules applied."
elif command -v ufw &>/dev/null; then
    ufw allow 67/udp  2>>"$LOG_FILE" || true
    ufw allow 69/udp  2>>"$LOG_FILE" || true
    ufw allow 80/tcp  2>>"$LOG_FILE" || true
    success "ufw rules applied."
else
    warn "No firewall manager found — open ports 67/udp, 69/udp, 80/tcp manually."
fi

# ─── ENABLE AND START SERVICES ────────────────────────────────────────────────
info "Starting services..."
if [[ "$PKG_MGR" == "dnf" ]]; then
    systemctl enable --now dnsmasq
    systemctl enable --now nginx
else
    # On Ubuntu dnsmasq may conflict with systemd-resolved
    systemctl disable --now systemd-resolved 2>/dev/null || true
    systemctl enable --now dnsmasq
    systemctl enable --now nginx
fi
success "dnsmasq and nginx started."

# ─── SUMMARY ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  PXE Server Setup Complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  ${CYAN}Server IP:${NC}       $SERVER_IP"
echo -e "  ${CYAN}TFTP Root:${NC}       $TFTP_ROOT"
echo -e "  ${CYAN}HTTP Root:${NC}       $HTTP_ROOT"
echo -e "  ${CYAN}DHCP Range:${NC}      $DHCP_RANGE_START – $DHCP_RANGE_END"
echo -e "  ${CYAN}Boot menu:${NC}       $TFTP_ROOT/pxelinux.cfg/default"
echo -e "  ${CYAN}Kickstart:${NC}       http://$SERVER_IP/ks/"
echo ""
echo -e "  ${YELLOW}Next step:${NC} Run ./fetch-kernels.sh to download OS kernels."
echo -e "  ${YELLOW}Then:${NC}      PXE-boot any machine on the $LAN_INTERFACE network."
echo ""
echo -e "  Log: $LOG_FILE"
echo ""
