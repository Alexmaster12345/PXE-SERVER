#!/usr/bin/env bash
# =============================================================================
# start.sh — Install deps and start PXE Web UI on port 9000
# Run as root: sudo bash start.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/venv"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash start.sh"

# Install python3 + venv if missing
if ! command -v python3 &>/dev/null; then
    info "Installing python3..."
    dnf install -y python3 python3-pip 2>/dev/null || apt-get install -y python3 python3-pip
fi

# Create virtualenv
if [[ ! -d "$VENV" ]]; then
    info "Creating virtual environment..."
    python3 -m venv "$VENV"
fi

# Install dependencies
info "Installing Python dependencies..."
"$VENV/bin/pip" install -q -r "$SCRIPT_DIR/requirements.txt"
success "Dependencies installed."

# Install systemd service
if [[ ! -f /etc/systemd/system/pxe-webui.service ]]; then
    info "Installing systemd service..."
    cp "$SCRIPT_DIR/pxe-webui.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable pxe-webui
    success "Service installed."
fi

# Open firewall for port 9000
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=9000/tcp &>/dev/null || true
    firewall-cmd --reload &>/dev/null || true
    success "Firewall: port 9000/tcp opened."
elif command -v ufw &>/dev/null; then
    ufw allow 9000/tcp &>/dev/null || true
fi

# Start (or restart) service
info "Starting PXE Web UI..."
systemctl restart pxe-webui
sleep 2

if systemctl is-active --quiet pxe-webui; then
    SERVER_IP=$(ip -4 addr show | awk '/inet /{print $2}' | grep -v 127 | head -1 | cut -d/ -f1)
    success "PXE Web UI is running!"
    echo ""
    echo -e "  ${GREEN}Open in browser:${NC}  http://${SERVER_IP}:9000"
    echo ""
else
    echo ""
    echo -e "${RED}Service failed to start. Check logs:${NC}"
    echo "  journalctl -u pxe-webui -n 30"
    exit 1
fi
