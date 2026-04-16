import { renderChannelCard, bindChannelGrid } from './channel-card';
import { apiFetch } from './api';
import { _healthDot } from './health';
import { setChannelContext } from './player';
import { watchChannel, showChannelContextMenu } from './playlists';
import { settings } from './settings';
import type { RecentChannel, Channel } from './types';
import { toast } from './utils';

let recentCache: RecentChannel[] = [];
let renderToken = 0;

function _normalizeRecent(item: unknown): RecentChannel | null {
  if (!item || typeof item !== 'object') return null;
  const recent = item as Partial<RecentChannel>;
  if (!recent.url || typeof recent.url !== 'string') return null;
  return {
    id: typeof recent.id === 'string' && recent.id ? recent.id : recent.url,
    name: typeof recent.name === 'string' && recent.name ? recent.name : recent.url,
    url: recent.url,
    tvg_logo: typeof recent.tvg_logo === 'string' ? recent.tvg_logo : '',
    group: typeof recent.group === 'string' ? recent.group : '',
    watched_at: typeof recent.watched_at === 'number' ? recent.watched_at : Date.now(),
  };
}

function _recentPayload(ch: Channel & { tvg_logo?: string }): Record<string, string> {
  return {
    name: ch.name || ch.url,
    url: ch.url,
    tvg_logo: ch.tvg_logo || '',
    group: ch.group || '',
  };
}

function _cacheRecents(list: RecentChannel[]): RecentChannel[] {
  recentCache = list.slice(0, settings.recentLimit);
  return recentCache;
}

async function _fetchServerRecents(): Promise<RecentChannel[]> {
  const response = await apiFetch('/api/recents');
  const data = await response.json().catch(() => []);
  if (!response.ok) {
    throw new Error((data as { detail?: string }).detail || 'Failed to load recents');
  }
  return Array.isArray(data)
    ? data
      .map((item) => _normalizeRecent(item))
      .filter((item): item is RecentChannel => !!item)
      .slice(0, settings.recentLimit)
    : [];
}

async function _postRecent(ch: Channel & { tvg_logo?: string }): Promise<RecentChannel> {
  const response = await apiFetch('/api/recents', {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify(_recentPayload(ch)),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error((data as { detail?: string }).detail || 'Failed to save recent');
  }
  return _normalizeRecent(data) || {
    id: ch.url,
    name: ch.name || ch.url,
    url: ch.url,
    tvg_logo: ch.tvg_logo || '',
    group: ch.group || '',
    watched_at: Date.now(),
  };
}

async function _deleteRecent(id: string): Promise<void> {
  const response = await apiFetch(`/api/recents/${encodeURIComponent(id)}`, { method: 'DELETE' });
  if (!response.ok) {
    const data = await response.json().catch(() => ({}));
    throw new Error((data as { detail?: string }).detail || 'Failed to delete recent');
  }
}

async function fetchRecents(): Promise<RecentChannel[]> {
  try {
    return _cacheRecents(await _fetchServerRecents());
  } catch {
    return recentCache.slice(0, settings.recentLimit);
  }
}

async function persistRecent(ch: Channel & { tvg_logo?: string }): Promise<void> {
  try {
    const recent = await _postRecent(ch);
    _cacheRecents([recent, ...recentCache.filter((item) => item.id !== recent.id)]);
  } catch (error) {
    toast((error as Error).message, 'warning');
  }
  renderRecentChannels();
}

async function removeRecent(id: string): Promise<void> {
  try {
    await _deleteRecent(id);
    _cacheRecents(recentCache.filter((item) => item.id !== id));
  } catch (error) {
    toast((error as Error).message, 'warning');
  }
  renderRecentChannels();
}

export function addToRecents(ch: Channel & { tvg_logo?: string }): void {
  void persistRecent(ch);
}

export function renderRecentChannels(): void {
  const token = ++renderToken;
  void (async () => {
    const recents = await fetchRecents();
    if (token !== renderToken) return;

    const grid    = document.getElementById('recentChannelGrid');
    const empty   = document.getElementById('recentEmptyState');
    const badge   = document.getElementById('recentCountBadge');
    if (badge) badge.textContent = String(recents.length);
    if (!recents.length) {
      if (grid) grid.innerHTML = '';
      empty?.classList.remove('d-none');
      return;
    }

    empty?.classList.add('d-none');
    if (!grid) return;

    grid.innerHTML = recents
      .map((ch, i) => renderChannelCard(ch as unknown as Channel, i, {
        hideHealthDot: true,
        topLeftContent: _healthDot(ch.url),
        topRightContent: `
          <button class="recent-remove-btn" data-recent-id="${ch.id}" title="Remove from history" aria-label="Remove ${ch.name}">
            <i class="fas fa-times"></i>
          </button>`,
      }))
      .join('');

    bindChannelGrid(grid, recents as unknown as Channel[], {
      onWatch: (ch, idx) => {
        addToRecents(ch as Channel & { tvg_logo?: string });
        setChannelContext(recents as unknown as Channel[], idx);
        watchChannel(ch);
      },
      onDownload: (ch, btn) => {
        (window as unknown as Record<string, Function>).downloadChannel?.(ch, btn);
      },
      onContextMenu: (ch, x, y) => {
        showChannelContextMenu(ch as unknown as import('./types').MergedChannel, x, y);
      },
    });

    grid.querySelectorAll<HTMLElement>('.recent-remove-btn').forEach((btn) => {
      btn.addEventListener('click', (event) => {
        event.stopPropagation();
        const id = btn.dataset.recentId;
        if (!id) return;
        void removeRecent(id);
      });
    });
  })();
}

document.getElementById('clearRecentBtn')?.addEventListener('click', () => {
  void (async () => {
    const recents = await fetchRecents();
    try {
      for (const recent of recents) {
        await _deleteRecent(recent.id);
      }
      _cacheRecents([]);
    } catch (error) {
      toast((error as Error).message, 'warning');
    }
    renderRecentChannels();
  })();
});
