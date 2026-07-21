import { browser } from "wxt/browser";
import { CAPTURE_ENABLED_KEY, DEBUG_REPORT_KEY, resolveCaptureToggleState } from "../../lib/capture-toggle";
import type { BadgeState } from "../../lib/meeting-tracker";

// Popup: capture on/off toggle + earsd status badge + (while a meeting is
// live) a pause-transcription toggle.
//
// The capture toggle is just a view over storage.local[CAPTURE_ENABLED_KEY] —
// writing the key is the whole action. content.ts mirrors changes into the
// MAIN world (which actually starts/stops capture), so the popup never talks
// to the tabs directly and works the same whether zero or five meeting tabs
// are open.
//
// The pause toggle is deliberately NOT that mechanism: capture-toggle.ts is a
// privacy kill switch that tears down the whole capture pipeline. Pausing
// transcription only closes/reopens the daemon session around the paused span
// (audio keeps flowing into the ring buffer), so it goes straight to the
// background's MeetingTracker via {kind:"set-transcription-paused"}.
//
// Status comes from the background: queried once on open ({kind:"get-status"},
// which also wakes a suspended worker), then updated live off the
// {kind:"status"} broadcasts. The badge now carries meeting states
// (recording/paused/transcribing) on top of the transport trio; transport
// problems always win (you can't be "recording" while disconnected).

const toggleEl = document.getElementById("toggle") as HTMLInputElement | null;
const toggleLabelEl = document.getElementById("toggle-label");
const badgeEl = document.getElementById("status-badge");
const textEl = document.getElementById("status-text");
const pauseRowEl = document.getElementById("transcription-row");
const pauseToggleEl = document.getElementById("transcription-toggle") as HTMLInputElement | null;
const pauseLabelEl = document.getElementById("transcription-label");

interface MeetingInfo {
  active: boolean;
  paused: boolean;
}

const STATUS_TEXT: Record<BadgeState, string> = {
  connected: "Connected",
  connecting: "Connecting…",
  disconnected: "Disconnected",
  recording: "Recording",
  paused: "Paused",
  transcribing: "Transcribing",
};

const STATUS_TITLE: Record<BadgeState, string> = {
  connected: "connected to earsd",
  connecting: "connecting to earsd…",
  disconnected: "earsd not reachable",
  recording: "meeting in progress — session open on earsd",
  paused: "meeting in progress — transcription paused",
  transcribing: "meeting ended — transcribing",
};

function renderStatus(status: BadgeState): void {
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

function renderMeeting(meeting: MeetingInfo | undefined): void {
  const active = meeting?.active === true;
  if (pauseRowEl) pauseRowEl.hidden = !active;
  if (!active) return;
  if (pauseToggleEl) {
    pauseToggleEl.checked = !meeting!.paused;
    pauseToggleEl.disabled = false;
  }
  if (pauseLabelEl) {
    pauseLabelEl.textContent = meeting!.paused ? "Transcription paused" : "Transcription on";
  }
}

// ── Capture toggle ⇄ storage.local ──────────────────────────────────────────

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

// ── Pause-transcription toggle → background MeetingTracker ──────────────────

pauseToggleEl?.addEventListener("change", () => {
  const paused = !pauseToggleEl.checked;
  if (pauseLabelEl) {
    pauseLabelEl.textContent = paused ? "Transcription paused" : "Transcription on";
  }
  browser.runtime.sendMessage({ kind: "set-transcription-paused", paused }).catch(() => {});
});

// ── Debug: report state → meeting tab console(s) ────────────────────────────

// Writing a fresh nonce fires storage.onChanged in every open meeting tab's
// content script, which nudges the MAIN world to log `[ears][debug][state]`.
// Same popup ⇄ storage ⇄ content path as the capture toggle — no tabs/scripting
// permission needed, and it reaches every meeting tab at once.
const debugBtnEl = document.getElementById("debug-report") as HTMLButtonElement | null;
const debugNoteEl = document.getElementById("debug-report-note");

debugBtnEl?.addEventListener("click", () => {
  browser.storage.local
    .set({ [DEBUG_REPORT_KEY]: Date.now() })
    .then(() => {
      if (debugNoteEl) debugNoteEl.textContent = "State dumped — see the meeting tab console ([ears][debug][state]).";
    })
    .catch(() => {
      if (debugNoteEl) debugNoteEl.textContent = "Couldn't trigger the report.";
    });
});

// ── Status + meeting state ──────────────────────────────────────────────────

interface StatusPayload {
  status?: BadgeState;
  meeting?: MeetingInfo;
}

browser.runtime
  .sendMessage({ kind: "get-status" })
  .then((res) => {
    const payload = res as StatusPayload | undefined;
    if (payload?.status) renderStatus(payload.status);
    renderMeeting(payload?.meeting);
  })
  .catch(() => renderStatus("disconnected"));

browser.runtime.onMessage.addListener((msg) => {
  const m = msg as { kind?: string } & StatusPayload;
  if (m.kind === "status" && m.status) {
    renderStatus(m.status);
    renderMeeting(m.meeting);
  }
});
