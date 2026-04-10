export function esc(str: unknown): string {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

export function formatBytes(bytes: number | null | undefined): string {
  if (!bytes) return '0 B';
  const k = 1024;
  const units = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return (bytes / Math.pow(k, i)).toFixed(1) + ' ' + units[i];
}

export function formatDuration(sec: number): string {
  if (!sec) return '--';
  const m = Math.floor(sec / 60);
  const s = Math.round(sec % 60);
  return `${m}:${s.toString().padStart(2, '0')}`;
}

export function toast(msg: string, type: 'success' | 'danger' | 'info' | 'warning' = 'success'): void {
  const id = 't' + Date.now();
  const typeClass =
    { success: 'toast-success', danger: 'toast-danger', info: 'toast-info', warning: 'toast-warning' }[type] ||
    'toast-success';
  const html = `<div id="${id}" class="tw-toast ${typeClass}" role="alert">
    <span>${esc(msg)}</span>
    <button class="tw-toast-close" onclick="this.parentElement.remove()">✕</button>
  </div>`;
  const container = document.getElementById('toastContainer');
  if (!container) return;
  container.insertAdjacentHTML('beforeend', html);
  const el = document.getElementById(id);
  if (el) {
    setTimeout(() => {
      el.style.opacity = '0';
      setTimeout(() => el.remove(), 300);
    }, 3500);
  }
}
