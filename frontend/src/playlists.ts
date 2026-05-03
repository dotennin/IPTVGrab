import Sortable from 'sortablejs';
import { apiFetch } from './api';
import { esc, toast } from './utils';
import {
  healthCache,
  healthOnlyFilter,
  healthIsAvailable,
  setHealthOnlyFilter,
  updateHealthDots,
  startHealthPoll,
  refreshHealthOnce,
} from './health';
import {
  openHLSPlayer,
  proxyWatchUrl,
  currentStreamInfo,
  showStreamInfo,
  startDownload,
  setChannelContext,
} from './player';
import { addToRecents } from './recents';
import { addTaskCard, startPolling, updateTaskCard } from './tasks';
import { Modal } from './bootstrap-shim';
import { renderChannelCard, bindChannelGrid } from './channel-card';
import type { BindOptions } from './channel-card';
import type { SavedPlaylist, Channel, MergedChannel, StreamInfo } from './types';
import { normalizeRecordingIntervalMinutes, saveSettings, settings } from './settings';

const PAGE_SIZE = 60;

export let currentPlaylist: SavedPlaylist | null = null;
export let allChannels: (Channel & { id?: string; playlist_name?: string })[] = [];

// ── Virtual / infinite-scroll state ──────────────────────────────────────────
let _virtualChannels: (Channel & { id?: string; playlist_name?: string })[] = [];
let _virtualRendered = 0;
let _scrollObserver: IntersectionObserver | null = null;
let _gridBindOpts: BindOptions | null = null;

function _appendNextPage(): void {
  const grid = document.getElementById('channelGrid');
  if (!grid || !_gridBindOpts) return;

  // Remove old sentinel before adding new content
  grid.querySelector('.channel-load-sentinel')?.remove();

  const batch = _virtualChannels.slice(_virtualRendered, _virtualRendered + PAGE_SIZE);
  if (batch.length === 0) return;

  // Render batch into a temp container so we only bind the new cards
  const tmp = document.createElement('div');
  tmp.innerHTML = batch
    .map((ch, batchIdx) => renderChannelCard(ch, _virtualRendered + batchIdx, { showPlaylistTag: true }))
    .join('');
  bindChannelGrid(tmp, _virtualChannels, _gridBindOpts);
  while (tmp.firstChild) grid.appendChild(tmp.firstChild);

  _virtualRendered += batch.length;

  // Append sentinel and observe if there are more channels to load
  if (_virtualRendered < _virtualChannels.length) {
    const sentinel = document.createElement('div');
    sentinel.className = 'channel-load-sentinel';
    grid.appendChild(sentinel);
    _scrollObserver?.observe(sentinel);
  }
}

export async function loadPlaylists({ autoSelect = false } = {}): Promise<void> {
  try {
    const res = await apiFetch('/api/playlists');
    if (!res.ok) return;
    const list: SavedPlaylist[] = await res.json();
    const sel = document.getElementById('playlistSelect') as HTMLSelectElement | null;
    if (!sel) return;
    const prev = sel.value;
    sel.innerHTML = '<option value="">＋ Add playlist…</option>';
    if (list.length > 0) {
      const totalChannels = list.reduce((sum, pl) => sum + (pl.channel_count || 0), 0);
      const allOpt = document.createElement('option');
      allOpt.value = '__all__';
      allOpt.textContent = `All Playlists (${totalChannels})`;
      sel.appendChild(allOpt);
    }
    for (const pl of list) {
      const opt = document.createElement('option');
      opt.value = pl.id;
      opt.textContent = `${pl.name} (${pl.channel_count})`;
      sel.appendChild(opt);
    }
    if (autoSelect && list.length > 0) {
      sel.value = '__all__';
      await selectPlaylist('__all__');
    } else if (prev && [...sel.options].some((o) => o.value === prev)) {
      sel.value = prev;
    }
  } catch { /* ignore */ }
}

let _activeGroup = '';

function _populateGroupFilter(
  channels: (Channel & { group?: string | null })[],
  orderedGroups: string[] | null = null,
): void {
  const list    = document.getElementById('groupList');
  const sidebar = document.getElementById('channelGroupSidebar');
  if (!list || !sidebar) return;

  const groups = orderedGroups
    ? orderedGroups
    : [...new Set(channels.map((c) => c.group).filter(Boolean) as string[])].sort();
  list.innerHTML = `<li class="channel-group-item" data-group="">All</li>`;
  // default to first group if active group not present in new list
  if (groups.length > 0 && !_activeGroup) _activeGroup = groups[0];
  for (const g of groups) {
    const li = document.createElement('li');
    li.className = 'channel-group-item' + (g === _activeGroup ? ' active' : '');
    li.dataset.group = g;
    li.textContent = g;
    li.title = g;
    list.appendChild(li);
  }
  sidebar.classList.toggle('d-none', groups.length === 0);
  const countEl = document.getElementById('groupCount');
  if (countEl) countEl.textContent = groups.length > 0 ? String(groups.length) : '';
}

export async function selectPlaylist(id: string): Promise<void> {
  const filterBar  = document.getElementById('channelFilterBar');
  const countBadge = document.getElementById('channelCountBadge');
  const refreshBtn = document.getElementById('refreshPlaylistBtn') as HTMLButtonElement | null;
  const deleteBtn  = document.getElementById('deletePlaylistBtn') as HTMLButtonElement | null;


  if (!id) {
    currentPlaylist = null;
    allChannels = [];
    renderChannels([]);
    filterBar?.classList.add('d-none');
    document.getElementById('channelSearch')?.classList.add('d-none');
    document.getElementById('healthOnlyWrap')?.classList.add('d-none');
    document.getElementById('channelGroupSidebar')?.classList.add('d-none');
    if (countBadge) countBadge.textContent = '0';
    if (refreshBtn) refreshBtn.disabled = true;
    const editPlaylistBtn = document.getElementById('editPlaylistBtn') as HTMLButtonElement | null;
    if (editPlaylistBtn) editPlaylistBtn.disabled = true;
    document.getElementById('editAllPlaylistsBtn')?.classList.add('d-none');
    document.getElementById('refreshAllPlaylistsBtn')?.classList.add('d-none');
    if (deleteBtn) deleteBtn.disabled = true;
    return;
  }

  if (id === '__all__') {
    try {
      const res = await apiFetch('/api/all-playlists');
      if (!res.ok) throw new Error('Failed to load channels');
      const data = await res.json();
      currentPlaylist = null;
      allChannels = [];
      for (const g of data.groups || []) {
        if (!g.enabled) continue;
        for (const ch of g.channels || []) {
          if (!ch.enabled) continue;
          allChannels.push({ ...ch, playlist_name: ch.source_playlist_name || '' });
        }
      }
      _populateGroupFilter(
        allChannels,
        (data.groups || []).filter((g: { enabled: boolean }) => g.enabled).map((g: { name: string }) => g.name),
      );
      const channelSearch = document.getElementById('channelSearch') as HTMLInputElement | null;
      if (channelSearch) { channelSearch.value = ''; channelSearch.classList.remove('d-none'); }
      filterBar?.classList.remove('d-none');
      document.getElementById('healthOnlyWrap')?.classList.remove('d-none');
      if (countBadge) countBadge.textContent = String(allChannels.length);
      if (refreshBtn) { refreshBtn.disabled = true; refreshBtn.classList.add('d-none'); }
      const editPlaylistBtn = document.getElementById('editPlaylistBtn') as HTMLButtonElement | null;
      if (editPlaylistBtn) { editPlaylistBtn.disabled = true; editPlaylistBtn.classList.add('d-none'); }
      if (deleteBtn) deleteBtn.disabled = true;
      document.getElementById('editAllPlaylistsBtn')?.classList.remove('d-none');
      document.getElementById('refreshAllPlaylistsBtn')?.classList.remove('d-none');
      await refreshHealthOnce();
      renderChannels(getFilteredChannels());
    } catch (e) {
      toast((e as Error).message, 'danger');
    }
    return;
  }

  try {
    const res = await apiFetch(`/api/playlists/${id}`);
    if (!res.ok) throw new Error('Failed to load playlist');
    currentPlaylist = await res.json();
    allChannels = currentPlaylist!.channels || [];
    _populateGroupFilter(allChannels);
    const channelSearch = document.getElementById('channelSearch') as HTMLInputElement | null;
    if (channelSearch) { channelSearch.value = ''; channelSearch.classList.remove('d-none'); }
    filterBar?.classList.remove('d-none');
    document.getElementById('healthOnlyWrap')?.classList.remove('d-none');
    if (refreshBtn) { refreshBtn.disabled = !currentPlaylist!.url; refreshBtn.classList.remove('d-none'); }
    const editPlaylistBtn = document.getElementById('editPlaylistBtn') as HTMLButtonElement | null;
    if (editPlaylistBtn) { editPlaylistBtn.disabled = false; editPlaylistBtn.classList.remove('d-none'); }
    document.getElementById('editAllPlaylistsBtn')?.classList.add('d-none');
    document.getElementById('refreshAllPlaylistsBtn')?.classList.add('d-none');
    if (deleteBtn) deleteBtn.disabled = false;
    await refreshHealthOnce();
    renderChannels(getFilteredChannels());
  } catch (e) {
    toast((e as Error).message, 'danger');
  }
}

export function getFilteredChannels(): (Channel & { id?: string; playlist_name?: string })[] {
  const search = (document.getElementById('channelSearch') as HTMLInputElement | null)?.value.toLowerCase() || '';
  return allChannels.filter((ch) => {
    const matchSearch =
      !search ||
      (ch.name || '').toLowerCase().includes(search) ||
      (ch.group || '').toLowerCase().includes(search) ||
      (ch.playlist_name || '').toLowerCase().includes(search);
    const matchGroup  = !_activeGroup || ch.group === _activeGroup;
    const matchHealth = !healthOnlyFilter || (healthCache[ch.url] && healthIsAvailable(healthCache[ch.url].status));
    // return matchSearch && matchGroup;
    return matchSearch && matchGroup && matchHealth;
  });
}

export function renderChannels(
  channels: (Channel & { id?: string; playlist_name?: string })[],
): void {
  const grid        = document.getElementById('channelGrid');
  const placeholder = document.getElementById('channelPlaceholder');
  const countBadge  = document.getElementById('channelCountBadge');
  if (countBadge) {
    countBadge.textContent =
      allChannels.length > 0 && channels.length !== allChannels.length
        ? `${channels.length} / ${allChannels.length}`
        : String(channels.length);
  }
  if (!grid) return;

  // Tear down previous observer before re-rendering
  _scrollObserver?.disconnect();
  _scrollObserver = null;

  if (!channels.length) {
    grid.innerHTML = '';
    _virtualChannels = [];
    _virtualRendered = 0;
    placeholder?.classList.remove('d-none');
    return;
  }
  placeholder?.classList.add('d-none');

  // Store bind-options once so _appendNextPage can reuse them
  _gridBindOpts = {
    onWatch: (ch) => {
      addToRecents(ch as Parameters<typeof addToRecents>[0]);
      const idx = _virtualChannels.findIndex(c => c === ch);
      setChannelContext(_virtualChannels as Channel[], idx >= 0 ? idx : 0);
      watchChannel(ch);
    },
    onDownload: (ch, btn) => {
      downloadChannel(ch as Channel & { id?: string; tvg_logo?: string }, btn);
    },
    onContextMenu: (ch, x, y) => {
      showChannelContextMenu(ch as unknown as MergedChannel, x, y);
    },
  };

  // Initialise virtual-scroll state
  _virtualChannels = channels;
  _virtualRendered = 0;
  grid.innerHTML   = '';

  _scrollObserver = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          _scrollObserver!.unobserve(entry.target);
          _appendNextPage();
        }
      }
    },
    { rootMargin: '300px' },
  );

  _appendNextPage();
}

// ── Channel context menu ──────────────────────────────────────────────────────
let _ctxChannel: MergedChannel | null = null;

export function showChannelContextMenu(ch: MergedChannel, x: number, y: number): void {
  _ctxChannel = ch;
  const menu = document.getElementById('channelContextMenu');
  if (!menu) return;
  menu.classList.remove('hidden');
  const mw = 200, mh = 160;
  const left = x + mw > window.innerWidth  ? x - mw : x;
  const top  = y + mh > window.innerHeight ? y - mh : y;
  (menu as HTMLElement).style.left = left + 'px';
  (menu as HTMLElement).style.top  = top  + 'px';
}

function hideChannelContextMenu(): void {
  document.getElementById('channelContextMenu')?.classList.add('hidden');
  _ctxChannel = null;
}

document.addEventListener('click',   hideChannelContextMenu);
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') hideChannelContextMenu(); });

document.getElementById('ctxDownloadChannel')?.addEventListener('click', (e) => {
  e.stopPropagation();
  if (_ctxChannel) downloadChannel(_ctxChannel as unknown as Channel & { id?: string; tvg_logo?: string });
});

document.getElementById('ctxWatchChannel')?.addEventListener('click', (e) => {
  e.stopPropagation();
  if (_ctxChannel) {
    addToRecents(_ctxChannel as unknown as Parameters<typeof addToRecents>[0]);
    watchChannel(_ctxChannel as unknown as Channel);
  }
});

document.getElementById('ctxCopyChannelUrl')?.addEventListener('click', (e) => {
  e.stopPropagation();
  if (!_ctxChannel?.url) return;
  navigator.clipboard.writeText(_ctxChannel.url)
    .then(() => toast('URL copied', 'success'))
    .catch(() => toast('Copy failed', 'danger'));
  hideChannelContextMenu();
});

document.getElementById('ctxDisableChannel')?.addEventListener('click', async (e) => {
  e.stopPropagation();
  const ch = _ctxChannel;
  hideChannelContextMenu();
  if (ch) await disableChannelInAllPlaylists(ch);
});

async function disableChannelInAllPlaylists(ch: MergedChannel): Promise<void> {
  try {
    let channelId = ch.id;
    if (!channelId) {
      const res = await apiFetch('/api/all-playlists');
      if (!res.ok) throw new Error('Failed to load All Playlists config');
      const data = await res.json();
      outer: for (const g of data.groups || []) {
        for (const c of g.channels || []) {
          if (c.url === ch.url) { channelId = c.id; break outer; }
        }
      }
    }
    if (!channelId) {
      toast('Channel not found in All Playlists. Open the editor to add it first.', 'warning');
      return;
    }
    const res = await apiFetch(`/api/all-playlists/channels/${encodeURIComponent(channelId)}`, {
      method:  'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ enabled: false }),
    });
    if (!res.ok) {
      const d = await res.json();
      throw new Error(d.detail || 'Failed to disable channel');
    }
    toast(`Disabled: ${ch.name || ch.url}`, 'success');
    document.getElementById(`channel-${channelId}`)?.remove();
  } catch (e) {
    toast((e as Error).message, 'danger');
  }
}

export async function downloadChannel(
  ch: Channel & { id?: string; tvg_logo?: string },
  triggerBtn: Element | null = null,
): Promise<void> {
  const btn = triggerBtn as HTMLButtonElement | null;
  if (btn) { btn.disabled = true; btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i>'; }
  try {
    const parseRes = await apiFetch('/api/parse', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ url: ch.url, headers: {} }),
    });
    const streamInfo: StreamInfo | null = parseRes.ok ? await parseRes.json() : null;

    let downloadOptions: { quality: string; recordingIntervalMinutes?: number; recordingAutoRestart: boolean } = {
      quality: 'best',
      recordingAutoRestart: false,
    };
    if (streamInfo && (streamInfo.is_live || (streamInfo.kind === 'master' && streamInfo.streams && streamInfo.streams.length > 0))) {
      downloadOptions = await pickDownloadOptions(ch, streamInfo);
    }

    const res  = await apiFetch('/api/download', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({
        url: ch.url,
        output_name: ch.name || null,
        quality: downloadOptions.quality,
        concurrency: 8,
        recording_interval_minutes: streamInfo?.is_live ? downloadOptions.recordingIntervalMinutes : undefined,
        recording_auto_restart: streamInfo?.is_live ? downloadOptions.recordingAutoRestart : false,
      }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Failed to start download');

    const taskRes = await apiFetch(`/api/tasks/${data.task_id}`);
    if (taskRes.ok) {
      const task = await taskRes.json();
      addTaskCard(task.id, task.url || '');
      updateTaskCard(task.id, task);
      startPolling(task.id);
    }
    showDownloadsTab();
    toast(`Started: ${ch.name || ch.url}`, 'success');
  } catch (e) {
    if ((e as Error).message !== 'cancelled') toast((e as Error).message, 'danger');
  } finally {
    if (btn) { btn.disabled = false; btn.innerHTML = '<i class="fas fa-download"></i>'; }
  }
}

function showDownloadsTab(): void {
  (window as unknown as Record<string, Function>).showDownloadsTab?.();
}

function pickDownloadOptions(
  ch: Channel,
  streamInfo: StreamInfo,
): Promise<{ quality: string; recordingIntervalMinutes?: number; recordingAutoRestart: boolean }> {
  return new Promise((resolve, reject) => {
    const modalEl = document.getElementById('qualitySelectModal');
    const body    = document.getElementById('qualitySelectBody');
    if (!modalEl || !body) {
      resolve({ quality: 'best', recordingAutoRestart: false });
      return;
    }
    const titleEl = modalEl.querySelector('.tw-modal-title');
    if (titleEl) titleEl.innerHTML = `<i class="fas fa-layer-group mr-2 text-gh-blue-light"></i>${esc(ch.name || 'Select Quality')}`;

    let html = '';
    if (streamInfo.kind === 'master' && streamInfo.streams && streamInfo.streams.length > 0) {
      html += `<p class="text-gh-muted text-sm mb-3">
        <i class="fas fa-layer-group mr-1"></i>${streamInfo.streams.length} quality option(s) — choose one to ${streamInfo.is_live ? 'record' : 'download'}:
      </p>`;
      streamInfo.streams.forEach((s, i) => {
        const checked = i === 0 ? 'checked' : '';
        html += `
          <label class="quality-option d-flex align-items-center gap-3 w-100">
            <input type="radio" name="qs-quality" value="${i}" ${checked} class="flex-shrink-0" />
            <div class="flex-grow-1">
              <div class="fw-semibold">${esc(s.label)}</div>
              <div class="text-muted small">
                ${s.resolution ? `${esc(s.resolution)} · ` : ''}
                ${Math.round(s.bandwidth / 1000)} kbps
                ${s.codecs ? ` · ${esc(s.codecs)}` : ''}
              </div>
            </div>
            ${i === 0 ? '<span class="badge bg-success">Best</span>' : ''}
          </label>`;
      });
    } else {
      html += `<p class="text-gh-muted text-sm mb-3">
        <i class="fas fa-circle mr-1 text-gh-red"></i>Live stream — recording starts immediately after confirmation.
      </p>`;
    }
    if (streamInfo.is_live) {
      html += `
        <div class="border-top border-gh-border mt-3 pt-3">
          <div class="grid grid-cols-12 gap-3">
            <div class="col-span-6">
              <label class="form-label text-gh-muted text-sm">Recording interval (minutes)</label>
              <input type="number" class="form-control" id="qsRecordingInterval" min="1" max="1440" step="1" value="${settings.recordingIntervalMinutes}" />
            </div>
            <div class="col-span-6">
              <label class="form-label text-gh-muted text-sm d-block">After each interval</label>
              <label class="inline-flex items-center gap-2 text-sm mt-2">
                <input type="checkbox" id="qsRecordingAutoRestart" ${settings.recordingAutoRestart ? 'checked' : ''} />
                <span>Save and start a new recording</span>
              </label>
            </div>
          </div>
        </div>`;
    }
    body.innerHTML = html;

    body.querySelectorAll('.quality-option').forEach((label) => {
      label.addEventListener('click', () => {
        const radio = label.querySelector('input[type=radio]') as HTMLInputElement | null;
        if (radio) radio.checked = true;
      });
    });

    const modal      = Modal.getOrCreateInstance(modalEl)!;
    const confirmBtn = document.getElementById('qualitySelectConfirmBtn');
    if (confirmBtn) {
      confirmBtn.innerHTML = streamInfo.is_live
        ? '<i class="fas fa-circle mr-1"></i>Start recording'
        : '<i class="fas fa-download mr-1"></i>Download';
    }

    function cleanup(): void {
      confirmBtn?.removeEventListener('click', onConfirm);
      modalEl!.removeEventListener('hidden.bs.modal', onCancel);
    }
    function onConfirm(): void {
      const sel = body!.querySelector('input[name="qs-quality"]:checked') as HTMLInputElement | null;
      const recordingIntervalEl = body!.querySelector('#qsRecordingInterval') as HTMLInputElement | null;
      const recordingAutoRestartEl = body!.querySelector('#qsRecordingAutoRestart') as HTMLInputElement | null;
      cleanup();
      modal.hide();
      resolve({
        quality: sel ? sel.value : 'best',
        recordingIntervalMinutes: streamInfo.is_live
          ? normalizeRecordingIntervalMinutes(recordingIntervalEl?.value || settings.recordingIntervalMinutes)
          : undefined,
        recordingAutoRestart: streamInfo.is_live
          ? (recordingAutoRestartEl?.checked ?? settings.recordingAutoRestart)
          : false,
      });
    }
    function onCancel(): void { cleanup(); reject(new Error('cancelled')); }

    confirmBtn?.addEventListener('click', onConfirm);
    modalEl!.addEventListener('hidden.bs.modal', onCancel);
    modal.show();
  });
}

export function watchChannel(ch: Channel): void {
  openHLSPlayer(proxyWatchUrl(ch.url), ch.name || ch.url, true);
}

// ── Playlist event listeners ──────────────────────────────────────────────────
const playlistSelect = document.getElementById('playlistSelect') as HTMLSelectElement | null;

playlistSelect?.addEventListener('mousedown', (e) => {
  const sel = document.getElementById('playlistSelect') as HTMLSelectElement;
  if (sel.value === '') {
    e.preventDefault();
    new Modal(document.getElementById('addPlaylistModal')!).show();
  }
});

playlistSelect?.addEventListener('change', (e) => {
  const val = (e.target as HTMLSelectElement).value;
  if (val === '') {
    const sel = document.getElementById('playlistSelect') as HTMLSelectElement;
    sel.value = currentPlaylist?.id || (allChannels.length ? '__all__' : '');
    new Modal(document.getElementById('addPlaylistModal')!).show();
    return;
  }
  selectPlaylist(val);
});

document.getElementById('channelSearch')?.addEventListener('input', () => {
  renderChannels(getFilteredChannels());
});

document.getElementById('groupList')?.addEventListener('click', (e) => {
  const item = (e.target as HTMLElement).closest('.channel-group-item') as HTMLElement | null;
  if (!item) return;
  _activeGroup = item.dataset.group || '';
  document.querySelectorAll('.channel-group-item').forEach((el) =>
    el.classList.toggle('active', el === item),
  );
  renderChannels(getFilteredChannels());
});

document.getElementById('healthOnlyCheck')?.addEventListener('change', (e) => {
  const value = (e.target as HTMLInputElement).checked;
  setHealthOnlyFilter(value);
  // Sync settings modal toggle
  const settingsToggle = document.getElementById('settingHealthOnly') as HTMLInputElement | null;
  if (settingsToggle) settingsToggle.checked = value;
  void saveSettings({ healthOnlyFilter: value });
  renderChannels(getFilteredChannels());
});

document.getElementById('refreshPlaylistBtn')?.addEventListener('click', async () => {
  if (!currentPlaylist) return;
  const btn = document.getElementById('refreshPlaylistBtn') as HTMLButtonElement;
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i>';
  try {
    const res = await apiFetch(`/api/playlists/${currentPlaylist.id}/refresh`, { method: 'POST' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Refresh failed');
    await selectPlaylist(currentPlaylist.id);
    await loadPlaylists();
    toast(`Refreshed: ${data.channel_count} channels`, 'success');
    startHealthPoll();
  } catch (e) {
    toast((e as Error).message, 'danger');
  } finally {
    btn.disabled = !currentPlaylist?.url;
    btn.innerHTML = '<i class="fas fa-sync-alt"></i>';
  }
});

document.getElementById('editPlaylistBtn')?.addEventListener('click', () => {
  if (!currentPlaylist) return;
  (document.getElementById('editPlaylistName') as HTMLInputElement).value = currentPlaylist.name || '';
  (document.getElementById('editPlaylistUrl') as HTMLInputElement).value = currentPlaylist.url || '';
  new Modal(document.getElementById('editPlaylistModal')!).show();
});

document.getElementById('saveEditPlaylistBtn')?.addEventListener('click', async () => {
  if (!currentPlaylist) return;
  const name = (document.getElementById('editPlaylistName') as HTMLInputElement).value.trim();
  const url  = (document.getElementById('editPlaylistUrl')  as HTMLInputElement).value.trim();
  if (!name) { toast('Playlist name cannot be empty', 'danger'); return; }
  const btn = document.getElementById('saveEditPlaylistBtn') as HTMLButtonElement;
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Saving...';
  try {
    const res = await apiFetch(`/api/playlists/${currentPlaylist.id}`, {
      method:  'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ name, url }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Edit failed');
    Modal.getInstance(document.getElementById('editPlaylistModal')!)?.hide();
    await loadPlaylists();
    await selectPlaylist(currentPlaylist.id);
    toast('Playlist updated', 'success');
  } catch (e) {
    toast((e as Error).message, 'danger');
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-save me-1"></i>Save';
  }
});

document.getElementById('deletePlaylistBtn')?.addEventListener('click', async () => {
  if (!currentPlaylist) return;
  if (!confirm(`Delete playlist "${currentPlaylist.name}"?`)) return;
  const deletedId = currentPlaylist.id;
  try {
    const res = await apiFetch(`/api/playlists/${deletedId}`, { method: 'DELETE' });
    if (!res.ok) throw new Error('Delete failed');
    currentPlaylist = null;
    allChannels = [];
    await loadPlaylists();
    const sel = document.getElementById('playlistSelect') as HTMLSelectElement | null;
    if (sel) sel.value = '';
    await selectPlaylist('');
    toast('Playlist deleted', 'success');
  } catch (e) {
    toast((e as Error).message, 'danger');
  }
});

document.getElementById('savePlaylistBtn')?.addEventListener('click', async () => {
  const name = (document.getElementById('newPlaylistName') as HTMLInputElement).value.trim();
  const url  = (document.getElementById('newPlaylistUrl')  as HTMLInputElement).value.trim();
  const text = (document.getElementById('newPlaylistText') as HTMLTextAreaElement).value.trim();

  if (!url && !text) { toast('Please provide a playlist URL or paste playlist content', 'danger'); return; }

  const btn = document.getElementById('savePlaylistBtn') as HTMLButtonElement;
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Loading...';
  try {
    const res = await apiFetch('/api/playlists', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ name, url, raw: text }),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Failed to add playlist');

    Modal.getInstance(document.getElementById('addPlaylistModal')!)?.hide();
    (document.getElementById('newPlaylistName') as HTMLInputElement).value = '';
    (document.getElementById('newPlaylistUrl')  as HTMLInputElement).value = '';
    (document.getElementById('newPlaylistText') as HTMLTextAreaElement).value = '';

    await loadPlaylists();
    const sel = document.getElementById('playlistSelect') as HTMLSelectElement | null;
    if (sel) sel.value = data.id;
    await selectPlaylist(data.id);
    toast(`Playlist added: ${data.channel_count} channels`, 'success');
    startHealthPoll();
  } catch (e) {
    toast((e as Error).message, 'danger');
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-save me-1"></i>Save';
  }
});

// expose downloadChannel and watchChannel on window (used by recents.ts)
(window as unknown as Record<string, unknown>).downloadChannel = downloadChannel;
(window as unknown as Record<string, unknown>).watchChannel    = watchChannel;

// Silence unused import warnings — these re-exported functions are intentionally
// side-effect-imported to ensure they're bundled.
void currentStreamInfo;
void showStreamInfo;
void startDownload;
void updateHealthDots;
void Sortable;
