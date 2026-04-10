import { esc } from './utils';
import { _healthDot } from './health';
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

function _recentChannelCard(ch: RecentChannel): string {
  return `
    <div class="channel-card" id="rechan-${encodeURIComponent(ch.url).slice(0, 32)}">
      ${_healthDot(ch.url)}
      <div class="channel-logo-wrap">
        ${ch.tvg_logo
          ? `<img src="${esc(ch.tvg_logo)}" class="channel-logo" alt=""
               onerror="this.style.display='none';this.nextElementSibling.style.display='flex'" />
             <div class="channel-logo-fallback" style="display:none"><i class="fas fa-tv"></i></div>`
          : `<div class="channel-logo-fallback"><i class="fas fa-tv"></i></div>`}
      </div>
      <div class="channel-name" title="${esc(ch.name)}">${esc(ch.name || ch.url)}</div>
      ${ch.group ? `<div class="channel-group">${esc(ch.group)}</div>` : ''}
      <div class="channel-actions">
        <button class="ch-action-btn ch-action-btn-dl" title="Download" data-re-dl-url="${esc(ch.url)}" data-re-ch='${JSON.stringify({ name: ch.name, url: ch.url, tvg_logo: ch.tvg_logo || '', group: ch.group || '' })}'>
          <i class="fas fa-download"></i>
        </button>
        <button class="ch-action-btn ch-action-btn-watch" title="Watch" data-re-watch-url="${esc(ch.url)}" data-re-ch='${JSON.stringify({ name: ch.name, url: ch.url, tvg_logo: ch.tvg_logo || '', group: ch.group || '' })}'>
          <i class="fas fa-play"></i>
        </button>
      </div>
    </div>`;
}

function _bindRecentGridEvents(container: HTMLElement): void {
  container.querySelectorAll('[data-re-dl-url]').forEach((btn) => {
    btn.addEventListener('click', () => {
      try {
        const ch = JSON.parse((btn as HTMLElement).dataset.reCh || '{}');
        // downloadChannel is defined in playlists.ts and exposed on window
        (window as unknown as Record<string, Function>).downloadChannel?.(ch, btn);
      } catch { /* ignore */ }
    });
  });
  container.querySelectorAll('[data-re-watch-url]').forEach((btn) => {
    btn.addEventListener('click', () => {
      try {
        const ch = JSON.parse((btn as HTMLElement).dataset.reCh || '{}');
        addToRecents(ch);
        // watchChannel is defined in playlists.ts
        (window as unknown as Record<string, Function>).watchChannel?.(ch);
      } catch { /* ignore */ }
    });
  });
}

export function renderRecentChannels(): void {
  const recents = _loadRecents();
  const grid = document.getElementById('recentChannelGrid');
  const empty = document.getElementById('recentEmptyState');
  const badge = document.getElementById('recentCountBadge');
  if (badge) badge.textContent = String(recents.length);
  if (!recents.length) {
    if (grid) grid.innerHTML = '';
    empty?.classList.remove('d-none');
    return;
  }
  empty?.classList.add('d-none');
  if (grid) {
    grid.innerHTML = recents.map((ch) => _recentChannelCard(ch)).join('');
    _bindRecentGridEvents(grid);
  }
}

document.getElementById('clearRecentBtn')?.addEventListener('click', () => {
  _saveRecents([]);
  renderRecentChannels();
});
