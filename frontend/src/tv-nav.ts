/**
 * tv-nav.ts — Arrow-key channel navigation for TV remote control.
 *
 * Rules:
 *  • Arrow keys ALWAYS navigate the currently visible channel grid only.
 *  • No zone model — bottom-nav and group-bar have no D-pad routing.
 *  • Enter on a focused card → watchChannel + setChannelContext.
 *  • Virtual cursor: arrows work even when no card is focused yet.
 */

import { setChannelContext } from './player';
import { watchChannel } from './playlists';
import { addToRecents } from './recents';

// ── Virtual cursor ────────────────────────────────────────────────────────────

let _navIdx = 0;

// ── Helpers ───────────────────────────────────────────────────────────────────

function channelCards(): HTMLElement[] {
  const recentsSection = document.getElementById('favoritesSection');
  if (recentsSection && !recentsSection.classList.contains('d-none')) {
    return Array.from(document.querySelectorAll<HTMLElement>('#recentChannelGrid .channel-card'));
  }
  return Array.from(document.querySelectorAll<HTMLElement>('#channelGrid .channel-card'));
}

function gridColumns(): number {
  const recentsSection = document.getElementById('favoritesSection');
  const gridId = (recentsSection && !recentsSection.classList.contains('d-none'))
    ? 'recentChannelGrid' : 'channelGrid';
  const grid = document.getElementById(gridId);
  if (!grid) return 1;
  return getComputedStyle(grid).gridTemplateColumns.split(' ').length || 1;
}

function selectCard(idx: number, cards: HTMLElement[]): void {
  if (!cards.length) return;
  _navIdx = Math.max(0, Math.min(idx, cards.length - 1));
  const card = cards[_navIdx];
  card.focus({ preventScroll: false });
  card.scrollIntoView({ block: 'nearest', inline: 'nearest' });
}

// ── _ch attachment via MutationObserver ───────────────────────────────────────

function attachChData(): void {
  document
    .querySelectorAll<HTMLElement>('#channelGrid .channel-card, #recentChannelGrid .channel-card')
    .forEach((card) => {
      if ((card as HTMLElement & { _ch?: unknown })._ch) return;
      const json = card.dataset.chJson;
      if (json) {
        try { (card as HTMLElement & { _ch?: unknown })._ch = JSON.parse(json); }
        catch { /* ignore */ }
      }
    });
}

const gridObserver = new MutationObserver(() => { attachChData(); _navIdx = 0; });
['channelGrid', 'recentChannelGrid'].forEach((id) => {
  const el = document.getElementById(id);
  if (el) gridObserver.observe(el, { childList: true });
});
attachChData();

// ── Global keydown handler (capture phase) ────────────────────────────────────

const ARROW_KEYS = new Set(['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown']);

document.addEventListener('keydown', (e: KeyboardEvent) => {
  const tag = (e.target as HTMLElement)?.tagName;
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;

  // Player handles its own keys while open
  if (document.getElementById('previewModal')?.classList.contains('show')) return;

  const isArrow  = ARROW_KEYS.has(e.key);
  const isEnter  = e.key === 'Enter';
  const isEscape = e.key === 'Escape';

  if (!isArrow && !isEnter && !isEscape) return;

  // Escape: close Add Stream modal when open
  if (isEscape) {
    const addStreamModal = document.getElementById('addStreamModal');
    if (addStreamModal?.classList.contains('show')) {
      (addStreamModal.querySelector('[data-bs-dismiss="modal"]') as HTMLButtonElement | null)?.click();
      e.preventDefault();
    }
    return;
  }

  const cards = channelCards();
  if (!cards.length) return;

  // Resolve effective index: prefer focused card, fall back to virtual cursor
  const focusedIdx = cards.indexOf(document.activeElement as HTMLElement);
  const idx = focusedIdx >= 0 ? focusedIdx : Math.min(_navIdx, cards.length - 1);

  if (isEnter) {
    if (focusedIdx < 0) {
      selectCard(idx, cards);
    } else {
      const ch = (cards[focusedIdx] as HTMLElement & { _ch?: unknown })._ch;
      if (ch) {
        const channelList = cards
          .map((c) => (c as HTMLElement & { _ch?: unknown })._ch)
          .filter(Boolean) as Parameters<typeof setChannelContext>[0];
        addToRecents(ch as Parameters<typeof addToRecents>[0]);
        setChannelContext(channelList, focusedIdx);
        watchChannel(ch as Parameters<typeof watchChannel>[0]);
      }
    }
    e.preventDefault();
    return;
  }

  // Arrow navigation
  const cols = gridColumns();
  let next = idx;
  if (e.key === 'ArrowRight') next = Math.min(idx + 1, cards.length - 1);
  if (e.key === 'ArrowLeft')  next = Math.max(idx - 1, 0);
  if (e.key === 'ArrowDown')  next = Math.min(idx + cols, cards.length - 1);
  if (e.key === 'ArrowUp')    next = Math.max(idx - cols, 0);

  selectCard(next, cards);
  e.preventDefault();
}, true);
