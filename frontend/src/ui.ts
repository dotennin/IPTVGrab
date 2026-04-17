import { apiFetch } from './api';
import { esc, toast } from './utils';
import { settings, loadSettings, saveSettings } from './settings';
import { setHealthOnlyFilter } from './health';
import { Modal } from './bootstrap-shim';
import { renderRecentChannels } from './recents';
import { addTaskCard, updateTaskCard, startPolling, currentRequest as _cr } from './tasks';
import { currentStreamInfo as _csi, showStreamInfo, showError } from './player';
import { loadPlaylists } from './playlists';

// ── Section management ────────────────────────────────────────────────────────
const ALL_SECTIONS = ['mainPanels', 'favoritesSection', 'downloadsSection'];

function showSection(id: string): void {
  ALL_SECTIONS.forEach((s) => {
    const el = document.getElementById(s);
    if (el) el.classList.toggle('d-none', s !== id);
  });
}

// ── Bottom nav active state ───────────────────────────────────────────────────
function setNavActive(btnId: string): void {
  document.querySelectorAll('#tvBottomNav .tv-nav-btn').forEach((b) =>
    b.classList.remove('tv-nav-active'),
  );
  document.getElementById(btnId)?.classList.add('tv-nav-active');
}

function showPanel(panelId: string): void {
  document.getElementById(panelId)?.classList.remove('d-none');
}

function hidePanel(panelId: string): void {
  document.getElementById(panelId)?.classList.add('d-none');
}

export function showDownloadsTab(): void {
  showSection('downloadsSection');
  setNavActive('downloads-tab');
}

function showFavoritesTab(): void {
  showSection('favoritesSection');
  setNavActive('favorites-tab');
  renderRecentChannels();
}

function showPlaylistTab(): void {
  showSection('mainPanels');
  setNavActive('playlist-tab');
}

function openAddStreamModal(): void {
  const modalEl = document.getElementById('addStreamModal');
  if (!modalEl) return;
  showDownloadsTab();
  Modal.getOrCreateInstance(modalEl)?.show();
}

// ── Bottom nav listeners ──────────────────────────────────────────────────────
document.getElementById('favorites-tab')?.addEventListener('click', showFavoritesTab);
document.getElementById('playlist-tab')?.addEventListener('click', showPlaylistTab);
document.getElementById('downloads-tab')?.addEventListener('click', showDownloadsTab);
document.getElementById('openAddStreamBtn')?.addEventListener('click', openAddStreamModal);

// ── Header rows ───────────────────────────────────────────────────────────────
function addHeaderRow(key = '', val = ''): void {
  const list = document.getElementById('headersList');
  if (!list) return;
  const row = document.createElement('div');
  row.className = 'input-group input-group-sm mb-2 header-row';
  row.innerHTML = `
    <input type="text" class="form-control header-key font-mono" placeholder="Header name" value="${esc(key)}" />
    <input type="text" class="form-control header-val font-mono" placeholder="Value" value="${esc(val)}" />
    <button class="btn btn-outline-danger" type="button" tabindex="-1"
            onclick="this.closest('.header-row').remove()">
      <i class="fas fa-times"></i>
    </button>`;
  list.appendChild(row);
}

document.getElementById('addHeaderBtn')?.addEventListener('click', () => addHeaderRow());

function collectHeaders(): Record<string, string> {
  const h: Record<string, string> = {};
  document.querySelectorAll('.header-row').forEach((row) => {
    const k = (row.querySelector('.header-key') as HTMLInputElement).value.trim();
    const v = (row.querySelector('.header-val') as HTMLInputElement).value.trim();
    if (k) h[k] = v;
  });
  return h;
}

function populateHeaders(headers: Record<string, string>): void {
  const list = document.getElementById('headersList');
  if (list) list.innerHTML = '';
  Object.entries(headers).forEach(([k, v]) => addHeaderRow(k, v));
}

// ── Parse button ──────────────────────────────────────────────────────────────
document.getElementById('parseBtn')?.addEventListener('click', async () => {
  const btn       = document.getElementById('parseBtn') as HTMLButtonElement;
  const curlTab   = document.getElementById('curl-tab');
  const curlActive = curlTab?.classList.contains('active') ?? false;

  let url         = '';
  let headers: Record<string, string> = {};
  let curlCommand = '';

  if (curlActive) {
    curlCommand = (document.getElementById('curlInput') as HTMLTextAreaElement)?.value.trim() || '';
    if (!curlCommand) { toast('Please paste a cURL command', 'danger'); return; }
  } else {
    url = (document.getElementById('urlInput') as HTMLInputElement)?.value.trim() || '';
    if (!url) { toast('Please enter an M3U8 URL', 'danger'); return; }
    headers = collectHeaders();
  }

  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Parsing...';

  try {
    const res = await apiFetch('/api/parse', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ url, headers, curl_command: curlCommand }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Parse failed');

    _cr.url     = url || data.url || '';
    _cr.headers = data.headers || headers;

    const urlInput = document.getElementById('urlInput') as HTMLInputElement | null;
    if (urlInput) urlInput.value = data.url || '';
    if (data.headers) populateHeaders(data.headers);

    showStreamInfo(data);
    showPanel('streamInfoPanel');
    toast('Parsed successfully', 'success');
  } catch (e) {
    toast((e as Error).message, 'danger');
    showError((e as Error).message);
    showPanel('streamInfoPanel');
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-search me-1"></i>Parse stream';
  }
});

// ── Settings modal ────────────────────────────────────────────────────────────
(function initSettingsModal() {
  const settingsModalEl = document.getElementById('settingsModal');
  if (!settingsModalEl) return;
  const settingsModal = Modal.getOrCreateInstance(settingsModalEl)!;

  document.getElementById('settingsBtn')?.addEventListener('click', () => {
    const toggle = document.getElementById('settingUseProxy') as HTMLInputElement | null;
    if (toggle) toggle.checked = settings.useProxy;
    const toggleAutoFullscreen = document.getElementById('settingAutoFullscreen') as HTMLInputElement | null;
    if (toggleAutoFullscreen) toggleAutoFullscreen.checked = settings.autoFullscreen;
    const toggleHealth = document.getElementById('settingHealthOnly') as HTMLInputElement | null;
    if (toggleHealth) toggleHealth.checked = settings.healthOnlyFilter;
    const recentLimitInput = document.getElementById('settingRecentLimit') as HTMLInputElement | null;
    if (recentLimitInput) recentLimitInput.value = String(settings.recentLimit);
    const recordingIntervalInput = document.getElementById('settingRecordingIntervalMinutes') as HTMLInputElement | null;
    if (recordingIntervalInput) recordingIntervalInput.value = String(settings.recordingIntervalMinutes);
    const recordingAutoRestart = document.getElementById('settingRecordingAutoRestart') as HTMLInputElement | null;
    if (recordingAutoRestart) recordingAutoRestart.checked = settings.recordingAutoRestart;
    settingsModal.show();
  });

  document.getElementById('settingUseProxy')?.addEventListener('change', (e) => {
    const value = (e.target as HTMLInputElement).checked;
    void saveSettings({ useProxy: value });
  });

  document.getElementById('settingAutoFullscreen')?.addEventListener('change', (e) => {
    const value = (e.target as HTMLInputElement).checked;
    void saveSettings({ autoFullscreen: value });
  });

  document.getElementById('settingHealthOnly')?.addEventListener('change', (e) => {
    const value = (e.target as HTMLInputElement).checked;
    setHealthOnlyFilter(value);
    // Sync the quick-toggle in channels panel
    const qToggle = document.getElementById('healthOnlyCheck') as HTMLInputElement | null;
    if (qToggle) qToggle.checked = value;
    void saveSettings({ healthOnlyFilter: value });
  });

  document.getElementById('settingRecentLimit')?.addEventListener('change', (e) => {
    const input = e.target as HTMLInputElement;
    const parsed = Number.parseInt(input.value || '', 10);
    const value = Number.isFinite(parsed) ? Math.min(200, Math.max(1, parsed)) : settings.recentLimit;
    input.value = String(value);
    void saveSettings({ recentLimit: value }).then(() => {
      renderRecentChannels();
    });
  });

  document.getElementById('settingRecordingIntervalMinutes')?.addEventListener('change', (e) => {
    const input = e.target as HTMLInputElement;
    const parsed = Number.parseInt(input.value || '', 10);
    const value = Number.isFinite(parsed) ? Math.min(1440, Math.max(1, parsed)) : settings.recordingIntervalMinutes;
    input.value = String(value);
    void saveSettings({ recordingIntervalMinutes: value });
  });

  document.getElementById('settingRecordingAutoRestart')?.addEventListener('change', (e) => {
    const value = (e.target as HTMLInputElement).checked;
    void saveSettings({ recordingAutoRestart: value });
  });
})();

// ── Page load initialization ──────────────────────────────────────────────────
(async () => {
  // Load server-side settings first so all modules start with correct values.
  await loadSettings();
  setHealthOnlyFilter(settings.healthOnlyFilter);
  const healthToggle = document.getElementById('healthOnlyCheck') as HTMLInputElement | null;
  if (healthToggle) healthToggle.checked = settings.healthOnlyFilter;

  try {
    const res = await apiFetch('/api/tasks');
    if (!res.ok) return;
    const taskList = await res.json();
    taskList.forEach((task: { id: string; url?: string; status: string }) => {
      addTaskCard(task.id, task.url || '');
      updateTaskCard(task.id, task as Parameters<typeof updateTaskCard>[1]);
      if (['downloading', 'queued', 'merging', 'recording', 'stopping', 'clipping'].includes(task.status)) {
        startPolling(task.id);
      }
    });
  } catch { /* ignore */ }
})();

loadPlaylists({ autoSelect: true });

// Start on the Recents tab
showFavoritesTab();

// Expose showDownloadsTab for player.ts / playlists.ts
(window as unknown as Record<string, unknown>).showDownloadsTab = showDownloadsTab;

void _csi;
