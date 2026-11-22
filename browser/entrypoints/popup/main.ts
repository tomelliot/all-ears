import { browser } from "wxt/browser";
import {
  CAPTURE_ENABLED_KEY,
  DEBUG_LOG_KEY,
  DEBUG_REPORT_KEY,
  DEBUG_SNAPSHOT_KEY,
  PERF_DETAIL_KEY,
  resolveCaptureToggleState,
  resolvePerfDetailState,
} from "../../lib/capture-toggle";
import { toJsonl, type LogEntry } from "../../lib/debug-log";
import { perfToJsonl, type PerfRecord } from "../../lib/perf";
import type { BadgeState } from "../../lib/session-tracker";
import { describeJitsiSignal, detectJitsi, type JitsiSignal } from "../../lib/identity/jitsi-detect";
import {
  hostOfPattern,
  parseSiteHookPatterns,
  patternsForFrames,
  SITE_HOOKS_KEY,
} from "../../lib/site-hooks";

// ── Site hooks: enable capture scripts on the current, unlisted site ────────
//
// activeTab gives the popup the tab's URL and one isolated-world read of the
// top frame, which lists iframe origins (the call is often in one). The click
// requests host permission for those origins and records them; background.ts
// registers the scripts. They load on the next page load — the popup offers
// the reload instead of doing it, because reloading leaves a call in progress.

const siteHooksEl = document.getElementById("site-hooks");
const siteHooksBtnEl = document.getElementById("site-hooks-btn") as HTMLButtonElement | null;
const siteHooksReloadEl = document.getElementById("site-hooks-reload") as HTMLButtonElement | null;
const siteHooksNoteEl = document.getElementById("site-hooks-note");

let siteTab: { id: number; patterns: string[] } | null = null;
let siteStored: string[] = [];

function siteEnabled(): boolean {
  return siteTab !== null && siteTab.patterns.every((p) => siteStored.includes(p));
}

function renderSiteHooks(note?: string): void {
  if (!siteTab || !siteHooksEl || !siteHooksBtnEl) return;
  siteHooksEl.hidden = false;
  siteHooksBtnEl.textContent = siteEnabled() ? "Disable hooks on this site" : "Enable hooks on this site";
  if (siteHooksNoteEl) {
    siteHooksNoteEl.textContent = note ?? siteTab.patterns.map(hostOfPattern).join(", ");
  }
}

async function loadSiteHooks(): Promise<void> {
  if (!browser.scripting?.executeScript) return;
  const [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  if (tab?.id === undefined || !tab.url) return;
  let frameUrls: string[] = [];
  let jitsi: JitsiSignal | null = null;
  try {
    // Self-contained: executeScript serializes the function, so it gathers
    // raw inputs and the popup runs the detector on them.
    const [res] = await browser.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => ({
        frames: [...document.querySelectorAll("iframe")].map((f) => f.src),
        scripts: [...document.scripts].map((s) => s.src).filter(Boolean),
        resources: performance.getEntriesByType("resource").map((e) => e.name),
      }),
    });
    const r = res?.result as { frames?: unknown; scripts?: unknown; resources?: unknown } | undefined;
    const strings = (x: unknown): string[] => (Array.isArray(x) ? x.filter((s) => typeof s === "string") : []);
    frameUrls = strings(r?.frames);
    jitsi = detectJitsi({ scriptSrcs: strings(r?.scripts), resourceUrls: strings(r?.resources) });
  } catch {
    // No script access to this page — fall back to the top origin alone.
  }
  const patterns = patternsForFrames(tab.url, frameUrls);
  if (patterns.length === 0) return; // built-in platform or non-web page
  siteTab = { id: tab.id, patterns };
  const v = await browser.storage.local.get(SITE_HOOKS_KEY);
  siteStored = parseSiteHookPatterns((v as Record<string, unknown>)[SITE_HOOKS_KEY]);
  // A Jitsi page the user hasn't enabled yet gets told so: it is the one kind
  // of unlisted site the extension can fully capture (names and session).
  renderSiteHooks(
    jitsi && !siteEnabled()
      ? `This looks like a Jitsi meeting (${describeJitsiSignal(jitsi)}). Enable hooks to record it.`
      : undefined,
  );
}

void loadSiteHooks().catch(() => {});

siteHooksBtnEl?.addEventListener("click", () => {
  if (!siteTab) return;
  const { patterns } = siteTab;
  if (!siteEnabled()) {
    // The request has to be the first call in the handler, or the click's user
    // gesture lapses and the browser rejects it.
    browser.permissions
      .request({ origins: patterns })
      .then(async (granted) => {
        if (!granted) {
          renderSiteHooks("Permission not granted.");
          return;
        }
        siteStored = [...new Set([...siteStored, ...patterns])];
        await browser.storage.local.set({ [SITE_HOOKS_KEY]: siteStored });
        if (siteHooksReloadEl) siteHooksReloadEl.hidden = false;
        renderSiteHooks("Hooks registered. Reload the tab to load them — a reload leaves any call in progress.");
      })
      .catch(() => renderSiteHooks("Couldn't enable hooks."));
  } else {
    siteStored = siteStored.filter((p) => !patterns.includes(p));
    browser.storage.local
      .set({ [SITE_HOOKS_KEY]: siteStored })
      .then(() => browser.permissions.remove({ origins: patterns }))
      .then(() => {
        if (siteHooksReloadEl) siteHooksReloadEl.hidden = false;
        renderSiteHooks("Hooks removed. Reload the tab to unload them.");
      })
      .catch(() => renderSiteHooks("Couldn't disable hooks."));
  }
});

siteHooksReloadEl?.addEventListener("click", () => {
  if (!siteTab) return;
  void browser.tabs.reload(siteTab.id).then(() => window.close());
});

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
// transcription only pauses/resumes the daemon session around the paused span
// (audio keeps flowing into the ring buffer), so it goes straight to the
// background's SessionTracker via {kind:"set-transcription-paused"}.
//
// Status comes from the background: queried once on open ({kind:"get-status"},
// which also wakes a suspended worker), then updated live off the
// {kind:"status"} broadcasts. The badge now carries session states
// (recording/paused/transcribing) on top of the transport trio; transport
// problems always win (you can't be "recording" while disconnected).

const toggleEl = document.getElementById("toggle") as HTMLInputElement | null;
const toggleLabelEl = document.getElementById("toggle-label");
const badgeEl = document.getElementById("status-badge");
const textEl = document.getElementById("status-text");
const pauseRowEl = document.getElementById("transcription-row");
const pauseToggleEl = document.getElementById("transcription-toggle") as HTMLInputElement | null;
const pauseLabelEl = document.getElementById("transcription-label");

interface SessionInfo {
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
  recording: "meeting in progress — recording on earsd",
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

function renderSession(session: SessionInfo | undefined): void {
  const active = session?.active === true;
  if (pauseRowEl) pauseRowEl.hidden = !active;
  if (!active) return;
  if (pauseToggleEl) {
    pauseToggleEl.checked = !session!.paused;
    pauseToggleEl.disabled = false;
  }
  if (pauseLabelEl) {
    pauseLabelEl.textContent = session!.paused ? "Transcription paused" : "Transcription on";
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
  const dl = changes[DEBUG_LOG_KEY];
  if (dl) renderDebugLog(dl.newValue === true);
});

// ── Pause-transcription toggle → background SessionTracker ──────────────────

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

// "Send track snapshot": same nonce path; the meeting tab records a
// `track-snapshot` attribution event that earsd files under the live session.
const snapshotBtnEl = document.getElementById("debug-snapshot") as HTMLButtonElement | null;

snapshotBtnEl?.addEventListener("click", () => {
  browser.storage.local
    .set({ [DEBUG_SNAPSHOT_KEY]: Date.now() })
    .then(() => {
      if (debugNoteEl) {
        debugNoteEl.textContent = "Snapshot sent — it lands in the live session's attribution.jsonl.";
      }
    })
    .catch(() => {
      if (debugNoteEl) debugNoteEl.textContent = "Couldn't send the snapshot.";
    });
});

// ── Debug logging: persist console to disk (IndexedDB ring + export) ────────

// The toggle flips DEBUG_LOG_KEY; every context reads it and taps its console.
// "Download log" pulls the accumulated ring from the background and saves a
// .jsonl file (the popup has DOM, so it does the object-URL download — no
// downloads permission needed). "Clear log" empties the ring.
const debugLogToggleEl = document.getElementById("debug-log-toggle") as HTMLInputElement | null;
const downloadLogEl = document.getElementById("download-log") as HTMLButtonElement | null;
const clearLogEl = document.getElementById("clear-log") as HTMLButtonElement | null;

function renderDebugLog(on: boolean): void {
  if (debugLogToggleEl) {
    debugLogToggleEl.checked = on;
    debugLogToggleEl.disabled = false;
  }
}

browser.storage.local
  .get(DEBUG_LOG_KEY)
  .then((v) => renderDebugLog((v as Record<string, unknown>)[DEBUG_LOG_KEY] === true))
  .catch(() => renderDebugLog(false));

debugLogToggleEl?.addEventListener("change", () => {
  renderDebugLog(debugLogToggleEl.checked);
  browser.storage.local.set({ [DEBUG_LOG_KEY]: debugLogToggleEl.checked }).catch(() => {});
});

downloadLogEl?.addEventListener("click", () => {
  browser.runtime
    .sendMessage({ kind: "get-debug-log" })
    .then((res) => {
      const entries = (res as { entries?: LogEntry[] } | undefined)?.entries ?? [];
      if (entries.length === 0) {
        if (debugNoteEl) debugNoteEl.textContent = "No log entries captured yet.";
        return;
      }
      const blob = new Blob([toJsonl(entries)], { type: "application/x-ndjson" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `ears-debug-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")}.jsonl`;
      a.click();
      URL.revokeObjectURL(url);
      if (debugNoteEl) {
        debugNoteEl.textContent = `Downloaded ${entries.length} log ${entries.length === 1 ? "entry" : "entries"}.`;
      }
    })
    .catch(() => {
      if (debugNoteEl) debugNoteEl.textContent = "Couldn't read the log.";
    });
});

clearLogEl?.addEventListener("click", () => {
  browser.runtime
    .sendMessage({ kind: "clear-debug-log" })
    .then(() => {
      if (debugNoteEl) debugNoteEl.textContent = "Log cleared.";
    })
    .catch(() => {
      if (debugNoteEl) debugNoteEl.textContent = "Couldn't clear the log.";
    });
});

// ── Performance instrumentation ─────────────────────────────────────────────
//
// One control: detail — per-audio-frame stage timing + heap sampling. Costs
// main-thread time on the tab being measured.
// Tier 1 collection itself has no control here: it defaults on and is cheap.

const perfDetailToggleEl = document.getElementById("perf-detail-toggle") as HTMLInputElement | null;
const downloadPerfEl = document.getElementById("download-perf") as HTMLButtonElement | null;
const clearPerfEl = document.getElementById("clear-perf") as HTMLButtonElement | null;
const perfNoteEl = document.getElementById("perf-note");

browser.storage.local
  .get(PERF_DETAIL_KEY)
  .then((v) => {
    const record = v as Record<string, unknown>;
    if (perfDetailToggleEl) {
      perfDetailToggleEl.checked = resolvePerfDetailState(record[PERF_DETAIL_KEY]);
      perfDetailToggleEl.disabled = false;
    }
  })
  .catch(() => {});

perfDetailToggleEl?.addEventListener("change", () => {
  browser.storage.local.set({ [PERF_DETAIL_KEY]: perfDetailToggleEl.checked }).catch(() => {});
});

downloadPerfEl?.addEventListener("click", () => {
  browser.runtime
    .sendMessage({ kind: "get-perf-log" })
    .then((res) => {
      const records = (res as { records?: PerfRecord[] } | undefined)?.records ?? [];
      if (records.length === 0) {
        if (perfNoteEl) perfNoteEl.textContent = "No perf records captured yet.";
        return;
      }
      const blob = new Blob([perfToJsonl(records)], { type: "application/x-ndjson" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = `ears-perf-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")}.jsonl`;
      a.click();
      URL.revokeObjectURL(url);
      if (perfNoteEl) perfNoteEl.textContent = `Downloaded ${records.length} perf record(s).`;
    })
    .catch(() => {
      if (perfNoteEl) perfNoteEl.textContent = "Couldn't read the perf log.";
    });
});

clearPerfEl?.addEventListener("click", () => {
  browser.runtime
    .sendMessage({ kind: "clear-perf-log" })
    .then(() => {
      if (perfNoteEl) perfNoteEl.textContent = "Perf log cleared.";
    })
    .catch(() => {
      if (perfNoteEl) perfNoteEl.textContent = "Couldn't clear the perf log.";
    });
});

// ── Status + session state ──────────────────────────────────────────────────

interface StatusPayload {
  status?: BadgeState;
  session?: SessionInfo;
}

browser.runtime
  .sendMessage({ kind: "get-status" })
  .then((res) => {
    const payload = res as StatusPayload | undefined;
    if (payload?.status) renderStatus(payload.status);
    renderSession(payload?.session);
  })
  .catch(() => renderStatus("disconnected"));

browser.runtime.onMessage.addListener((msg) => {
  const m = msg as { kind?: string } & StatusPayload;
  if (m.kind === "status" && m.status) {
    renderStatus(m.status);
    renderSession(m.session);
  }
});
