#!/usr/bin/env python3
"""
PXE Web UI — Upload OS images, manage boot menu entries.
"""

import os
import re
import json
import hashlib
import shutil
import subprocess
import threading
from functools import wraps
from pathlib import Path
from flask import (
    Flask, render_template, request, jsonify,
    Response, redirect, url_for, session, flash
)
import werkzeug

# ── Config ────────────────────────────────────────────────────────────────────
TFTP_ROOT   = Path("/var/lib/tftpboot")
HTTP_ROOT   = Path("/var/www/pxe")
IMAGES_DIR  = TFTP_ROOT / "images"
PXECFG      = TFTP_ROOT / "pxelinux.cfg" / "default"
UPLOAD_DIR  = Path(__file__).parent / "uploads"
SERVER_IP   = "192.168.50.225"
MAX_CONTENT = 10 * 1024 * 1024 * 1024   # 10 GB

# ── Auth Config ───────────────────────────────────────────────────────────────
# Credentials stored as SHA-256 hashes.
# To change password, replace the hash below with:
#   python3 -c "import hashlib; print(hashlib.sha256(b'yourpassword').hexdigest())"
ADMIN_USERNAME = "admin"
ADMIN_PASSWORD_HASH = hashlib.sha256(b"pxeadmin").hexdigest()  # default: pxeadmin
SECRET_KEY = os.environ.get("PXE_SECRET_KEY", os.urandom(24).hex())

UPLOAD_DIR.mkdir(parents=True, exist_ok=True)

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = MAX_CONTENT
app.config["SECRET_KEY"] = SECRET_KEY
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"

# Progress tracking: {task_id: {"percent": 0, "status": "...", "log": []}}
_progress: dict = {}
_progress_lock = threading.Lock()


# ── Auth Helpers ─────────────────────────────────────────────────────────────
def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("logged_in"):
            if request.path.startswith("/api/"):
                return jsonify({"error": "Unauthorized"}), 401
            return redirect(url_for("login", next=request.path))
        return f(*args, **kwargs)
    return decorated


# ── Auth Routes ───────────────────────────────────────────────────────────────
@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    if request.method == "POST":
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")
        pw_hash  = hashlib.sha256(password.encode()).hexdigest()
        if username == ADMIN_USERNAME and pw_hash == ADMIN_PASSWORD_HASH:
            session["logged_in"] = True
            session["username"]  = username
            next_url = request.form.get("next") or url_for("index")
            return redirect(next_url)
        error = "Invalid username or password."
    return render_template("login.html", error=error, next=request.args.get("next", ""))


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ── Helpers ───────────────────────────────────────────────────────────────────
def log_progress(task_id: str, msg: str, percent: int = None):
    with _progress_lock:
        entry = _progress.setdefault(task_id, {"percent": 0, "status": "running", "log": []})
        entry["log"].append(msg)
        if percent is not None:
            entry["percent"] = percent


def finish_progress(task_id: str, success: bool, msg: str):
    with _progress_lock:
        entry = _progress.setdefault(task_id, {"percent": 0, "status": "", "log": []})
        entry["percent"] = 100 if success else entry.get("percent", 0)
        entry["status"] = "done" if success else "error"
        entry["log"].append(msg)


def get_installed_oses() -> list:
    oses = []
    if IMAGES_DIR.exists():
        for d in sorted(IMAGES_DIR.iterdir()):
            if not d.is_dir():
                continue
            vmlinuz = any((d / f).exists() for f in ("vmlinuz", "linux"))
            initrd  = any((d / f).exists() for f in ("initrd.img", "initrd.gz", "initrd"))
            oses.append({
                "name": d.name,
                "vmlinuz": vmlinuz,
                "initrd":  initrd,
                "ready":   vmlinuz and initrd,
                "size_mb": sum(
                    f.stat().st_size for f in d.rglob("*") if f.is_file()
                ) // (1024 * 1024),
            })
    return oses


def read_boot_menu() -> str:
    if PXECFG.exists():
        return PXECFG.read_text()
    return ""


def write_boot_menu(content: str):
    PXECFG.parent.mkdir(parents=True, exist_ok=True)
    PXECFG.write_text(content)


def add_menu_entry(slug: str, label: str, os_type: str):
    """Append a new LABEL block to pxelinux.cfg/default."""
    menu = read_boot_menu()

    kernel_path  = f"images/{slug}/vmlinuz"
    initrd_file  = "initrd.img" if os_type == "rocky" else "initrd.gz"
    initrd_path  = f"images/{slug}/{initrd_file}"

    if os_type == "rocky":
        append = (
            f"initrd={initrd_path} "
            f"inst.repo=http://{SERVER_IP}/pxe/{slug} "
            f"inst.ks=http://{SERVER_IP}/ks/{slug}-ks.cfg quiet"
        )
    else:
        append = (
            f"initrd={initrd_path} "
            f"url=http://{SERVER_IP}/ks/{slug}-preseed.cfg "
            f"auto=true priority=critical quiet splash"
        )

    block = (
        f"\n# ---------------------------------------------------------------------------\n"
        f"LABEL {slug}\n"
        f"    MENU LABEL {label}\n"
        f"    KERNEL {kernel_path}\n"
        f"    APPEND {append}\n"
    )

    if f"LABEL {slug}" not in menu:
        write_boot_menu(menu + block)


def remove_menu_entry(slug: str):
    menu = read_boot_menu()
    # Remove the block starting with LABEL <slug> up to the next LABEL or EOF
    pattern = re.compile(
        r"\n?# -+\n?LABEL " + re.escape(slug) + r".*?(?=\n# -|\nLABEL |\Z)",
        re.DOTALL,
    )
    new_menu = pattern.sub("", menu)
    write_boot_menu(new_menu)


def extract_iso_background(task_id: str, iso_path: Path, slug: str, label: str, os_type: str):
    """Mount ISO, copy vmlinuz+initrd to tftpboot, mirror repo via HTTP root."""
    mnt = Path(f"/mnt/pxe_iso_{slug}")
    dest_tftp = IMAGES_DIR / slug
    dest_http = HTTP_ROOT / slug

    try:
        log_progress(task_id, f"Creating directories for {slug}...", 5)
        dest_tftp.mkdir(parents=True, exist_ok=True)
        dest_http.mkdir(parents=True, exist_ok=True)
        mnt.mkdir(parents=True, exist_ok=True)

        log_progress(task_id, f"Mounting ISO {iso_path.name}...", 10)
        subprocess.run(
            ["mount", "-o", "loop,ro", str(iso_path), str(mnt)],
            check=True, capture_output=True
        )

        # ── Locate vmlinuz and initrd inside the ISO ──────────────────────────
        log_progress(task_id, "Locating kernel and initrd in ISO...", 20)
        vmlinuz_candidates = list(mnt.rglob("vmlinuz")) + list(mnt.rglob("linux"))
        initrd_candidates  = (
            list(mnt.rglob("initrd.img")) +
            list(mnt.rglob("initrd.gz")) +
            list(mnt.rglob("initrd"))
        )

        # Prefer files inside pxeboot/ or install/ subdirectories
        def prefer(candidates):
            for p in candidates:
                if any(k in str(p) for k in ("pxeboot", "install", "images/pxeboot")):
                    return p
            return candidates[0] if candidates else None

        vmlinuz_src = prefer(vmlinuz_candidates)
        initrd_src  = prefer(initrd_candidates)

        if not vmlinuz_src or not initrd_src:
            raise FileNotFoundError("Could not find vmlinuz or initrd inside ISO")

        log_progress(task_id, f"Copying {vmlinuz_src.name} → tftpboot...", 40)
        shutil.copy2(vmlinuz_src, dest_tftp / "vmlinuz")

        log_progress(task_id, f"Copying {initrd_src.name} → tftpboot...", 55)
        initrd_ext = ".img" if os_type == "rocky" else ".gz"
        shutil.copy2(initrd_src, dest_tftp / f"initrd{initrd_ext}")

        # ── Copy ISO content to HTTP repo root ────────────────────────────────
        log_progress(task_id, "Copying ISO contents to HTTP repo root (this may take a while)...", 60)
        subprocess.run(
            ["rsync", "-a", "--info=progress2", str(mnt) + "/", str(dest_http) + "/"],
            check=True, capture_output=True
        )

        log_progress(task_id, "Unmounting ISO...", 90)
        subprocess.run(["umount", str(mnt)], check=True, capture_output=True)
        mnt.rmdir()

        # ── Update PXE boot menu ──────────────────────────────────────────────
        log_progress(task_id, "Adding boot menu entry...", 95)
        add_menu_entry(slug, label, os_type)

        # ── Fix permissions ───────────────────────────────────────────────────
        subprocess.run(["chmod", "-R", "755", str(dest_tftp)], capture_output=True)
        subprocess.run(["chmod", "-R", "755", str(dest_http)], capture_output=True)

        log_progress(task_id, f"✔ {label} is ready for PXE booting!", 100)
        finish_progress(task_id, True, "Installation complete.")

    except Exception as exc:
        try:
            subprocess.run(["umount", str(mnt)], capture_output=True)
        except Exception:
            pass
        finish_progress(task_id, False, f"Error: {exc}")

    finally:
        # Clean up uploaded ISO to save disk space
        try:
            iso_path.unlink(missing_ok=True)
        except Exception:
            pass


# ── Routes ────────────────────────────────────────────────────────────────────

@app.route("/")
@login_required
def index():
    return render_template("index.html", oses=get_installed_oses(), server_ip=SERVER_IP)


@app.route("/api/oses")
@login_required
def api_oses():
    return jsonify(get_installed_oses())


@app.route("/api/upload", methods=["POST"])
@login_required
def api_upload():
    label   = request.form.get("label", "").strip()
    os_type = request.form.get("os_type", "rocky")  # rocky | ubuntu
    file    = request.files.get("iso_file")

    if not label:
        return jsonify({"error": "OS label is required"}), 400
    if not file or not file.filename:
        return jsonify({"error": "No file selected"}), 400

    filename = werkzeug.utils.secure_filename(file.filename)
    if not filename.lower().endswith(".iso"):
        return jsonify({"error": "Only .iso files are supported"}), 400

    slug = re.sub(r"[^a-z0-9_-]", "", label.lower().replace(" ", "-"))[:32]
    iso_path = UPLOAD_DIR / filename

    file.save(str(iso_path))

    task_id = f"{slug}_{os.urandom(4).hex()}"
    with _progress_lock:
        _progress[task_id] = {"percent": 0, "status": "running", "log": [f"Upload saved: {filename}"]}

    thread = threading.Thread(
        target=extract_iso_background,
        args=(task_id, iso_path, slug, label, os_type),
        daemon=True,
    )
    thread.start()

    return jsonify({"task_id": task_id, "slug": slug})


@app.route("/api/progress/<task_id>")
@login_required
def api_progress(task_id: str):
    with _progress_lock:
        data = _progress.get(task_id, {"percent": 0, "status": "unknown", "log": []})
    return jsonify(data)


@app.route("/api/delete/<slug>", methods=["DELETE"])
@login_required
def api_delete(slug: str):
    slug = re.sub(r"[^a-z0-9_-]", "", slug)
    errors = []

    tftp_dir = IMAGES_DIR / slug
    http_dir = HTTP_ROOT / slug

    if tftp_dir.exists():
        shutil.rmtree(tftp_dir)
    else:
        errors.append(f"TFTP dir not found: {tftp_dir}")

    if http_dir.exists():
        shutil.rmtree(http_dir)
    else:
        errors.append(f"HTTP dir not found: {http_dir}")

    remove_menu_entry(slug)

    if errors:
        return jsonify({"warning": errors}), 200
    return jsonify({"deleted": slug})


@app.route("/api/menu")
@login_required
def api_menu():
    return jsonify({"content": read_boot_menu()})


@app.route("/api/menu", methods=["POST"])
@login_required
def api_menu_save():
    body = request.get_json(force=True)
    content = body.get("content", "")
    write_boot_menu(content)
    return jsonify({"saved": True})


@app.route("/api/status")
@login_required
def api_status():
    services = {}
    for svc in ("dnsmasq", "nginx"):
        result = subprocess.run(
            ["systemctl", "is-active", svc],
            capture_output=True, text=True
        )
        services[svc] = result.stdout.strip()

    return jsonify({
        "server_ip": SERVER_IP,
        "services": services,
        "oses": get_installed_oses(),
    })


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=9000, debug=False)
