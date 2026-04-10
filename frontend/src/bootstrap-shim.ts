/* bootstrap-shim.ts — minimal Bootstrap JS API subset for TypeScript */

interface ModalElement extends HTMLElement {
  _bsModal?: Modal;
}

export class Modal {
  private el: ModalElement;
  private _static: boolean;
  private _onKeydown: (e: KeyboardEvent) => void;
  private _onBackdrop: (e: MouseEvent) => void;

  constructor(el: HTMLElement | string | null) {
    if (typeof el === 'string') el = document.querySelector<HTMLElement>(el);
    if (!el) throw new Error('Modal: element not found');
    this.el = el as ModalElement;
    this.el._bsModal = this;
    this._static = el.dataset.bsBackdrop === 'static';
    this._onKeydown  = (e: KeyboardEvent) => { if (e.key === 'Escape' && !this._static) this.hide(); };
    this._onBackdrop = (e: MouseEvent) => { if (e.target === this.el && !this._static) this.hide(); };
  }

  show(): void {
    this.el.classList.remove('hidden');
    this.el.classList.add('show');
    document.body.style.overflow = 'hidden';
    document.addEventListener('keydown', this._onKeydown);
    this.el.addEventListener('click', this._onBackdrop as EventListener);
    setTimeout(() => this.el.dispatchEvent(new CustomEvent('shown.bs.modal', { bubbles: true })), 0);
  }

  hide(): void {
    this.el.classList.add('hidden');
    this.el.classList.remove('show');
    document.body.style.overflow = '';
    document.removeEventListener('keydown', this._onKeydown);
    this.el.removeEventListener('click', this._onBackdrop as EventListener);
    this.el.dispatchEvent(new CustomEvent('hidden.bs.modal', { bubbles: true }));
  }

  toggle(): void {
    this.el.classList.contains('hidden') ? this.show() : this.hide();
  }

  static getInstance(el: HTMLElement | string | null): Modal | null {
    if (typeof el === 'string') el = document.querySelector<HTMLElement>(el);
    return el ? ((el as ModalElement)._bsModal ?? null) : null;
  }

  static getOrCreateInstance(el: HTMLElement | string | null): Modal | null {
    if (typeof el === 'string') el = document.querySelector<HTMLElement>(el);
    return el ? ((el as ModalElement)._bsModal ?? new Modal(el)) : null;
  }
}

interface ToastElement extends HTMLElement {
  dataset: DOMStringMap;
}

export class Toast {
  private el: ToastElement;
  private _delay: number;

  constructor(el: HTMLElement | string) {
    if (typeof el === 'string') el = document.querySelector<HTMLElement>(el) as HTMLElement;
    this.el = el as ToastElement;
    this._delay = parseInt(el.dataset.bsDelay || '3500', 10);
  }

  show(): void {
    this.el.classList.remove('hidden');
    setTimeout(() => {
      this.el.classList.add('hidden');
      this.el.dispatchEvent(new CustomEvent('hidden.bs.toast', { bubbles: true }));
    }, this._delay);
  }
}

// ── DOMContentLoaded: tabs + dismiss buttons ──────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  function activateTab(btn: HTMLElement): void {
    const targetSel = btn.dataset.bsTarget;
    if (!targetSel) return;
    const targetPane = document.querySelector<HTMLElement>(targetSel);
    if (!targetPane) return;

    const nav = btn.closest('.tab-nav');
    if (nav) {
      nav.querySelectorAll("[data-bs-toggle='tab']").forEach((b) => b.classList.remove('tab-active'));
    }
    btn.classList.add('tab-active');

    const paneParent = targetPane.parentElement;
    if (paneParent) {
      paneParent.querySelectorAll('.tab-pane').forEach((p) => p.classList.remove('tab-pane-active'));
    }
    targetPane.classList.add('tab-pane-active');
  }

  document.addEventListener('click', (e) => {
    const btn = (e.target as HTMLElement).closest<HTMLElement>("[data-bs-toggle='tab']");
    if (btn) activateTab(btn);
  });

  document.addEventListener('click', (e) => {
    const btn = (e.target as HTMLElement).closest<HTMLElement>("[data-bs-dismiss='modal']");
    if (btn) {
      const modalEl = btn.closest<HTMLElement>('.tw-modal');
      if (modalEl) {
        const inst = Modal.getInstance(modalEl) ?? new Modal(modalEl);
        inst.hide();
      }
    }
  });
});
