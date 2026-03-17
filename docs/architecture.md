# PXE Server Architecture

## Network Flow (Step by Step)

```
┌─────────────────────────────────────────────────────────────────┐
│                         LAN (e.g. 192.168.1.0/24)              │
│                                                                  │
│  ┌──────────────┐        ┌─────────────────────────────────┐   │
│  │  Client PC   │        │       PXE Server (this box)     │   │
│  │              │        │  IP: 192.168.1.10               │   │
│  │  BIOS/UEFI   │        │                                 │   │
│  │  "Boot PXE"  │        │  ┌──────────┐  ┌────────────┐  │   │
│  └──────┬───────┘        │  │ dnsmasq  │  │   nginx    │  │   │
│         │                │  │ DHCP+TFTP│  │ HTTP :80   │  │   │
│         │ 1. DHCP req    │  └────┬─────┘  └─────┬──────┘  │   │
│         │───────────────►│       │               │         │   │
│         │◄──────────────-│  IP + boot file       │         │   │
│         │                │       │               │         │   │
│         │ 2. TFTP get    │       │               │         │   │
│         │  pxelinux.0    │       │               │         │   │
│         │───────────────►│  /var/lib/tftpboot/   │         │   │
│         │◄── bootloader ─│       │               │         │   │
│         │                │       │               │         │   │
│         │ 3. TFTP get    │       │               │         │   │
│         │  boot menu     │       │               │         │   │
│         │───────────────►│  pxelinux.cfg/default │         │   │
│         │◄── OS menu ────│       │               │         │   │
│         │                │       │               │         │   │
│         │ 4. User picks  │       │               │         │   │
│         │  "Rocky 9"     │       │               │         │   │
│         │                │       │               │         │   │
│         │ 5. TFTP get    │       │               │         │   │
│         │  vmlinuz+initrd│       │               │         │   │
│         │───────────────►│  images/rocky9/       │         │   │
│         │◄── kernel ─────│       │               │         │   │
│         │                │       │               │         │   │
│         │ 6. Kernel boot │       │               │         │   │
│         │  fetches repo  │       │               │         │   │
│         │  + kickstart   │       │               │         │   │
│         │───────────────────────────────────────►│         │   │
│         │◄── packages + ks.cfg ──────────────────│         │   │
│         │                │       │               │         │   │
│         │ 7. OS installs │       │               │         │   │
│         │    (automated) │       │               │         │   │
│  └──────────────┘        └─────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Component Responsibilities

### dnsmasq
- Acts as both **DHCP server** and **TFTP server** in a single daemon
- DHCP: assigns IPs to booting clients, sends `next-server` (TFTP IP) and `filename` (pxelinux.0) options
- TFTP: serves all files under `/var/lib/tftpboot/` to clients

### syslinux / pxelinux
- `pxelinux.0` — the actual PXE bootloader binary loaded by the client NIC firmware
- `menu.c32` — renders the graphical text boot menu
- `ldlinux.c32`, `libcom32.c32`, `libutil.c32` — syslinux runtime libraries
- `pxelinux.cfg/default` — boot menu entries (labels, kernels, append lines)

### nginx
- Serves the installer repo (packages) and kickstart/preseed files over HTTP
- Clients reference it via `inst.repo=http://SERVER_IP/pxe/rocky9` in the kernel append line

### Kickstart / Preseed
- Text files that answer every installer question automatically
- Rocky Linux uses **kickstart** (`.ks.cfg`)
- Ubuntu/Debian uses **preseed** (`.cfg`)
- Loaded at install time via `inst.ks=http://...` or `url=http://...`

## Directory Layout (on the server)

```
/var/lib/tftpboot/              ← TFTP root
├── pxelinux.0                  ← PXE bootloader
├── menu.c32                    ← Menu renderer
├── ldlinux.c32                 ← Syslinux lib
├── libcom32.c32                ← Syslinux lib
├── libutil.c32                 ← Syslinux lib
├── reboot.c32                  ← Reboot module
├── pxelinux.cfg/
│   ├── default                 ← Boot menu (all clients)
│   └── 01-aa-bb-cc-dd-ee-ff   ← Per-MAC boot config (optional)
└── images/
    ├── rocky9/
    │   ├── vmlinuz             ← Rocky 9 kernel
    │   └── initrd.img          ← Rocky 9 initrd
    ├── ubuntu2404/
    │   ├── vmlinuz             ← Ubuntu 24.04 kernel
    │   └── initrd.gz           ← Ubuntu 24.04 initrd
    └── memtest/
        └── memtest86+.bin      ← RAM test

/var/www/pxe/                   ← HTTP root (nginx)
├── rocky9/                     ← Rocky 9 installer repo (rsync mirror)
├── ubuntu2404/                 ← Ubuntu installer repo (optional)
└── ks/
    ├── rocky9-ks.cfg           ← Rocky kickstart
    └── ubuntu2404-preseed.cfg  ← Ubuntu preseed
```

## BIOS vs UEFI

| Feature | BIOS (Legacy) | UEFI |
|---------|--------------|------|
| Bootloader | `pxelinux.0` | `grubx64.efi` or `shimx64.efi` |
| Boot menu | `pxelinux.cfg/default` | `grub.cfg` |
| dnsmasq tag | (default) | `set:efi-x86_64` |
| DHCP arch option | 0 | 7 (x86_64 UEFI) |

## Security Notes

- dnsmasq runs a DHCP server — only deploy on a trusted LAN segment
- Store kickstart password hashes, never plaintext passwords
- Restrict nginx to serve only from `/var/www/pxe/` (no directory traversal)
- Consider using HTTPS for kickstart files if the LAN is not fully trusted
- The PXE boot process has no authentication — anyone on the LAN can PXE boot
