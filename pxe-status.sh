#!/usr/bin/env bash
# =============================================================================
# pxe-status.sh — PXE Server Health Check & Diagnostics
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[✔]${NC} $*"; }
fail() { echo -e "  ${RED}[✘]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[!]${NC} $*"; }
hdr()  { echo -e "\n${CYAN}── $* ──${NC}"; }

TFTP_ROOT="/var/lib/tftpboot"
HTTP_ROOT="/var/www/pxe"

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  PXE Server Status Report${NC}"
echo -e "${CYAN}============================================================${NC}"

# ─── Services ────────────────────────────────────────────────────────────────
hdr "Services"
for svc in dnsmasq nginx; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        ok "$svc is running"
    else
        fail "$svc is NOT running  →  sudo systemctl start $svc"
    fi
done

# ─── Ports ────────────────────────────────────────────────────────────────────
hdr "Listening Ports"
check_port() {
    local port=$1 proto=$2 label=$3
    if ss -lnup 2>/dev/null | grep -q ":${port}" || ss -lntp 2>/dev/null | grep -q ":${port}"; then
        ok "Port $port/$proto ($label) is open"
    else
        fail "Port $port/$proto ($label) NOT listening"
    fi
}
check_port 67  udp  "DHCP"
check_port 69  udp  "TFTP"
check_port 80  tcp  "HTTP"

# ─── TFTP Files ───────────────────────────────────────────────────────────────
hdr "TFTP Bootloader Files ($TFTP_ROOT)"
for f in pxelinux.0 menu.c32 ldlinux.c32 libcom32.c32 libutil.c32; do
    if [[ -f "$TFTP_ROOT/$f" ]]; then
        ok "$f"
    else
        fail "$f MISSING"
    fi
done

# ─── Kernel Images ────────────────────────────────────────────────────────────
hdr "Kernel Images"
declare -A KERNELS=(
    ["Rocky 9 vmlinuz"]="$TFTP_ROOT/images/rocky9/vmlinuz"
    ["Rocky 9 initrd"]="$TFTP_ROOT/images/rocky9/initrd.img"
    ["Ubuntu 24.04 vmlinuz"]="$TFTP_ROOT/images/ubuntu2404/vmlinuz"
    ["Ubuntu 24.04 initrd"]="$TFTP_ROOT/images/ubuntu2404/initrd.gz"
    ["Memtest86+"]="$TFTP_ROOT/images/memtest/memtest86+.bin"
)
for label in "${!KERNELS[@]}"; do
    f="${KERNELS[$label]}"
    if [[ -f "$f" ]]; then
        size=$(du -sh "$f" | cut -f1)
        ok "$label  ($size)"
    else
        warn "$label NOT found — run: sudo bash fetch-kernels.sh"
    fi
done

# ─── Kickstart Files ──────────────────────────────────────────────────────────
hdr "Kickstart / Preseed Files ($HTTP_ROOT/ks)"
for f in rocky9-ks.cfg ubuntu2404-preseed.cfg; do
    if [[ -f "$HTTP_ROOT/ks/$f" ]]; then
        ok "$f"
    else
        fail "$f MISSING  →  re-run setup.sh"
    fi
done

# ─── Boot Menu ────────────────────────────────────────────────────────────────
hdr "Boot Menu"
if [[ -f "$TFTP_ROOT/pxelinux.cfg/default" ]]; then
    ok "pxelinux.cfg/default present"
    if grep -q "SERVER_IP" "$TFTP_ROOT/pxelinux.cfg/default" 2>/dev/null; then
        warn "Boot menu still contains placeholder SERVER_IP — run setup.sh"
    else
        ok "SERVER_IP substituted correctly"
    fi
else
    fail "pxelinux.cfg/default MISSING"
fi

# ─── Network ──────────────────────────────────────────────────────────────────
hdr "Network Interfaces"
ip -4 addr show | awk '/inet /{print "  "$2}' | while read -r addr; do
    echo -e "  ${CYAN}→${NC} $addr"
done

# ─── Recent DHCP/PXE Activity ────────────────────────────────────────────────
hdr "Recent PXE Activity (last 10 lines of /var/log/dnsmasq-pxe.log)"
if [[ -f /var/log/dnsmasq-pxe.log ]]; then
    tail -n 10 /var/log/dnsmasq-pxe.log | while read -r line; do
        echo "  $line"
    done
else
    warn "No log yet at /var/log/dnsmasq-pxe.log (no clients have booted yet)"
fi

echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "  Tip: ${YELLOW}tail -f /var/log/dnsmasq-pxe.log${NC}  to watch live boots"
echo -e "${CYAN}============================================================${NC}"
echo ""
