/**
 * tv-nav.ts — D-pad / keyboard spatial navigation for TV remote control.
 *
 * Zone model:
 *   1. Bottom nav  → left/right between .tv-nav-btn  (wraps)
 *   2. Group bar   → left/right between .channel-group-item
 *   3. Channel grid → 2-D arrow navigation
 *   Cross-zone:  Down from group bar → first card
 *                Up from first grid row → group bar
 *                Escape → close player modal → channels section
 */

import { setNextOpenAutoFullscreen } from './player';
import { watchChannel } from './playlists';
import { addToRecents } from './recents';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function focusable(el: Element | null): el is HTMLElement {
  return el instanceof HTMLElement && !el.hasAttribute('disabled');
}

function focusSafe(el: Element | null): boolean {
  if (focusable(el)) {
    el.focus({ preventScroll: false });
    el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
    return true;
  }
  return false;
}

function bottomNavButtons(): HTMLElement[] {
  return Array.from(
    document.querySelectorAll<HTMLElement>('#tvBottomNav .tv-nav-btn'),
  );
}

function groupBarItems(): HTMLElement[] {
  return Array.from(
    document.querySelectorAll<HTMLElement>('#groupList .channel-group-item'),
  );
}

function channelCards(): HTMLElement[] {
  return Array.from(
    document.querySelectorAll<HTMLElement>('#channelGrid .channel-card'),
  );
}

/** Return number of CSS grid columns for the channel grid */
function gridColumns(): number {
  const grid = document.getElementById('channelGrid');
  if (!grid) return 1;
  const cols = getComputedStyle(grid).gridTemplateColumns.split(' ');
  return cols.length || 1;
}

// ─────────────────────────────────────────────────────────────────────────────
// Zone detection
// ─────────────────────────────────────────────────────────────────────────────

type Zone = 'bottom-nav' | 'group-bar' | 'channel-grid' | 'other';

function detectZone(el: Element | null): Zone {
  if (!el) return 'other';
  if (el.closest('#tvBottomNav'))  return 'bottom-nav';
  if (el.closest('#groupList'))    return 'group-bar';
  if (el.closest('#channelGrid'))  return 'channel-grid';
  return 'other';
}

// ─────────────────────────────────────────────────────────────────────────────
// Navigation handlers
// ─────────────────────────────────────────────────────────────────────────────

function navBottomNav(el: HTMLElement, key: string): boolean {
  const btns = bottomNavButtons();
  const idx  = btns.indexOf(el);
  if (idx < 0) return false;

  if (key === 'ArrowLeft')  { focusSafe(btns[(idx - 1 + btns.length) % btns.length]); return true; }
  if (key === 'ArrowRight') { focusSafe(btns[(idx + 1) % btns.length]); return true; }
  if (key === 'ArrowUp') {
    // Move up into channel grid if visible, else group bar
    const groups = groupBarItems();
    if (groups.length) { focusSafe(groups[0]); return true; }
    const cards = channelCards();
    if (cards.length) { focusSafe(cards[0]); return true; }
  }
  return false;
}

function navGroupBar(el: HTMLElement, key: string): boolean {
  const items = groupBarItems();
  const idx   = items.indexOf(el);
  if (idx < 0) return false;

  if (key === 'ArrowLeft')  { focusSafe(items[Math.max(0, idx - 1)]); return true; }
  if (key === 'ArrowRight') { focusSafe(items[Math.min(items.length - 1, idx + 1)]); return true; }
  if (key === 'ArrowDown') {
    const cards = channelCards();
    if (cards.length) { focusSafe(cards[0]); return true; }
  }
  if (key === 'ArrowUp') {
    const btns = bottomNavButtons();
    if (btns.length) { focusSafe(btns[0]); return true; }
  }
  return false;
}

function navChannelGrid(el: HTMLElement, key: string): boolean {
  const cards = channelCards();
  const idx   = cards.indexOf(el);
  if (idx < 0) return false;

  const cols = gridColumns();

  if (key === 'ArrowRight') {
    // Don't wrap past end of visual row
    if ((idx + 1) % cols !== 0 && idx + 1 < cards.length) {
      focusSafe(cards[idx + 1]); return true;
    }
  }
  if (key === 'ArrowLeft') {
    if (idx % cols !== 0 && idx - 1 >= 0) {
      focusSafe(cards[idx - 1]); return true;
    }
  }
  if (key === 'ArrowDown') {
    if (idx + cols < cards.length) { focusSafe(cards[idx + cols]); return true; }
  }
  if (key === 'ArrowUp') {
    if (idx - cols >= 0) { focusSafe(cards[idx - cols]); return true; }
    // First row → go to group bar
    const groups = groupBarItems();
    if (groups.length) { focusSafe(groups[0]); return true; }
    const btns = bottomNavButtons();
    if (btns.length) { focusSafe(btns[0]); return true; }
    return true;
  }
  if (key === 'Enter' || key === ' ') {
    // Trigger watch with auto-fullscreen
    const ch = (el as HTMLElement & { _ch?: unknown })._ch;
    if (ch) {
      addToRecents(ch as Parameters<typeof addToRecents>[0]);
      setNextOpenAutoFullscreen(true);
      watchChannel(ch as Parameters<typeof watchChannel>[0]);
    } else {
      // Fallback: simulate click on the card body
      el.click();
    }
    return true;
  }
  return false;
}

// ─────────────────────────────────────────────────────────────────────────────
// Global keydown listener
// ─────────────────────────────────────────────────────────────────────────────

const NAV_KEYS = new Set([
  'ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Escape',
]);

document.addEventListener('keydown', (e: KeyboardEvent) => {
  // Skip if typing in an input/textarea
  const tag = (e.target as HTMLElement)?.tagName;
  if (tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT') return;

  if (!NAV_KEYS.has(e.key)) return;

  // When the player modal is visible, let player.ts handle all navigation keys
  const previewModalEl = document.getElementById('previewModal');
  if (previewModalEl?.classList.contains('show')) return;

  const active = document.activeElement as HTMLElement | null;
  const zone   = detectZone(active);

  // Escape: go back to channels (or close URL section)
  if (e.key === 'Escape') {
    // If in URL section, go back to channels
    const urlSection = document.getElementById('urlSettingsSection');
    if (urlSection && !urlSection.classList.contains('d-none')) {
      document.getElementById('playlist-tab')?.click();
      e.preventDefault();
      return;
    }
    return;
  }

  let handled = false;
  if (zone === 'bottom-nav' && active)  handled = navBottomNav(active, e.key);
  if (zone === 'group-bar'  && active)  handled = navGroupBar(active, e.key);
  if (zone === 'channel-grid' && active) handled = navChannelGrid(active, e.key);

  // If nothing has focus yet and user presses Down/Right, focus first card
  if (!handled && zone === 'other') {
    if (e.key === 'ArrowDown' || e.key === 'ArrowRight') {
      const cards = channelCards();
      if (cards.length) { focusSafe(cards[0]); handled = true; }
    }
  }

  if (handled) e.preventDefault();
}, true);

// ─────────────────────────────────────────────────────────────────────────────
// Attach _ch data to cards after grid renders (MutationObserver)
// ─────────────────────────────────────────────────────────────────────────────
// Note: channel data is attached by playlists.ts via data-ch-json attribute.
// We read it here so Enter key can trigger watch without needing a click.

function attachChData(): void {
  document.querySelectorAll<HTMLElement>('#channelGrid .channel-card').forEach((card) => {
    if ((card as HTMLElement & { _ch?: unknown })._ch) return; // already set
    const json = card.dataset.chJson;
    if (json) {
      try {
        (card as HTMLElement & { _ch?: unknown })._ch = JSON.parse(json);
      } catch { /* ignore */ }
    }
  });
}

const gridObserver = new MutationObserver(attachChData);
const grid = document.getElementById('channelGrid');
if (grid) {
  gridObserver.observe(grid, { childList: true });
}
attachChData();
