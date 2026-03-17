#!/usr/bin/env bash
# =============================================================================
# fetch-kernels.sh — Download netboot kernels for PXE
# =============================================================================
# Downloads vmlinuz + initrd for each OS into /var/lib/tftpboot/images/
# Run as root AFTER setup.sh: sudo bash fetch-kernels.sh
# =============================================================================

set -euo pipefail

TFTP_ROOT="/var/lib/tftpboot"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash fetch-kernels.sh"

command -v wget &>/dev/null || { dnf install -y wget 2>/dev/null || apt-get install -y wget; }

# =============================================================================
# Rocky Linux 9 — netboot kernel + initrd
# =============================================================================
ROCKY9_DIR="$TFTP_ROOT/images/rocky9"
ROCKY9_BASE="https://download.rockylinux.org/pub/rocky/9/BaseOS/x86_64/os/images/pxeboot"

info "Fetching Rocky Linux 9 netboot kernel..."
mkdir -p "$ROCKY9_DIR"
wget -q --show-progress -O "$ROCKY9_DIR/vmlinuz"   "$ROCKY9_BASE/vmlinuz"
wget -q --show-progress -O "$ROCKY9_DIR/initrd.img" "$ROCKY9_BASE/initrd.img"
success "Rocky Linux 9 kernel + initrd saved to $ROCKY9_DIR"

# Also mirror the minimal repo for offline install (optional — large download ~800MB)
# Uncomment to enable full local mirror:
# HTTP_ROOT="/var/www/pxe"
# info "Mirroring Rocky 9 repo (this will take a while)..."
# rsync -avz --progress rsync://dl.rockylinux.org/rocky/9/BaseOS/x86_64/os/ "$HTTP_ROOT/rocky9/"

# =============================================================================
# Ubuntu 24.04 LTS — netboot kernel + initrd
# =============================================================================
UBUNTU_DIR="$TFTP_ROOT/images/ubuntu2404"
UBUNTU_BASE="http://archive.ubuntu.com/ubuntu/dists/noble/main/installer-amd64/current/legacy-images/netboot/ubuntu-installer/amd64"

info "Fetching Ubuntu 24.04 netboot kernel..."
mkdir -p "$UBUNTU_DIR"
wget -q --show-progress -O "$UBUNTU_DIR/vmlinuz"   "$UBUNTU_BASE/linux"
wget -q --show-progress -O "$UBUNTU_DIR/initrd.gz" "$UBUNTU_BASE/initrd.gz"
success "Ubuntu 24.04 kernel + initrd saved to $UBUNTU_DIR"

# =============================================================================
# Memtest86+ (if not already present)
# =============================================================================
MEMTEST_DIR="$TFTP_ROOT/images/memtest"
mkdir -p "$MEMTEST_DIR"
if [[ ! -f "$MEMTEST_DIR/memtest86+.bin" ]]; then
    info "Fetching Memtest86+..."
    MEMTEST_URL="https://www.memtest.org/download/v7.00/mt86plus_7.00.binaries.zip"
    TMP_ZIP=$(mktemp /tmp/memtest.XXXXXX.zip)
    wget -q --show-progress -O "$TMP_ZIP" "$MEMTEST_URL"
    command -v unzip &>/dev/null || { dnf install -y unzip 2>/dev/null || apt-get install -y unzip; }
    unzip -j "$TMP_ZIP" "*.bin" -d "$MEMTEST_DIR/" 2>/dev/null \
        && mv "$MEMTEST_DIR/"memtest64.bin "$MEMTEST_DIR/memtest86+.bin" 2>/dev/null || true
    rm -f "$TMP_ZIP"
    success "Memtest86+ saved to $MEMTEST_DIR"
else
    info "Memtest86+ already present, skipping."
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Kernel Download Complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  Files in $TFTP_ROOT/images/:"
find "$TFTP_ROOT/images" -type f | sort | while read -r f; do
    SIZE=$(du -sh "$f" | cut -f1)
    echo "    [$SIZE]  $f"
done
echo ""
echo -e "  ${YELLOW}Next:${NC} PXE-boot any machine on your LAN."
echo -e "  ${YELLOW}Watch logs:${NC} tail -f /var/log/dnsmasq-pxe.log"
echo ""
