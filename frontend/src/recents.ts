import { renderChannelCard, bindChannelGrid } from './channel-card';
import type { RecentChannel, Channel } from './types';

export const RECENT_KEY = 'mn_recent_channels';
const MAX_RECENT = 20;

function _loadRecents(): RecentChannel[] {
  try { return JSON.parse(localStorage.getItem(RECENT_KEY) || '[]'); } catch { return []; }
}

function _saveRecents(list: RecentChannel[]): void {
  try { localStorage.setItem(RECENT_KEY, JSON.stringify(list)); } catch { /* ignore */ }
}

export function addToRecents(ch: Channel & { tvg_logo?: string }): void {
  const list = _loadRecents().filter((r) => r.url !== ch.url);
  list.unshift({
    name: ch.name,
    url: ch.url,
    tvg_logo: ch.tvg_logo || '',
    group: ch.group || '',
    watched_at: Date.now(),
  });
  if (list.length > MAX_RECENT) list.length = MAX_RECENT;
  _saveRecents(list);
}

export function renderRecentChannels(): void {
  const recents = _loadRecents();
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
  if (grid) {
    grid.innerHTML = recents
      .map((ch, i) => renderChannelCard(ch as unknown as Channel, i))
      .join('');
    bindChannelGrid(grid, recents as unknown as Channel[], {
      onWatch: (ch) => {
        addToRecents(ch as unknown as RecentChannel & { tvg_logo?: string });
        (window as unknown as Record<string, Function>).watchChannel?.(ch);
      },
      onDownload: (ch, btn) => {
        (window as unknown as Record<string, Function>).downloadChannel?.(ch, btn);
      },
    });
  }
}

document.getElementById('clearRecentBtn')?.addEventListener('click', () => {
  _saveRecents([]);
  renderRecentChannels();
});
