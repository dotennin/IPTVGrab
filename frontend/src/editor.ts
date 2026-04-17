import Sortable from 'sortablejs';
import { Modal } from './bootstrap-shim';
import { apiFetch } from './api';
import { esc, toast } from './utils';
import { startHealthPoll, _healthDotInline, _originLabel } from './health';
import { loadPlaylists, selectPlaylist } from './playlists';
import type { MergedGroup, MergedChannel } from './types';

let editorGroups: MergedGroup[] = [];
let editorSelectedGroupId: string | null = null;
let groupSortable: Sortable | null = null;
let channelSortable: Sortable | null = null;
let editorDirty = false;
let editorChannelFilter = '';
const EDITOR_FILTER_DEBOUNCE_MS = 120;
let editorFilterRenderTimer: ReturnType<typeof window.setTimeout> | null = null;

function flashButtonIcon(button: Element, nextClass: string): void {
  const icon = button.querySelector('i');
  if (!icon) return;
  const originalClass = icon.className;
  icon.className = nextClass;
  window.setTimeout(() => {
    icon.className = originalClass;
  }, 1500);
}

function filterEditorGroups(groups: MergedGroup[], filter: string): MergedGroup[] {
  const query = filter.trim().toLowerCase();
  if (!query) return groups;
  return groups
    .map((group) => ({
      ...group,
      channels: (group.channels || []).filter((ch) => [ch.name, ch.url, ch.source_playlist_name, group.name]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(query))),
    }))
    .filter((group) => group.channels.length > 0);
}

function findEditorChannel(groupId: string | undefined, channelId: string | undefined): {
  group: MergedGroup;
  channel: MergedChannel;
} | null {
  if (!groupId || !channelId) return null;
  const group = editorGroups.find((item) => item.id === groupId);
  if (!group) return null;
  const channel = (group.channels || []).find((item) => item.id === channelId);
  return channel ? { group, channel } : null;
}

function renderEditorChannelItem(ch: MergedChannel, group: MergedGroup): string {
  return `
    <div class="editor-channel-item${ch.enabled ? '' : ' disabled-item'}" data-group-id="${group.id}" data-ch-id="${ch.id}">
      <span class="drag-handle"><i class="fas fa-grip-vertical"></i></span>
      ${ch.tvg_logo ? `<img src="${esc(ch.tvg_logo)}" class="ch-logo" alt="" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'">` : ''}
      <div class="ch-logo-fallback" ${ch.tvg_logo ? 'style="display:none"' : ''}><i class="fas fa-tv"></i></div>
      <div class="flex-grow-1" style="min-width:0">
        <div class="editor-item-name" title="${esc(ch.name)}">${esc(ch.name || ch.url)} ${_healthDotInline(ch.url)}</div>
        <div class="editor-channel-url" title="${esc(ch.url)}">${esc(ch.url)}</div>
        ${ch.source_playlist_name ? `<div class="editor-channel-source">${esc(ch.source_playlist_name)}</div>` : ''}
        ${ch.origin_id ? _originLabel(ch.origin_label ?? null) : ''}
      </div>
      <span class="editor-item-actions">
        <div class="form-check form-switch mb-0">
          <input class="form-check-input editor-ch-toggle" type="checkbox" ${ch.enabled ? 'checked' : ''} data-group-id="${group.id}" data-chid="${ch.id}">
        </div>
        ${ch.custom ? `<button class="btn btn-outline-primary btn-xs editor-edit-ch-btn" data-group-id="${group.id}" data-chid="${ch.id}" title="Edit"><i class="fas fa-pencil-alt"></i></button>` : ''}
        <button class="btn btn-outline-info btn-xs editor-copy-url-btn" data-group-id="${group.id}" data-chid="${ch.id}" title="Copy URL"><i class="fas fa-copy"></i></button>
        <button class="btn btn-outline-warning btn-xs editor-move-ch-btn" data-group-id="${group.id}" data-chid="${ch.id}" title="Move to group"><i class="fas fa-exchange-alt"></i></button>
        <button class="btn ${ch.custom ? 'btn-outline-danger' : 'btn-outline-secondary'} btn-xs editor-delete-ch-btn" data-group-id="${group.id}" data-chid="${ch.id}" ${ch.custom ? '' : 'disabled'} title="${ch.custom ? 'Delete' : 'Source channels cannot be deleted'}">
          <i class="fas fa-trash-alt"></i>
        </button>
      </span>
    </div>`;
}

function scheduleEditorFilterRender(value: string): void {
  editorChannelFilter = value;
  if (editorFilterRenderTimer) window.clearTimeout(editorFilterRenderTimer);
  editorFilterRenderTimer = window.setTimeout(() => {
    editorFilterRenderTimer = null;
    renderEditorChannels();
  }, EDITOR_FILTER_DEBOUNCE_MS);
}

function openAllPlaylistsEditor(): void {
  editorDirty = false;
  editorChannelFilter = '';
  if (editorFilterRenderTimer) {
    window.clearTimeout(editorFilterRenderTimer);
    editorFilterRenderTimer = null;
  }
  apiFetch('/api/all-playlists')
    .then((r) => r.json())
    .then((data) => {
      editorGroups = data.groups || [];
      editorSelectedGroupId = null;
      renderEditorGroups();
      renderEditorChannels();
      new Modal(document.getElementById('allPlaylistsEditorModal')!).show();
    })
    .catch((e: Error) => toast(e.message, 'danger'));
}

function renderEditorGroups(): void {
  const list = document.getElementById('editorGroupList');
  if (!list) return;
  list.innerHTML = editorGroups
    .map(
      (g) => `
    <div class="editor-group-item${g.id === editorSelectedGroupId ? ' active' : ''}${g.enabled ? '' : ' disabled-item'}"
         data-group-id="${g.id}">
      <span class="drag-handle"><i class="fas fa-grip-vertical"></i></span>
      <span class="editor-item-name" title="${esc(g.name)}">${esc(g.name)}</span>
      <span class="editor-item-badge badge ${g.custom ? 'bg-info' : 'bg-secondary'}">${g.channels?.length || 0}</span>
      <span class="editor-item-actions">
        <div class="form-check form-switch mb-0">
          <input class="form-check-input editor-group-toggle" type="checkbox" ${g.enabled ? 'checked' : ''} data-gid="${g.id}" title="${g.enabled ? 'Enabled' : 'Disabled'}">
        </div>
        ${g.custom ? `<button class="btn btn-outline-primary btn-xs editor-rename-group-btn" data-gid="${g.id}" title="Rename group"><i class="fas fa-pencil-alt"></i></button>` : ''}
        <button class="btn ${g.custom ? 'btn-outline-danger' : 'btn-outline-secondary'} btn-xs editor-delete-group-btn" data-gid="${g.id}" ${g.custom ? '' : 'disabled'} title="${g.custom ? 'Delete group' : 'Source groups cannot be deleted'}">
          <i class="fas fa-trash-alt"></i>
        </button>
      </span>
    </div>`,
    )
    .join('');

  list.querySelectorAll('.editor-group-item').forEach((el) => {
    el.addEventListener('click', (e) => {
      if ((e.target as HTMLElement).closest('.editor-item-actions')) return;
      editorSelectedGroupId = (el as HTMLElement).dataset.groupId || null;
      renderEditorGroups();
      renderEditorChannels();
    });
  });

  list.querySelectorAll('.editor-group-toggle').forEach((cb) => {
    cb.addEventListener('change', (e) => {
      e.stopPropagation();
      const input = cb as HTMLInputElement;
      const g = editorGroups.find((g) => g.id === input.dataset.gid);
      if (g) { g.enabled = input.checked; editorDirty = true; renderEditorGroups(); }
    });
  });

  list.querySelectorAll('.editor-rename-group-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const g = editorGroups.find((g) => g.id === (btn as HTMLElement).dataset.gid);
      if (!g?.custom) return;
      (document.getElementById('renameGroupNameInput') as HTMLInputElement).value = g.name;
      (document.getElementById('renameGroupIdInput')  as HTMLInputElement).value = g.id;
      const modal = new Modal(document.getElementById('renameGroupModal')!);
      modal.show();
      setTimeout(() => {
        const input = document.getElementById('renameGroupNameInput') as HTMLInputElement;
        input.focus(); input.select();
      }, 50);
    });
  });

  list.querySelectorAll('.editor-delete-group-btn:not([disabled])').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const gid = (btn as HTMLElement).dataset.gid;
      const g = editorGroups.find((g) => g.id === gid);
      if (!g?.custom) return;
      if (!confirm(`Delete custom group "${g.name}" and all its channels?`)) return;
      editorGroups = editorGroups.filter((g) => g.id !== gid);
      if (editorSelectedGroupId === gid) editorSelectedGroupId = null;
      editorDirty = true;
      renderEditorGroups();
      renderEditorChannels();
    });
  });

  if (groupSortable) groupSortable.destroy();
  groupSortable = new Sortable(list as HTMLElement, {
    handle: '.drag-handle',
    animation: 150,
    ghostClass: 'sortable-ghost',
    chosenClass: 'sortable-chosen',
    onEnd: () => {
      const newOrder = [...list.querySelectorAll('.editor-group-item')].map(
        (el) => (el as HTMLElement).dataset.groupId,
      );
      const reordered = newOrder
        .map((id) => editorGroups.find((g) => g.id === id))
        .filter((g): g is MergedGroup => !!g);
      editorGroups = reordered;
      editorDirty = true;
    },
  });
}

function renderEditorChannels(): void {
  const list        = document.getElementById('editorChannelList');
  const placeholder = document.getElementById('editorChannelPlaceholder');
  const emptyState  = document.getElementById('editorChannelEmptyState');
  const addBtn      = document.getElementById('editorAddChannelBtn');
  const countEl     = document.getElementById('editorChannelCount');
  const nameEl      = document.getElementById('editorSelectedGroupName');
  const filterRow   = document.getElementById('editorChannelFilterRow');
  const filterInput = document.getElementById('editorChannelFilterInput') as HTMLInputElement | null;
  const clearBtn    = document.getElementById('editorChannelFilterClearBtn') as HTMLButtonElement | null;
  if (!list || !placeholder || !emptyState) return;

  if (filterInput && filterInput.value !== editorChannelFilter) {
    filterInput.value = editorChannelFilter;
  }
  clearBtn?.classList.toggle('d-none', !editorChannelFilter.trim());

  const selectedGroup = editorGroups.find((g) => g.id === editorSelectedGroupId);
  const isFiltering = !!editorChannelFilter.trim();
  const visibleGroups = isFiltering
    ? filterEditorGroups(editorGroups, editorChannelFilter)
    : selectedGroup ? [selectedGroup] : [];
  const matchedChannels = visibleGroups.reduce((sum, group) => sum + (group.channels?.length || 0), 0);

  filterRow?.classList.toggle('d-none', editorGroups.length === 0);
  addBtn?.classList.toggle('d-none', !selectedGroup);
  if (countEl) countEl.textContent = String(matchedChannels);
  if (nameEl) {
    if (isFiltering) {
      nameEl.textContent = visibleGroups.length
        ? `— ${visibleGroups.length} group${visibleGroups.length === 1 ? '' : 's'} matched`
        : '— 0 groups matched';
    } else {
      nameEl.textContent = selectedGroup ? `— ${selectedGroup.name}` : '';
    }
  }

  if (!selectedGroup && !isFiltering) {
    list.classList.add('d-none');
    placeholder.classList.remove('d-none');
    emptyState.classList.add('d-none');
    if (countEl) countEl.textContent = '0';
    return;
  }

  placeholder.classList.add('d-none');
  emptyState.classList.add('d-none');

  if (!visibleGroups.length) {
    list.classList.add('d-none');
    emptyState.classList.remove('d-none');
    const emptyLabel = emptyState.querySelector('p');
    if (emptyLabel) {
      emptyLabel.textContent = editorChannelFilter.trim()
        ? `No channels match "${editorChannelFilter.trim()}" across any group`
        : 'No channels in this group';
    }
    if (channelSortable) {
      channelSortable.destroy();
      channelSortable = null;
    }
    return;
  }

  list.classList.remove('d-none');
  list.innerHTML = visibleGroups
    .map((group) => `
      ${isFiltering ? `<div class="editor-filter-group-label">${esc(group.name)} <span class="badge bg-secondary ms-1">${group.channels.length}</span></div>` : ''}
      ${(group.channels || []).map((ch) => renderEditorChannelItem(ch, group)).join('')}
    `)
    .join('');

  list.querySelectorAll('.editor-ch-toggle').forEach((cb) => {
    cb.addEventListener('change', (e) => {
      e.stopPropagation();
      const input = cb as HTMLInputElement;
      const found = findEditorChannel(input.dataset.groupId, input.dataset.chid);
      if (found) { found.channel.enabled = input.checked; editorDirty = true; renderEditorChannels(); }
    });
  });

  list.querySelectorAll('.editor-edit-ch-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const found = findEditorChannel(
        (btn as HTMLElement).dataset.groupId,
        (btn as HTMLElement).dataset.chid,
      );
      if (!found) return;
      (document.getElementById('editChannelNameInput') as HTMLInputElement).value = found.channel.name || '';
      (document.getElementById('editChannelUrlInput')  as HTMLInputElement).value = found.channel.url  || '';
      (document.getElementById('editChannelLogoInput') as HTMLInputElement).value = found.channel.tvg_logo || '';
      (document.getElementById('editChannelIdInput')   as HTMLInputElement).value = found.channel.id;
      new Modal(document.getElementById('editChannelModal')!).show();
    });
  });

  list.querySelectorAll('.editor-delete-ch-btn:not([disabled])').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const found = findEditorChannel(
        (btn as HTMLElement).dataset.groupId,
        (btn as HTMLElement).dataset.chid,
      );
      if (!found?.channel.custom) return;
      found.group.channels = (found.group.channels || []).filter((c) => c.id !== found.channel.id);
      editorDirty = true;
      renderEditorChannels();
    });
  });

  list.querySelectorAll('.editor-move-ch-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const found = findEditorChannel(
        (btn as HTMLElement).dataset.groupId,
        (btn as HTMLElement).dataset.chid,
      );
      if (!found) return;

      const select = document.getElementById('moveChannelTargetSelect') as HTMLSelectElement;
      select.innerHTML = editorGroups
        .filter((g) => g.id !== found.group.id)
        .map((g) => `<option value="${esc(g.id)}">${esc(g.name)}</option>`)
        .join('');

      const info       = document.getElementById('moveChannelInfo');
      const confirmBtn = document.getElementById('confirmMoveChannelBtn');
      if (found.channel.custom) {
        if (info) info.textContent = 'This channel will be removed from the current group and added to the selected group.';
        if (confirmBtn) confirmBtn.innerHTML = '<i class="fas fa-exchange-alt mr-1"></i>Move';
      } else {
        if (info) info.innerHTML = 'The original will remain in this group but be <strong>disabled</strong>. A copy will be added to the selected group.';
        if (confirmBtn) confirmBtn.innerHTML = '<i class="fas fa-copy mr-1"></i>Copy to Group';
      }
      (document.getElementById('moveChannelIdInput') as HTMLInputElement).value = found.channel.id;
      (document.getElementById('moveChannelSourceGroupId') as HTMLInputElement).value = found.group.id;
      new Modal(document.getElementById('moveChannelModal')!).show();
    });
  });

  list.querySelectorAll('.editor-copy-url-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const found = findEditorChannel(
        (btn as HTMLElement).dataset.groupId,
        (btn as HTMLElement).dataset.chid,
      );
      if (!found?.channel.url) return;
      navigator.clipboard.writeText(found.channel.url).then(() => {
        flashButtonIcon(btn, 'fas fa-check');
      }).catch(() => toast('Copy failed', 'danger'));
    });
  });

  if (channelSortable) {
    channelSortable.destroy();
    channelSortable = null;
  }
  if (!isFiltering && selectedGroup) {
    const allChannels = selectedGroup.channels || [];
    channelSortable = new Sortable(list as HTMLElement, {
      handle: '.drag-handle',
      animation: 150,
      ghostClass: 'sortable-ghost',
      chosenClass: 'sortable-chosen',
      onEnd: () => {
        const newOrder = [...list.querySelectorAll('.editor-channel-item')].map(
          (el) => (el as HTMLElement).dataset.chId,
        );
        selectedGroup.channels = newOrder
          .map((id) => allChannels.find((c) => c.id === id))
          .filter((c): c is MergedChannel => !!c);
        editorDirty = true;
      },
    });
  }
}

document.getElementById('editAllPlaylistsBtn')?.addEventListener('click', openAllPlaylistsEditor);

document.getElementById('refreshAllPlaylistsBtn')?.addEventListener('click', async () => {
  const btn = document.getElementById('refreshAllPlaylistsBtn') as HTMLButtonElement;
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i>';
  try {
    const res = await apiFetch('/api/all-playlists/refresh', { method: 'POST' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Refresh failed');
    await loadPlaylists();
    await selectPlaylist('__all__');
    let msg = `Refreshed: ${data.total_channels} channels`;
    if (data.errors?.length) msg += ` (${data.errors.length} error(s))`;
    toast(msg, 'success');
    startHealthPoll();
  } catch (e) {
    toast((e as Error).message, 'danger');
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-sync-alt"></i>';
  }
});

document.getElementById('editorSaveBtn')?.addEventListener('click', async () => {
  const btn = document.getElementById('editorSaveBtn') as HTMLButtonElement;
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Saving...';
  try {
    const res = await apiFetch('/api/all-playlists', {
      method:  'PUT',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ groups: editorGroups }),
    });
    if (!res.ok) {
      const data = await res.json();
      throw new Error(data.detail || 'Save failed');
    }
    editorDirty = false;
    Modal.getInstance(document.getElementById('allPlaylistsEditorModal')!)?.hide();
    toast('All Playlists config saved', 'success');
    await selectPlaylist('__all__');
  } catch (e) {
    toast((e as Error).message, 'danger');
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-save me-1"></i>Save Changes';
  }
});

document.getElementById('editorRefreshAllBtn')?.addEventListener('click', async () => {
  const btn = document.getElementById('editorRefreshAllBtn') as HTMLButtonElement;
  btn.disabled = true;
  btn.innerHTML = '<i class="fas fa-spinner fa-spin me-1"></i>Refreshing...';
  try {
    const res = await apiFetch('/api/all-playlists/refresh', { method: 'POST' });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || 'Refresh failed');
    const res2  = await apiFetch('/api/all-playlists');
    const data2 = await res2.json();
    editorGroups = data2.groups || [];
    if (editorSelectedGroupId && !editorGroups.find((g) => g.id === editorSelectedGroupId)) {
      editorSelectedGroupId = null;
    }
    renderEditorGroups();
    renderEditorChannels();
    editorDirty = false;
    let msg = `Refreshed: ${data.total_channels} channels`;
    if (data.errors?.length) msg += ` (${data.errors.length} error(s))`;
    toast(msg, 'success');
    startHealthPoll();
  } catch (e) {
    toast((e as Error).message, 'danger');
  } finally {
    btn.disabled = false;
    btn.innerHTML = '<i class="fas fa-sync-alt me-1"></i>Refresh All';
  }
});

document.getElementById('editorExportBtn')?.addEventListener('click', async () => {
  const btn = document.getElementById('editorExportBtn') as HTMLButtonElement | null;
  if (!btn) return;
  const exportUrl = btn.dataset.exportUrl
    || new URL('/api/all-playlists/export.m3u', window.location.origin).toString();
  try {
    await navigator.clipboard.writeText(exportUrl);
    flashButtonIcon(btn, 'fas fa-check');
    toast('M3U URL copied', 'success');
  } catch {
    window.prompt('Copy M3U URL', exportUrl);
    toast('Clipboard unavailable; copy the URL manually', 'warning');
  }
});

document.getElementById('editorAddGroupBtn')?.addEventListener('click', () => {
  (document.getElementById('newGroupNameInput') as HTMLInputElement).value = '';
  new Modal(document.getElementById('addGroupModal')!).show();
});

document.getElementById('confirmAddGroupBtn')?.addEventListener('click', () => {
  const name = (document.getElementById('newGroupNameInput') as HTMLInputElement).value.trim();
  if (!name) { toast('Group name is required', 'danger'); return; }
  if (editorGroups.some((g) => g.name === name)) { toast('Group already exists', 'danger'); return; }
  editorGroups.unshift({
    id: 'g_' + Math.random().toString(36).slice(2, 10),
    name,
    enabled: true,
    custom: true,
    channels: [],
  });
  editorDirty = true;
  Modal.getInstance(document.getElementById('addGroupModal')!)?.hide();
  renderEditorGroups();
});

document.getElementById('confirmRenameGroupBtn')?.addEventListener('click', () => {
  const gid     = (document.getElementById('renameGroupIdInput')   as HTMLInputElement).value;
  const newName = (document.getElementById('renameGroupNameInput') as HTMLInputElement).value.trim();
  if (!newName) { toast('Group name is required', 'danger'); return; }
  const g = editorGroups.find((g) => g.id === gid);
  if (!g?.custom) return;
  if (editorGroups.some((og) => og.id !== gid && og.name === newName)) {
    toast('A group with that name already exists', 'danger'); return;
  }
  g.name = newName;
  (g.channels || []).forEach((ch) => { if (ch.custom) ch.group = newName; });
  editorDirty = true;
  Modal.getInstance(document.getElementById('renameGroupModal')!)?.hide();
  renderEditorGroups();
  renderEditorChannels();
});

document.getElementById('renameGroupNameInput')?.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') (document.getElementById('confirmRenameGroupBtn') as HTMLButtonElement)?.click();
});

document.getElementById('editorAddChannelBtn')?.addEventListener('click', () => {
  (document.getElementById('newChannelNameInput') as HTMLInputElement).value = '';
  (document.getElementById('newChannelUrlInput')  as HTMLInputElement).value = '';
  (document.getElementById('newChannelLogoInput') as HTMLInputElement).value = '';
  new Modal(document.getElementById('addChannelModal')!).show();
});

document.getElementById('confirmAddChannelBtn')?.addEventListener('click', () => {
  const name = (document.getElementById('newChannelNameInput') as HTMLInputElement).value.trim();
  const url  = (document.getElementById('newChannelUrlInput')  as HTMLInputElement).value.trim();
  const logo = (document.getElementById('newChannelLogoInput') as HTMLInputElement).value.trim();
  if (!name || !url) { toast('Name and URL are required', 'danger'); return; }
  const group = editorGroups.find((g) => g.id === editorSelectedGroupId);
  if (!group) { toast('No group selected', 'danger'); return; }
  if (!group.channels) group.channels = [];
  group.channels.unshift({
    id: 'cc_' + Math.random().toString(36).slice(2, 10),
    name,
    url,
    tvg_logo: logo,
    group: group.name,
    enabled: true,
    custom: true,
    source_playlist_id: null,
    source_playlist_name: null,
  });
  editorDirty = true;
  Modal.getInstance(document.getElementById('addChannelModal')!)?.hide();
  renderEditorChannels();
});

document.getElementById('confirmMoveChannelBtn')?.addEventListener('click', () => {
  const chid      = (document.getElementById('moveChannelIdInput')      as HTMLInputElement).value;
  const sourceGid = (document.getElementById('moveChannelSourceGroupId') as HTMLInputElement).value;
  const targetGid = (document.getElementById('moveChannelTargetSelect') as HTMLSelectElement).value;
  if (!chid || !targetGid) return;

  const srcGroup = editorGroups.find((g) => g.id === sourceGid);
  const tgtGroup = editorGroups.find((g) => g.id === targetGid);
  if (!srcGroup || !tgtGroup) return;

  const ch = (srcGroup.channels || []).find((c) => c.id === chid);
  if (!ch) return;

  if (ch.custom) {
    srcGroup.channels = srcGroup.channels.filter((c) => c.id !== chid);
    tgtGroup.channels = [...(tgtGroup.channels || []), ch];
  } else {
    const copy: MergedChannel = {
      ...ch,
      id: 'cc_' + Math.random().toString(36).slice(2, 10),
      custom: true,
      group: tgtGroup.name,
      source_playlist_id: null,
      source_playlist_name: null,
      origin_id: ch.id,
    };
    tgtGroup.channels = [...(tgtGroup.channels || []), copy];
    ch.enabled = false;
  }

  editorDirty = true;
  Modal.getInstance(document.getElementById('moveChannelModal')!)?.hide();
  renderEditorGroups();
  renderEditorChannels();
});

document.getElementById('confirmEditChannelBtn')?.addEventListener('click', () => {
  const chId = (document.getElementById('editChannelIdInput')   as HTMLInputElement).value;
  const name = (document.getElementById('editChannelNameInput') as HTMLInputElement).value.trim();
  const url  = (document.getElementById('editChannelUrlInput')  as HTMLInputElement).value.trim();
  const logo = (document.getElementById('editChannelLogoInput') as HTMLInputElement).value.trim();
  if (!name || !url) { toast('Name and URL are required', 'danger'); return; }
  for (const g of editorGroups) {
    const ch = (g.channels || []).find((c) => c.id === chId);
    if (ch && ch.custom) { ch.name = name; ch.url = url; ch.tvg_logo = logo; editorDirty = true; break; }
  }
  Modal.getInstance(document.getElementById('editChannelModal')!)?.hide();
  renderEditorChannels();
});

document.getElementById('editorChannelFilterInput')?.addEventListener('input', (e) => {
  scheduleEditorFilterRender((e.target as HTMLInputElement).value);
});

document.getElementById('editorChannelFilterClearBtn')?.addEventListener('click', () => {
  if (editorFilterRenderTimer) window.clearTimeout(editorFilterRenderTimer);
  editorFilterRenderTimer = null;
  editorChannelFilter = '';
  renderEditorChannels();
});

document.getElementById('allPlaylistsEditorModal')?.addEventListener('hide.bs.modal', (e) => {
  if (editorFilterRenderTimer) {
    window.clearTimeout(editorFilterRenderTimer);
    editorFilterRenderTimer = null;
  }
  if (editorDirty) {
    if (!confirm('You have unsaved changes. Close without saving?')) {
      e.preventDefault();
    }
  }
});

// ── Editor panel resizer ──────────────────────────────────────────────────────
(function () {
  const resizer = document.getElementById('editorResizer') as HTMLElement | null;
  const panel   = document.querySelector('.editor-groups-panel') as HTMLElement | null;
  if (!resizer || !panel) return;

  // Capture non-null refs for the event handlers
  const resizerEl = resizer;
  const panelEl   = panel;

  resizerEl.addEventListener('pointerdown', (e: PointerEvent) => {
    const startX = e.clientX;
    const startW = panelEl.offsetWidth;
    resizerEl.setPointerCapture(e.pointerId);
    resizerEl.classList.add('dragging');
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';

    function onMove(e: PointerEvent): void {
      const w = Math.max(160, Math.min(600, startW + e.clientX - startX));
      panelEl.style.width = w + 'px';
    }
    function onUp(): void {
      resizerEl.classList.remove('dragging');
      document.body.style.cursor = '';
      document.body.style.userSelect = '';
      resizerEl.removeEventListener('pointermove', onMove as EventListener);
      resizerEl.removeEventListener('pointerup', onUp);
    }
    resizerEl.addEventListener('pointermove', onMove as EventListener);
    resizerEl.addEventListener('pointerup', onUp);
    e.preventDefault();
  });
})();
