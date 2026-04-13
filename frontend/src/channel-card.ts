/**
 * channel-card.ts — Shared channel card rendering and event binding.
 *
 * Interaction contract:
 *  • Mouse click (card body or play button) → watch WITHOUT auto-fullscreen
 *  • Enter key on a focused card            → handled by tv-nav.ts WITH auto-fullscreen
 */

import { esc } from './utils';
import { _healthDot } from './health';
import type { Channel } from './types';

export interface ChannelCardOptions {
  /** Show the playlist_name tag (merged / all-playlists view) */
  showPlaylistTag?: boolean;
}

export type OnWatchFn       = (ch: Channel, idx: number) => void;
export type OnDownloadFn    = (ch: Channel, btn: HTMLElement, idx: number) => void;
export type OnContextMenuFn = (ch: Channel, x: number, y: number) => void;

export interface BindOptions {
  onWatch:        OnWatchFn;
  onDownload:     OnDownloadFn;
  onContextMenu?: OnContextMenuFn;
}

/** Render a single channel card as an HTML string. */
export function renderChannelCard(
  ch: Channel & { id?: string; playlist_name?: string },
  i: number,
  opts: ChannelCardOptions = {},
): string {
  const chJson = esc(JSON.stringify(ch));
  const logo = ch.tvg_logo
    ? `<img src="${esc(ch.tvg_logo)}" class="channel-logo" alt=""
           onerror="this.style.display='none';this.nextElementSibling.style.display='flex'" />
       <div class="channel-logo-fallback" style="display:none"><i class="fas fa-tv"></i></div>`
    : `<div class="channel-logo-fallback"><i class="fas fa-tv"></i></div>`;

  return `
    <div class="channel-card" id="channel-${ch.id || i}"
         tabindex="0" role="button"
         aria-label="${esc(ch.name || ch.url)}"
         data-ch-json="${chJson}">
      ${_healthDot(ch.url)}
      <div class="channel-logo-wrap">${logo}</div>
      <div class="channel-name" title="${esc(ch.name)}">${esc(ch.name || ch.url)}</div>
      ${ch.group ? `<div class="channel-group">${esc(ch.group)}</div>` : ''}
      ${opts.showPlaylistTag && ch.playlist_name
        ? `<div class="channel-playlist-tag" title="${esc(ch.playlist_name)}">${esc(ch.playlist_name)}</div>`
        : ''}
      <div class="channel-actions">
        <button class="ch-action-btn ch-action-btn-dl channel-dl-btn" data-ch-idx="${i}" title="Download">
          <i class="fas fa-download"></i>
        </button>
        <button class="ch-action-btn ch-action-btn-watch channel-watch-btn" data-ch-idx="${i}" title="Watch">
          <i class="fas fa-play"></i>
        </button>
      </div>
    </div>`;
}

/**
 * Attach all event handlers to channel cards inside `grid`.
 * Enter is NOT handled here — tv-nav.ts handles it globally with auto-fullscreen.
 */
export function bindChannelGrid(
  grid: HTMLElement,
  channels: Channel[],
  opts: BindOptions,
): void {
  grid.querySelectorAll('.channel-dl-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const idx = parseInt((btn as HTMLElement).dataset.chIdx || '0', 10);
      opts.onDownload(channels[idx], btn as HTMLElement, idx);
    });
  });

  grid.querySelectorAll('.channel-watch-btn').forEach((btn) => {
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      const idx = parseInt((btn as HTMLElement).dataset.chIdx || '0', 10);
      opts.onWatch(channels[idx], idx);
    });
  });

  let _lpTimer: ReturnType<typeof setTimeout> | null = null;

  grid.querySelectorAll<HTMLElement>('.channel-card').forEach((card, i) => {
    const ch = channels[i];

    // Card body click (not action buttons) → watch WITHOUT auto-fullscreen
    card.addEventListener('click', (e) => {
      if ((e.target as Element).closest('.channel-actions')) return;
      opts.onWatch(ch, i);
    });

    if (opts.onContextMenu) {
      card.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        const me = e as MouseEvent;
        opts.onContextMenu!(ch, me.clientX, me.clientY);
      });
      card.addEventListener('touchstart', (e) => {
        const te = e as TouchEvent;
        _lpTimer = setTimeout(() => {
          _lpTimer = null;
          const touch = te.touches[0];
          opts.onContextMenu!(ch, touch.clientX, touch.clientY);
        }, 500);
      }, { passive: true });
      card.addEventListener('touchend',  () => { if (_lpTimer) { clearTimeout(_lpTimer); _lpTimer = null; } });
      card.addEventListener('touchmove', () => { if (_lpTimer) { clearTimeout(_lpTimer); _lpTimer = null; } });
    }
  });
}
