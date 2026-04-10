import { apiFetch } from './api';

async function initAuth(): Promise<void> {
  try {
    const res = await fetch('/api/auth/status');
    if (!res.ok) return;
    const data = await res.json();
    if (data.auth_required) {
      const btn = document.getElementById('logoutBtn');
      if (btn) btn.classList.remove('d-none');
      try {
        const tr = await fetch('/api/auth/export-token');
        if (tr.ok) {
          const { token } = await tr.json();
          if (token) {
            const exportBtn = document.getElementById('editorExportBtn') as HTMLAnchorElement | null;
            if (exportBtn) {
              exportBtn.href = `/api/all-playlists/export.m3u?token=${encodeURIComponent(token)}`;
            }
          }
        }
      } catch { /* ignore */ }
    }
  } catch { /* ignore */ }
}

document.getElementById('logoutBtn')?.addEventListener('click', async () => {
  await fetch('/api/logout', { method: 'POST' }).catch(() => {});
  window.location.replace('/login');
});

// Suppress unused-import warning — apiFetch is used in other modules
void apiFetch;

initAuth();
