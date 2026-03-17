/* PXE Boot Manager — frontend */

// ── Tab navigation ──────────────────────────────────────────────────────────
const TAB_TITLES = {
  dashboard: 'Dashboard',
  upload:    'Upload OS',
  images:    'OS Images',
  menu:      'Boot Menu',
};

function switchTab(name) {
  document.querySelectorAll('.tab-panel').forEach(p => p.classList.remove('active'));
  document.querySelectorAll('.nav-item').forEach(a => a.classList.remove('active'));
  document.getElementById(`tab-${name}`).classList.add('active');
  document.querySelector(`.nav-item[data-tab="${name}"]`).classList.add('active');
  document.getElementById('tabTitle').textContent = TAB_TITLES[name] || name;

  if (name === 'images')    loadImages();
  if (name === 'menu')      loadMenu();
  if (name === 'dashboard') loadDashboard();
}

document.querySelectorAll('.nav-item').forEach(a => {
  a.addEventListener('click', e => {
    e.preventDefault();
    switchTab(a.dataset.tab);
  });
});

// ── Toast ────────────────────────────────────────────────────────────────────
function toast(msg, type = 'info') {
  const el = document.createElement('div');
  el.className = `toast ${type}`;
  el.innerHTML = `<div class="toast-dot"></div><span>${msg}</span>`;
  document.getElementById('toastContainer').appendChild(el);
  setTimeout(() => el.remove(), 4000);
}

// ── Confirm Modal ─────────────────────────────────────────────────────────────
let _confirmCallback = null;
function confirm(msg, cb) {
  document.getElementById('confirmBody').textContent = msg;
  document.getElementById('confirmModal').style.display = 'flex';
  _confirmCallback = cb;
}
function closeModal() {
  document.getElementById('confirmModal').style.display = 'none';
  _confirmCallback = null;
}
document.getElementById('confirmBtn').addEventListener('click', () => {
  if (_confirmCallback) _confirmCallback();
  closeModal();
});

// ── API helpers ───────────────────────────────────────────────────────────────
async function apiFetch(url, opts = {}) {
  const r = await fetch(url, opts);
  if (!r.ok) {
    const body = await r.json().catch(() => ({}));
    throw new Error(body.error || `HTTP ${r.status}`);
  }
  return r.json();
}

// ── Dashboard ─────────────────────────────────────────────────────────────────
async function loadDashboard() {
  try {
    const data = await apiFetch('/api/status');

    // Stats
    const ready = data.oses.filter(o => o.ready).length;
    document.getElementById('statOSCount').textContent = ready;

    const dm = data.services.dnsmasq === 'active';
    const ng = data.services.nginx   === 'active';
    document.getElementById('statDnsmasq').textContent = dm ? 'Active' : 'Stopped';
    document.getElementById('statDnsmasq').style.color = dm ? 'var(--green)' : 'var(--red)';
    document.getElementById('statNginx').textContent   = ng ? 'Active' : 'Stopped';
    document.getElementById('statNginx').style.color   = ng ? 'var(--green)' : 'var(--red)';

    const totalMB = data.oses.reduce((s, o) => s + o.size_mb, 0);
    document.getElementById('statTotalSize').textContent = totalMB.toLocaleString();

    // Service pills
    const pills = document.getElementById('servicePills');
    pills.innerHTML = [
      ['dnsmasq', data.services.dnsmasq],
      ['nginx',   data.services.nginx],
    ].map(([n, s]) =>
      `<span class="pill ${s === 'active' ? 'active' : 'inactive'}">${n}</span>`
    ).join('');

    // OS cards
    const grid = document.getElementById('dashOsGrid');
    if (!data.oses.length) {
      grid.innerHTML = '<div class="empty-state">No OS images installed yet. Go to Upload OS to add one.</div>';
      return;
    }
    grid.innerHTML = data.oses.map(o => `
      <div class="os-card">
        <div class="os-card-name">${o.name}</div>
        <div class="os-card-meta">${o.size_mb} MB</div>
        <div class="os-card-badges">
          <span class="badge ${o.vmlinuz ? 'badge-green' : 'badge-red'}">vmlinuz</span>
          <span class="badge ${o.initrd  ? 'badge-green' : 'badge-red'}">initrd</span>
          <span class="badge ${o.ready   ? 'badge-blue'  : 'badge-red'}">${o.ready ? 'Ready' : 'Incomplete'}</span>
        </div>
      </div>
    `).join('');
  } catch (e) {
    toast('Dashboard load failed: ' + e.message, 'error');
  }
}

// ── Images Table ──────────────────────────────────────────────────────────────
async function loadImages() {
  const tbody = document.getElementById('imagesTableBody');
  tbody.innerHTML = '<tr><td colspan="6" class="empty-state">Loading...</td></tr>';
  try {
    const oses = await apiFetch('/api/oses');
    if (!oses.length) {
      tbody.innerHTML = '<tr><td colspan="6" class="empty-state">No OS images installed yet.</td></tr>';
      return;
    }
    tbody.innerHTML = oses.map(o => `
      <tr>
        <td style="font-weight:600">${o.name}</td>
        <td><span class="badge ${o.vmlinuz ? 'badge-green' : 'badge-red'}">${o.vmlinuz ? '✔' : '✘'}</span></td>
        <td><span class="badge ${o.initrd  ? 'badge-green' : 'badge-red'}">${o.initrd  ? '✔' : '✘'}</span></td>
        <td>${o.size_mb}</td>
        <td><span class="badge ${o.ready ? 'badge-blue' : 'badge-red'}">${o.ready ? 'Ready' : 'Incomplete'}</span></td>
        <td>
          <button class="btn btn-danger btn-sm" onclick="deleteOS('${o.name}')">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14H6L5 6"/><path d="M10 11v6M14 11v6"/><path d="M9 6V4h6v2"/></svg>
            Delete
          </button>
        </td>
      </tr>
    `).join('');
  } catch (e) {
    toast('Failed to load images: ' + e.message, 'error');
  }
}

function deleteOS(slug) {
  confirm(
    `Delete "${slug}"? This will remove all TFTP/HTTP files and the boot menu entry.`,
    async () => {
      try {
        await apiFetch(`/api/delete/${slug}`, { method: 'DELETE' });
        toast(`"${slug}" deleted.`, 'success');
        loadImages();
        loadDashboard();
      } catch (e) {
        toast('Delete failed: ' + e.message, 'error');
      }
    }
  );
}

// ── Boot Menu ─────────────────────────────────────────────────────────────────
async function loadMenu() {
  try {
    const { content } = await apiFetch('/api/menu');
    document.getElementById('menuEditor').value = content;
    document.getElementById('saveStatus').textContent = '';
  } catch (e) {
    toast('Failed to load menu: ' + e.message, 'error');
  }
}

async function saveMenu() {
  const content = document.getElementById('menuEditor').value;
  try {
    await apiFetch('/api/menu', {
      method: 'POST',
      body: JSON.stringify({ content }),
      headers: { 'Content-Type': 'application/json' },
    });
    document.getElementById('saveStatus').textContent = '✔ Saved successfully';
    toast('Boot menu saved.', 'success');
  } catch (e) {
    toast('Save failed: ' + e.message, 'error');
  }
}

// ── Upload ────────────────────────────────────────────────────────────────────
const dropZone  = document.getElementById('dropZone');
const isoInput  = document.getElementById('isoFile');
const dropName  = document.getElementById('dropFilename');

dropZone.addEventListener('click', () => isoInput.click());
isoInput.addEventListener('change', () => {
  const f = isoInput.files[0];
  dropName.textContent = f ? `📀 ${f.name} (${(f.size / 1024 / 1024 / 1024).toFixed(2)} GB)` : '';
});

dropZone.addEventListener('dragover',  e => { e.preventDefault(); dropZone.classList.add('drag-over'); });
dropZone.addEventListener('dragleave', ()  => dropZone.classList.remove('drag-over'));
dropZone.addEventListener('drop', e => {
  e.preventDefault();
  dropZone.classList.remove('drag-over');
  const f = e.dataTransfer.files[0];
  if (f) {
    const dt = new DataTransfer();
    dt.items.add(f);
    isoInput.files = dt.files;
    dropName.textContent = `📀 ${f.name} (${(f.size / 1024 / 1024 / 1024).toFixed(2)} GB)`;
  }
});

document.getElementById('uploadForm').addEventListener('submit', async e => {
  e.preventDefault();

  const label  = document.getElementById('osLabel').value.trim();
  const file   = isoInput.files[0];

  if (!label) { toast('Enter an OS name.', 'error'); return; }
  if (!file)  { toast('Select an ISO file.', 'error'); return; }

  const btn = document.getElementById('uploadBtn');
  btn.disabled = true;
  btn.textContent = 'Uploading...';

  const section = document.getElementById('progressSection');
  section.style.display = 'block';
  document.getElementById('progressFill').style.width = '0%';
  document.getElementById('progressPct').textContent = '0%';
  document.getElementById('progressLabel').textContent = 'Uploading ISO...';
  document.getElementById('progressLog').innerHTML = '';

  const fd = new FormData(document.getElementById('uploadForm'));

  try {
    const { task_id } = await apiFetch('/api/upload', { method: 'POST', body: fd });
    btn.textContent = 'Processing...';
    pollProgress(task_id);
  } catch (err) {
    toast('Upload failed: ' + err.message, 'error');
    btn.disabled = false;
    btn.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg> Upload &amp; Install`;
  }
});

function pollProgress(taskId) {
  const fill  = document.getElementById('progressFill');
  const pct   = document.getElementById('progressPct');
  const label = document.getElementById('progressLabel');
  const log   = document.getElementById('progressLog');
  const btn   = document.getElementById('uploadBtn');

  let lastLogLen = 0;

  const iv = setInterval(async () => {
    try {
      const data = await apiFetch(`/api/progress/${taskId}`);

      fill.style.width = data.percent + '%';
      pct.textContent  = data.percent + '%';

      // Append new log lines
      const newLines = data.log.slice(lastLogLen);
      lastLogLen = data.log.length;
      newLines.forEach(line => {
        const d = document.createElement('div');
        d.className = 'log-line' +
          (line.startsWith('✔') || line.includes('complete') ? ' success' : '') +
          (line.toLowerCase().includes('error') ? ' error' : '');
        d.textContent = line;
        log.appendChild(d);
        log.scrollTop = log.scrollHeight;
      });

      if (data.status === 'done') {
        clearInterval(iv);
        label.textContent = '✔ Installation complete!';
        toast('OS installed and ready for PXE booting!', 'success');
        btn.disabled = false;
        btn.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg> Upload &amp; Install`;
        loadDashboard();
      } else if (data.status === 'error') {
        clearInterval(iv);
        label.textContent = '✘ Installation failed.';
        toast('Installation failed. Check log for details.', 'error');
        btn.disabled = false;
        btn.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></svg> Upload &amp; Install`;
      }
    } catch (e) {
      clearInterval(iv);
    }
  }, 1500);
}

// ── Refresh all ───────────────────────────────────────────────────────────────
function refreshAll() {
  const active = document.querySelector('.nav-item.active');
  if (active) switchTab(active.dataset.tab);
  toast('Refreshed.', 'info');
}

// ── Init ──────────────────────────────────────────────────────────────────────
loadDashboard();
