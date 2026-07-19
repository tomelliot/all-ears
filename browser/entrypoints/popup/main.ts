import { browser } from "wxt/browser";
import { CAPTURE_ENABLED_KEY, resolveCaptureToggleState } from "../../lib/capture-toggle";
import type { TransportStatus } from "../../lib/transport";

// Popup: capture on/off toggle + earsd connection indicator.
//
// The toggle is just a view over storage.local[CAPTURE_ENABLED_KEY] — writing
// the key is the whole action. content.ts mirrors changes into the MAIN world
// (which actually starts/stops capture), so the popup never talks to the tabs
// directly and works the same whether zero or five meeting tabs are open.
//
// Status comes from the background: queried once on open ({kind:"get-status"},
// which also wakes a suspended worker), then updated live off the
// {kind:"status"} broadcasts EarsSocket's status callback emits.

const toggleEl = document.getElementById("toggle") as HTMLInputElement | null;
const toggleLabelEl = document.getElementById("toggle-label");
const badgeEl = document.getElementById("status-badge");
const textEl = document.getElementById("status-text");

const STATUS_TEXT: Record<TransportStatus, string> = {
  connected: "Connected",
  connecting: "Connecting…",
  disconnected: "Disconnected",
};

const STATUS_TITLE: Record<TransportStatus, string> = {
  connected: "connected to earsd",
  connecting: "connecting to earsd…",
  disconnected: "earsd not reachable",
};

function renderStatus(status: TransportStatus): void {
  // The badge's dot colour is keyed off data-status in CSS; the one-word
  // label only shows when the badge is expanded on hover. The native
  // tooltip carries the fuller description.
  if (badgeEl) badgeEl.dataset.status = status;
  if (textEl) textEl.textContent = STATUS_TEXT[status] ?? String(status);
  badgeEl?.setAttribute("title", STATUS_TITLE[status] ?? String(status));
}

function renderToggle(enabled: boolean): void {
  if (toggleEl) {
    toggleEl.checked = enabled;
    toggleEl.disabled = false;
  }
  if (toggleLabelEl) toggleLabelEl.textContent = enabled ? "Capture on" : "Capture off";
}

// ── Toggle ⇄ storage.local ──────────────────────────────────────────────────

browser.storage.local
  .get(CAPTURE_ENABLED_KEY)
  .then((v) => renderToggle(resolveCaptureToggleState((v as Record<string, unknown>)[CAPTURE_ENABLED_KEY])))
  .catch(() => renderToggle(true));

toggleEl?.addEventListener("change", () => {
  renderToggle(toggleEl.checked);
  browser.storage.local.set({ [CAPTURE_ENABLED_KEY]: toggleEl.checked }).catch(() => {});
});

// Keep in sync if the key changes elsewhere (another popup window, options).
browser.storage.local.onChanged?.addListener?.((changes) => {
  const c = changes[CAPTURE_ENABLED_KEY];
  if (c) renderToggle(resolveCaptureToggleState(c.newValue));
});

// ── Connection status ───────────────────────────────────────────────────────

browser.runtime
  .sendMessage({ kind: "get-status" })
  .then((res) => {
    const s = (res as { status?: TransportStatus } | undefined)?.status;
    if (s) renderStatus(s);
  })
  .catch(() => renderStatus("disconnected"));

browser.runtime.onMessage.addListener((msg) => {
  const m = msg as { kind?: string; status?: TransportStatus };
  if (m.kind === "status" && m.status) renderStatus(m.status);
});
