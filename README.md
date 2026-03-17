# PXE Network Boot Server

Boot any computer on your LAN into a Linux installer over Ethernet — no USB needed.

**Server IP:** `192.168.50.225` | **Web UI:** `http://192.168.50.225:9000`

## How It Works

```
Client Machine                   PXE Server (192.168.50.225)
──────────────                   ───────────────────────────
BIOS/UEFI: "Boot from network"
        │
        ▼ DHCP Request (UDP 67)
        ──────────────────────► dnsmasq
                                   │  "Your IP is 192.168.50.x"
                                   │  "TFTP server is 192.168.50.225"
                                   │  "Boot file: pxelinux.0"
        ◄──────────────────────────┘
        │
        ▼ TFTP fetch pxelinux.0 + boot menu (UDP 69)
        ──────────────────────► /var/lib/tftpboot/
        │
        ▼ User selects OS from menu
        ──────────────────────► TFTP fetch vmlinuz + initrd
        ▼
        kernel boots, fetches installer stage2 via HTTP (port 80)
        ──────────────────────► nginx serves /var/www/pxe/
        ▼
        OS installs automatically from kickstart/preseed file
```

## Stack

| Component | Role |
|-----------|------|
| **dnsmasq** | DHCP server + TFTP server (single process) |
| **nginx** | HTTP server — serves ISO repos, kickstart files |
| **syslinux/pxelinux** | PXE bootloader loaded by client over TFTP |
| **kickstart / preseed** | Fully automated OS installation answers |
| **Flask Web UI** | Browser-based manager at port 9000 — upload ISOs, manage boot menu |

## Supported OS Installs

| OS | Kickstart | Min RAM |
|----|-----------|---------|
| Rocky Linux 10 Minimal (x86_64) | `http/ks/rocky-10-minimum-ks.cfg` | **4 GB** |
| Rocky Linux 9 (x86_64) | `http/ks/rocky9-ks.cfg` | 2 GB |
| Ubuntu 24.04 LTS (x86_64) | `http/ks/ubuntu2404-preseed.cfg` | 2 GB |
| Memtest86+ | — | — |

> ⚠️ **Rocky Linux 10** embeds the entire anaconda installer (~600 MB decompressed) in the
> initrd. The target VM needs **at least 4 GB RAM** or the installer will silently crash and
> reboot in a loop.

---

## Quick Start

### 1. Prerequisites

- Rocky Linux server connected to the same LAN as the machines you want to boot
- Root/sudo access
- Ports **67/udp** (DHCP), **69/udp** (TFTP), **80/tcp** (HTTP), **9000/tcp** (Web UI)

> ⚠️ If your network already has a DHCP server (e.g. your router), disable it or configure
> proxy DHCP (options 43/66/67).

### 2. Edit Configuration

Open `setup.sh` and set the variables at the top:

```bash
LAN_INTERFACE="ens160"           # Your LAN network interface
SERVER_IP="192.168.50.225"       # This server's static IP
DHCP_RANGE_START="192.168.50.100"
DHCP_RANGE_END="192.168.50.200"
GATEWAY="192.168.50.1"
```

### 3. Run Setup

```bash
sudo bash setup.sh
```

Installs dnsmasq + nginx + syslinux, configures everything, starts services, and fixes SELinux contexts.

### 4. Download OS Kernels

```bash
sudo bash fetch-kernels.sh
```

Downloads `vmlinuz` + `initrd` for Rocky 9 and Ubuntu 24.04 into `/var/lib/tftpboot/images/`.

### 5. Start the Web UI

The Web UI is installed at `/opt/pxe-webui` and runs as a systemd service:

```bash
sudo systemctl start pxe-webui
sudo systemctl enable pxe-webui
```

Open `http://<SERVER_IP>:9000` in your browser.

**Default login:** `admin` / `pxeadmin`

### 6. Upload an OS ISO via Web UI

1. Log in to the Web UI
2. Go to **Upload** tab
3. Select a Rocky Linux or Ubuntu ISO file
4. The UI will extract the ISO, copy the kernel/initrd to TFTP, and add a boot menu entry automatically

### 7. Boot a Client

1. On the target machine: BIOS/UEFI → set **Network/PXE** as first boot device
2. Boot — machine gets an IP, shows the PXE menu (auto-selects Rocky 10 after 60s)
3. Installation runs fully automated via kickstart
4. VM **powers off** when done — change boot order to Hard Disk, then power on

### 8. Check Status

```bash
sudo bash pxe-status.sh

# Watch live PXE/DHCP/TFTP activity
sudo tail -f /var/log/dnsmasq-pxe.log

# Watch HTTP requests from installing clients
sudo tail -f /var/log/nginx/access.log
```

---

## Project Structure

```
PXE-server/
├── setup.sh                        # Main installer script
├── fetch-kernels.sh                # Downloads OS netboot kernels
├── pxe-status.sh                   # Health check / diagnostics
├── config/
│   └── dnsmasq.conf                # Reference dnsmasq config
├── tftpboot/
│   └── pxelinux.cfg/
│       └── default                 # PXE boot menu
├── http/
│   └── ks/
│       ├── rocky9-ks.cfg           # Rocky 9 kickstart
│       ├── rocky-10-minimum-ks.cfg # Rocky 10 kickstart
│       └── ubuntu2404-preseed.cfg  # Ubuntu 24.04 preseed
├── web-ui/                         # Flask Web UI source
│   ├── app.py                      # Flask application (auth + API)
│   ├── requirements.txt
│   ├── pxe-webui.service           # systemd unit file
│   ├── templates/
│   │   ├── index.html              # Main dashboard
│   │   └── login.html              # Login page
│   └── static/
│       ├── css/style.css
│       └── js/app.js
└── docs/
    └── architecture.md
```

**Live deployment paths:**

| Source | Deployed to |
|--------|-------------|
| `web-ui/` | `/opt/pxe-webui/` |
| Python venv | `/opt/pxe-webui-venv/` |
| Boot kernels | `/var/lib/tftpboot/images/` |
| ISO repos | `/var/www/pxe/<os-name>/` |
| Kickstart files | `/var/www/pxe/ks/` |

---

## Web UI

The Flask Web UI at `http://192.168.50.225:9000` provides:

- **Dashboard** — server status, installed OSes, service health
- **Upload** — drag-and-drop ISO upload with live progress bar
- **Boot Menu** — view and edit `pxelinux.cfg/default` in the browser
- **Delete** — remove an OS and all associated files

**Authentication:** session-based login. Passwords stored as SHA-256 hashes.

To change the Web UI password:
```bash
python3 -c "import hashlib; print(hashlib.sha256(b'yournewpassword').hexdigest())"
# Paste the output into ADMIN_PASSWORD_HASH in /opt/pxe-webui/app.py
sudo systemctl restart pxe-webui
```

---

## SELinux Notes (Rocky Linux)

SELinux is enforcing on this server. All PXE content directories must have the correct contexts:

```bash
# HTTP content (nginx)
sudo semanage fcontext -a -t httpd_sys_content_t "/var/www/pxe(/.*)?"
sudo restorecon -Rv /var/www/pxe

# TFTP content (dnsmasq)
sudo semanage fcontext -a -t tftpdir_t "/var/lib/tftpboot(/.*)?"
sudo restorecon -Rv /var/lib/tftpboot
```

The Web UI runs from `/opt/pxe-webui` to avoid SELinux `user_home_t` restrictions on home directories.

---

## UEFI Support

```bash
sudo dnf install -y grub2-efi-x64 shim-x64
cp /boot/efi/EFI/rocky/grubx64.efi /var/lib/tftpboot/
cp /boot/efi/EFI/rocky/shimx64.efi /var/lib/tftpboot/
```

In `dnsmasq.conf`:
```
dhcp-match=set:efi-x86_64,option:client-arch,7
dhcp-boot=tag:efi-x86_64,grubx64.efi
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Client gets no IP | Check `LAN_INTERFACE` in setup.sh; check for conflicting DHCP server |
| PXE ROM timeout | Ensure ports 67/udp and 69/udp are open in firewall |
| `pxelinux.0` not found | Re-run setup.sh; check syslinux is installed |
| Files return 404 | SELinux context wrong — run `restorecon -Rv /var/www/pxe` |
| Installer loops / reboots | Not enough RAM — Rocky 10 needs **4 GB minimum** |
| Kickstart never fetched | Missing `inst.stage2=` or `inst.waitfornet=` in boot append line |
| Web UI won't start | Check `sudo journalctl -u pxe-webui -n 50`; verify `/opt/pxe-webui` exists |
| Login fails on Web UI | Default: `admin` / `pxeadmin` |

```bash
# Restart all services
sudo systemctl restart dnsmasq nginx pxe-webui

# Check logs
sudo journalctl -u dnsmasq -n 50
sudo journalctl -u nginx -n 50
sudo journalctl -u pxe-webui -n 50
sudo tail -f /var/log/dnsmasq-pxe.log
sudo tail -f /var/log/nginx/access.log
```
