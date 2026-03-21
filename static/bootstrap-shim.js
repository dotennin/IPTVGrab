/* bootstrap-shim.js — minimal Bootstrap JS API subset for app.js compatibility */
(function () {
  "use strict";

  /* ── Modal ──────────────────────────────────────────────────────────────── */
  class Modal {
    constructor(el) {
      if (typeof el === "string") el = document.querySelector(el);
      this.el = el;
      el._bsModal = this;
      this._static = el.dataset.bsBackdrop === "static";
      this._onKeydown = (e) => { if (e.key === "Escape" && !this._static) this.hide(); };
      this._onBackdrop = (e) => { if (e.target === this.el && !this._static) this.hide(); };
    }

    show() {
      this.el.classList.remove("hidden");
      this.el.classList.add("show");
      document.body.style.overflow = "hidden";
      document.addEventListener("keydown", this._onKeydown);
      this.el.addEventListener("click", this._onBackdrop);
      // Dispatch after a microtask so listeners added synchronously after .show() fire correctly
      setTimeout(() => this.el.dispatchEvent(new CustomEvent("shown.bs.modal", { bubbles: true })), 0);
    }

    hide() {
      this.el.classList.add("hidden");
      this.el.classList.remove("show");
      document.body.style.overflow = "";
      document.removeEventListener("keydown", this._onKeydown);
      this.el.removeEventListener("click", this._onBackdrop);
      this.el.dispatchEvent(new CustomEvent("hidden.bs.modal", { bubbles: true }));
    }

    toggle() {
      this.el.classList.contains("hidden") ? this.show() : this.hide();
    }

    static getInstance(el) {
      if (typeof el === "string") el = document.querySelector(el);
      return el ? el._bsModal || null : null;
    }

    static getOrCreateInstance(el) {
      if (typeof el === "string") el = document.querySelector(el);
      return el ? (el._bsModal || new Modal(el)) : null;
    }
  }

  /* ── Toast ──────────────────────────────────────────────────────────────── */
  class Toast {
    constructor(el) {
      if (typeof el === "string") el = document.querySelector(el);
      this.el = el;
      this._delay = parseInt(el.dataset.bsDelay || "3500", 10);
    }

    show() {
      this.el.classList.remove("hidden");
      setTimeout(() => {
        this.el.classList.add("hidden");
        this.el.dispatchEvent(new CustomEvent("hidden.bs.toast", { bubbles: true }));
      }, this._delay);
    }
  }

  /* ── DOMContentLoaded: tabs + dismiss buttons ───────────────────────────── */
  document.addEventListener("DOMContentLoaded", () => {
    /* Tab system */
    function activateTab(btn) {
      const targetSel = btn.dataset.bsTarget;
      if (!targetSel) return;
      const targetPane = document.querySelector(targetSel);
      if (!targetPane) return;

      // Deactivate sibling tab buttons (same parent nav)
      const nav = btn.closest(".tab-nav");
      if (nav) {
        nav.querySelectorAll("[data-bs-toggle='tab']").forEach((b) => b.classList.remove("tab-active"));
      }
      btn.classList.add("tab-active");

      // Deactivate sibling panes (same parent)
      const paneParent = targetPane.parentElement;
      if (paneParent) {
        paneParent.querySelectorAll(".tab-pane").forEach((p) => p.classList.remove("tab-pane-active"));
      }
      targetPane.classList.add("tab-pane-active");
    }

    document.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-bs-toggle='tab']");
      if (btn) activateTab(btn);
    });

    /* Dismiss buttons */
    document.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-bs-dismiss='modal']");
      if (btn) {
        const modalEl = btn.closest(".tw-modal");
        if (modalEl) {
          const inst = Modal.getInstance(modalEl) || new Modal(modalEl);
          inst.hide();
        }
      }
    });
  });

  /* ── Expose ──────────────────────────────────────────────────────────────── */
  window.bootstrap = { Modal, Toast };
})();
