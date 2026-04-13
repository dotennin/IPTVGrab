import Sortable from 'sortablejs';
import { apiFetch } from './api';
import { esc, toast } from './utils';
import {
  healthCache,
  healthOnlyFilter,
  setHealthOnlyFilter,
  _healthDot,
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
  setNextOpenAutoFullscreen,
} from './player';
import { addToRecents } from './recents';
import { addTaskCard, startPolling, updateTaskCard } from './tasks';
import { Modal } from './bootstrap-shim';
import type { SavedPlaylist, Channel, MergedChannel, StreamInfo } from './types';

export let currentPlaylist: SavedPlaylist | null = null;
export let allChannels: (Channel & { id?: string; playlist_name?: string })[] = [];

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
    if (prev && [...sel.options].some((o) => o.value === prev)) {
      sel.value = prev;
    } else if (autoSelect && list.length > 0 && !currentPlaylist) {
      sel.value = '__all__';
      await selectPlaylist('__all__');
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
  list.innerHTML = `<li class="channel-group-item${_activeGroup === '' ? ' active' : ''}" data-group="">All</li>`;
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

  setHealthOnlyFilter(true);
  _activeGroup = '';
  const healthOnlyCheck = document.getElementById('healthOnlyCheck') as HTMLInputElement | null;
  if (healthOnlyCheck) healthOnlyCheck.checked = true;

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
      renderChannels(allChannels);
      refreshHealthOnce();
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
    if (countBadge) countBadge.textContent = String(allChannels.length);
    if (refreshBtn) { refreshBtn.disabled = !currentPlaylist!.url; refreshBtn.classList.remove('d-none'); }
    const editPlaylistBtn = document.getElementById('editPlaylistBtn') as HTMLButtonElement | null;
    if (editPlaylistBtn) { editPlaylistBtn.disabled = false; editPlaylistBtn.classList.remove('d-none'); }
    document.getElementById('editAllPlaylistsBtn')?.classList.add('d-none');
    document.getElementById('refreshAllPlaylistsBtn')?.classList.add('d-none');
    if (deleteBtn) deleteBtn.disabled = false;
    renderChannels(allChannels);
    refreshHealthOnce();
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
    const matchHealth = !healthOnlyFilter || (healthCache[ch.url] && healthCache[ch.url].status === 'ok');
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

  if (!channels.length) {
    grid.innerHTML = '';
    placeholder?.classList.remove('d-none');
    return;
  }
  placeholder?.classList.add('d-none');

  grid.innerHTML = channels
    .map(
      (ch, i) => `
    <div class="channel-card" id="channel-${ch.id || i}" tabindex="0" role="button" aria-label="${esc(ch.name || ch.url)}" data-ch-json="${esc(JSON.stringify(ch))}">
      ${_healthDot(ch.url)}
      <div class="channel-logo-wrap">
        ${
          ch.tvg_logo
            ? `<img src="${esc(ch.tvg_logo)}" class="channel-logo" alt=""
                 onerror="this.style.display='none';this.nextElementSibling.style.display='flex'" />
               <div class="channel-logo-fallback" style="display:none"><i class="fas fa-tv"></i></div>`
            : `<div class="channel-logo-fallback"><i class="fas fa-tv"></i></div>`
        }
      </div>
      <div class="channel-name" title="${esc(ch.name)}">${esc(ch.name || ch.url)}</div>
      ${ch.group ? `<div class="channel-group">${esc(ch.group)}</div>` : ''}
      ${ch.playlist_name ? `<div class="channel-playlist-tag" title="${esc(ch.playlist_name)}">${esc(ch.playlist_name)}</div>` : ''}
      <div class="channel-actions">
        <button class="ch-action-btn ch-action-btn-dl channel-dl-btn" data-ch-idx="${i}" title="Download">
          <i class="fas fa-download"></i>
        </button>
        <button class="ch-action-btn ch-action-btn-watch channel-watch-btn" data-ch-idx="${i}" title="Watch online">
          <i class="fas fa-play"></i>
        </button>
      </div>
    </div>`,
    )
    .join('');

  grid.querySelectorAll('.channel-dl-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const idx = parseInt((btn as HTMLElement).dataset.chIdx || '0', 10);
      downloadChannel(channels[idx], btn as HTMLElement);
    });
  });
  grid.querySelectorAll('.channel-watch-btn').forEach((btn) => {
    btn.addEventListener('click', () => {
      const idx = parseInt((btn as HTMLElement).dataset.chIdx || '0', 10);
      addToRecents(channels[idx] as Parameters<typeof addToRecents>[0]);
      watchChannel(channels[idx]);
    });
  });

  // Direct card click / keyboard Enter = watch (TV remote friendly)
  let _lpTimer: ReturnType<typeof setTimeout> | null = null;
  grid.querySelectorAll('.channel-card').forEach((card, i) => {
    const ch = channels[i];

    // Click on card body (not action buttons) → watch with auto-fullscreen
    card.addEventListener('click', (e) => {
      if ((e.target as Element).closest('.channel-actions')) return;
      addToRecents(ch as Parameters<typeof addToRecents>[0]);
      setNextOpenAutoFullscreen(true);
      watchChannel(ch);
    });

    // Keyboard Enter on focused card → watch
    card.addEventListener('keydown', (e) => {
      const key = (e as KeyboardEvent).key;
      if (key === 'Enter' || key === ' ') {
        e.preventDefault();
        addToRecents(ch as Parameters<typeof addToRecents>[0]);
        setNextOpenAutoFullscreen(true);
        watchChannel(ch);
      }
    });

    card.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      const me = e as MouseEvent;
      showChannelContextMenu(ch as unknown as MergedChannel, me.clientX, me.clientY);
    });
    card.addEventListener('touchstart', (e) => {
      const te = e as TouchEvent;
      _lpTimer = setTimeout(() => {
        _lpTimer = null;
        const touch = te.touches[0];
        showChannelContextMenu(ch as unknown as MergedChannel, touch.clientX, touch.clientY);
      }, 500);
    }, { passive: true });
    card.addEventListener('touchend', () => { if (_lpTimer) { clearTimeout(_lpTimer); _lpTimer = null; } });
    card.addEventListener('touchmove', () => { if (_lpTimer) { clearTimeout(_lpTimer); _lpTimer = null; } });
  });
}

// ── Channel context menu ──────────────────────────────────────────────────────
let _ctxChannel: MergedChannel | null = null;

function showChannelContextMenu(ch: MergedChannel, x: number, y: number): void {
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

    let quality = 'best';
    if (streamInfo && streamInfo.kind === 'master' && streamInfo.streams && streamInfo.streams.length > 0) {
      quality = await pickQuality(ch, streamInfo);
    }

    const res  = await apiFetch('/api/download', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ url: ch.url, output_name: ch.name || null, quality, concurrency: 8 }),
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

function pickQuality(
  ch: Channel,
  streamInfo: StreamInfo,
): Promise<string> {
  return new Promise((resolve, reject) => {
    const modalEl = document.getElementById('qualitySelectModal');
    const body    = document.getElementById('qualitySelectBody');
    if (!modalEl || !body) { resolve('0'); return; }
    const titleEl = modalEl.querySelector('.tw-modal-title');
    if (titleEl) titleEl.innerHTML = `<i class="fas fa-layer-group mr-2 text-gh-blue-light"></i>${esc(ch.name || 'Select Quality')}`;

    let html = `<p class="text-gh-muted text-sm mb-3">
      <i class="fas fa-layer-group mr-1"></i>${streamInfo.streams!.length} quality option(s) — choose one to download:
    </p>`;
    streamInfo.streams!.forEach((s, i) => {
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
    body.innerHTML = html;

    body.querySelectorAll('.quality-option').forEach((label) => {
      label.addEventListener('click', () => {
        const radio = label.querySelector('input[type=radio]') as HTMLInputElement | null;
        if (radio) radio.checked = true;
      });
    });

    const modal      = Modal.getOrCreateInstance(modalEl)!;
    const confirmBtn = document.getElementById('qualitySelectConfirmBtn');

    function cleanup(): void {
      confirmBtn?.removeEventListener('click', onConfirm);
      modalEl!.removeEventListener('hidden.bs.modal', onCancel);
    }
    function onConfirm(): void {
      const sel = body!.querySelector('input[name="qs-quality"]:checked') as HTMLInputElement | null;
      cleanup();
      modal.hide();
      resolve(sel ? sel.value : '0');
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
  setHealthOnlyFilter((e.target as HTMLInputElement).checked);
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
      body:    JSON.stringify({ name, url, text }),
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
