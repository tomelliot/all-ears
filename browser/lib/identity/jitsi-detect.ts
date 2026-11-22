// Recognising a Jitsi Meet call by what the page *is*, not where it is hosted.
//
// The hostname list in jitsi.ts only covers the hosted services. Self-hosted
// Jitsi lives on any domain, and reaches the hooks through the popup's "Enable
// hooks on this site", which tags it `web` — and a `web` page declares no
// meeting, so the daemon has no session to file its audio under. This module
// lets such a page upgrade itself to `jitsi` once it shows Jitsi's fingerprint.
//
// It decides *what* a hooked page is, never *where* to hook: the RTC hook has
// to run at document_start, before any page script, so injection can only be
// chosen from the URL in advance. Fingerprinting every site would mean
// injecting into every site (`<all_urls>`), which this extension does not do.
//
// Signals, each specific to Jitsi on its own:
//
//   global    `window.JitsiMeetJS` — lib-jitsi-meet's public entry point, with
//             a string `version`. Existence only; nothing inside is read.
//   script    a `<script src>` naming lib-jitsi-meet (jitsi-meet's index.html
//             loads `libs/lib-jitsi-meet.min.js`; embedders of the library load
//             it under the same name).
//   network   a resource-timing entry for lib-jitsi-meet, or for Jicofo's
//             `/conference-request/v1` (how a client asks to join a room).
//             Passive: read from the Performance timeline, no fetch hook.
//   audio     remote audio stream ids in lib-jitsi-meet's MSID shape:
//             `<8-hex endpoint>-audio-<n>-<pcId>`, or the bridge's
//             `mixedmslabel`. This is the media itself, so it holds even for a
//             build that hides the global and renames its scripts — but it
//             only exists once the call has started.
//
// Weaker hints (the `#react` root, `participant_*` tile ids, `config.js`) are
// deliberately not signals: plenty of non-Jitsi pages have a `#react` or a
// `config.js`, and a false positive would declare meetings on them.

export type JitsiSignal = "global" | "script" | "network" | "audio";

/** What the detector looks at, gathered by the caller so this stays pure. */
export interface JitsiFingerprintInput {
  /** `typeof window.JitsiMeetJS?.version === "string"` (MAIN world only). */
  hasJitsiMeetJSGlobal?: boolean;
  /** `src` of every `<script>` in the document. */
  scriptSrcs?: readonly string[];
  /** `name` of every Performance resource entry. */
  resourceUrls?: readonly string[];
  /** `MediaStream.id` of each remote audio track the hook has seen. */
  remoteAudioStreamIds?: readonly string[];
}

/** URLs longer than this are skipped rather than parsed (data:, giant query strings). */
export const JITSI_MAX_URL_LENGTH = 2048;

const LIB_FILE_RE = /\/lib-jitsi-meet(?:\.[\w-]+)*\.js(?:[?#]|$)/i;
const CONFERENCE_REQUEST_RE = /\/conference-request\/v1(?:[?#/]|$)/i;
const JITSI_AUDIO_MSID_RE = /^[0-9a-f]{8}-audio-\d+-\d+$/;

function pathOf(url: string): string | null {
  if (url.length > JITSI_MAX_URL_LENGTH) return null;
  try {
    const u = new URL(url);
    return u.pathname + u.search;
  } catch {
    return url;
  }
}

/**
 * The first Jitsi signal present, or null. One signal is enough: each names a
 * component only Jitsi ships (or a stream shape only it produces).
 */
export function detectJitsi(input: JitsiFingerprintInput): JitsiSignal | null {
  if (input.hasJitsiMeetJSGlobal) return "global";
  if (
    input.scriptSrcs?.some((s) => {
      const p = pathOf(s);
      return p !== null && LIB_FILE_RE.test(p);
    })
  ) {
    return "script";
  }
  if (
    input.resourceUrls?.some((u) => {
      const p = pathOf(u);
      return p !== null && (LIB_FILE_RE.test(p) || CONFERENCE_REQUEST_RE.test(p));
    })
  ) {
    return "network";
  }
  if (input.remoteAudioStreamIds?.some((id) => id === "mixedmslabel" || JITSI_AUDIO_MSID_RE.test(id))) {
    return "audio";
  }
  return null;
}

/** Human wording for a signal, for logs and the popup. */
export function describeJitsiSignal(signal: JitsiSignal): string {
  switch (signal) {
    case "global":
      return "the JitsiMeetJS library is loaded";
    case "script":
      return "the page loads lib-jitsi-meet";
    case "network":
      return "the page fetched Jitsi's library or conference endpoint";
    case "audio":
      return "remote audio arrives in Jitsi's stream format";
  }
}

// ── The bounded watcher ──────────────────────────────────────────────────────
//
// The hook feeds this from events (a PerformanceObserver, two document
// lifecycle events, and track arrival), never from a polling loop. It holds the
// guarantees that keep detection from costing the page anything noticeable:
//
//   - a total CPU budget: once the checks have spent JITSI_DETECT_BUDGET_MS
//     between them, detection gives up for this page load;
//   - a cap on resource URLs examined, however long the page lives (past it
//     the network signal is dropped; the cheap audio signal keeps working);
//   - no work at all once it has matched or given up.
//
// Giving up only means the page stays `web`: audio is still captured.

/** Total time all checks on one page may spend before detection gives up. */
export const JITSI_DETECT_BUDGET_MS = 25;
/** Resource-timing entries examined per page load, at most. */
export const JITSI_MAX_RESOURCE_ENTRIES = 3000;
/** Script tags examined per document scan, at most. */
export const JITSI_MAX_SCRIPTS = 300;

export interface JitsiDetectionResult {
  signal: JitsiSignal | null;
  /** Why detection stopped without a match; absent on a match. */
  reason?: "time budget" | "stopped";
  checks: number;
  spentMs: number;
}

export class JitsiDetector {
  private spentMs = 0;
  private checks = 0;
  private resources = 0;
  private done = false;

  constructor(
    private readonly now: () => number,
    private readonly onDone: (result: JitsiDetectionResult) => void,
  ) {}

  /** Still looking. Callers check this before gathering input. */
  get active(): boolean {
    return !this.done;
  }

  /** The resource cap is spent: the caller can stop observing the network. */
  get resourcesExhausted(): boolean {
    return this.resources >= JITSI_MAX_RESOURCE_ENTRIES;
  }

  feed(input: JitsiFingerprintInput): void {
    if (this.done) return;
    let bounded = input;
    if (input.resourceUrls) {
      const room = Math.max(0, JITSI_MAX_RESOURCE_ENTRIES - this.resources);
      const urls = input.resourceUrls.length > room ? input.resourceUrls.slice(0, room) : input.resourceUrls;
      this.resources += urls.length;
      bounded = { ...input, resourceUrls: urls };
      if (urls.length === 0 && !input.hasJitsiMeetJSGlobal && !input.scriptSrcs && !input.remoteAudioStreamIds) return;
    }
    if (input.scriptSrcs && input.scriptSrcs.length > JITSI_MAX_SCRIPTS) {
      bounded = { ...bounded, scriptSrcs: input.scriptSrcs.slice(0, JITSI_MAX_SCRIPTS) };
    }
    const t0 = this.now();
    let signal: JitsiSignal | null = null;
    try {
      signal = detectJitsi(bounded);
    } catch {
      signal = null;
    }
    this.spentMs += this.now() - t0;
    this.checks++;
    if (signal) return this.finish(signal);
    if (this.spentMs >= JITSI_DETECT_BUDGET_MS) this.finish(null, "time budget");
  }

  /** Stop watching (page teardown, or the caller's own deadline). */
  stop(): void {
    if (!this.done) this.finish(null, "stopped");
  }

  private finish(signal: JitsiSignal | null, reason?: JitsiDetectionResult["reason"]): void {
    this.done = true;
    this.onDone({
      signal,
      ...(signal ? {} : { reason }),
      checks: this.checks,
      spentMs: this.spentMs,
    });
  }
}

/**
 * Read `window.JitsiMeetJS.version` without running any page code: only plain
 * data properties are followed, so a page-defined getter (which could throw,
 * or loop) is never invoked.
 */
export function hasJitsiMeetJSGlobal(win: object): boolean {
  try {
    const lib = Object.getOwnPropertyDescriptor(win, "JitsiMeetJS");
    if (!lib || !("value" in lib) || typeof lib.value !== "object" || lib.value === null) return false;
    const version = Object.getOwnPropertyDescriptor(lib.value, "version");
    return !!version && "value" in version && typeof version.value === "string";
  } catch {
    return false;
  }
}
