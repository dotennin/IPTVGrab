import { apiFetch } from './api';
import { esc, toast } from './utils';
import { settings, saveSettings } from './settings';
import { Modal } from './bootstrap-shim';
import { renderRecentChannels } from './recents';
import { addTaskCard, updateTaskCard, startPolling, currentRequest as _cr } from './tasks';
import { currentStreamInfo as _csi, showStreamInfo, showError } from './player';
import { loadPlaylists } from './playlists';

// ── Tab switching ─────────────────────────────────────────────────────────────
function setActiveTab(tabId: string): void {
  document.querySelectorAll('.tab-nav .tab-btn').forEach((b) =>
    b.classList.remove('tab-active', 'active'),
  );
  document.getElementById(tabId)?.classList.add('tab-active', 'active');
}

function showPanel(panelId: string): void {
  document.getElementById(panelId)?.classList.remove('d-none');
}

function hidePanel(panelId: string): void {
  document.getElementById(panelId)?.classList.add('d-none');
}

export function showDownloadsTab(): void {
  hidePanel('mainPanels');
  hidePanel('favoritesSection');
  showPanel('downloadsSection');
  setActiveTab('downloads-tab');
}

function hideDownloadsTab(): void {
  showPanel('mainPanels');
  hidePanel('downloadsSection');
  hidePanel('favoritesSection');
  document.getElementById('downloads-tab')?.classList.remove('tab-active', 'active');
}

function showFavoritesTab(): void {
  hidePanel('mainPanels');
  hidePanel('downloadsSection');
  showPanel('favoritesSection');
  setActiveTab('favorites-tab');
  renderRecentChannels();
}

function hideFavoritesTab(): void {
  hidePanel('favoritesSection');
  document.getElementById('favorites-tab')?.classList.remove('tab-active', 'active');
}

function toggleUI(isPlaylist: boolean): void {
  hideDownloadsTab();
  hideFavoritesTab();

  const controls: Array<{ id: string; playlistHide: boolean }> = [
    { id: 'outputSettingsRow', playlistHide: true },
    { id: 'parseBtnGroup',     playlistHide: true },
    { id: 'streamInfoPanel',   playlistHide: true },
    { id: 'channelGridPanel',  playlistHide: false },
  ];

  controls.forEach(({ id, playlistHide }) => {
    if (isPlaylist === playlistHide) { hidePanel(id); } else { showPanel(id); }
  });
}

document.getElementById('favorites-tab')?.addEventListener('click', showFavoritesTab);

document.getElementById('playlist-tab')?.addEventListener('click', () => {
  toggleUI(true);
  setActiveTab('playlist-tab');
});

['url-tab', 'curl-tab'].forEach((id) => {
  document.getElementById(id)?.addEventListener('click', () => {
    toggleUI(false);
    setActiveTab(id);
  });
});

document.getElementById('downloads-tab')?.addEventListener('click', showDownloadsTab);

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

    // Update currentRequest on the imported object reference (tasks.ts)
    _cr.url     = url || data.url || '';
    _cr.headers = data.headers || headers;

    // Auto-fill URL tab
    const urlInput = document.getElementById('urlInput') as HTMLInputElement | null;
    if (urlInput) urlInput.value = data.url || '';
    if (data.headers) populateHeaders(data.headers);

    showStreamInfo(data);
    toast('Parsed successfully', 'success');
  } catch (e) {
    toast((e as Error).message, 'danger');
    showError((e as Error).message);
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
    settingsModal.show();
  });

  document.getElementById('settingUseProxy')?.addEventListener('change', (e) => {
    settings.useProxy = (e.target as HTMLInputElement).checked;
    saveSettings();
  });
})();

// ── Page load initialization ──────────────────────────────────────────────────
(async () => {
  try {
    const res = await apiFetch('/api/tasks');
    if (!res.ok) return;
    const taskList = await res.json();
    taskList.forEach((task: { id: string; url?: string; status: string }) => {
      addTaskCard(task.id, task.url || '');
      updateTaskCard(task.id, task as Parameters<typeof updateTaskCard>[1]);
      if (['downloading', 'queued', 'merging', 'recording', 'stopping'].includes(task.status)) {
        startPolling(task.id);
      }
    });
  } catch { /* ignore */ }
})();

loadPlaylists({ autoSelect: true });

// Expose showDownloadsTab for player.ts / playlists.ts
(window as unknown as Record<string, unknown>).showDownloadsTab = showDownloadsTab;

void _csi;
