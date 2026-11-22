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

const LIB_FILE_RE = /\/lib-jitsi-meet(?:\.[\w-]+)*\.js(?:[?#]|$)/i;
const CONFERENCE_REQUEST_RE = /\/conference-request\/v1(?:[?#/]|$)/i;
const JITSI_AUDIO_MSID_RE = /^[0-9a-f]{8}-audio-\d+-\d+$/;

function pathOf(url: string): string {
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
  if (input.scriptSrcs?.some((s) => LIB_FILE_RE.test(pathOf(s)))) return "script";
  if (
    input.resourceUrls?.some((u) => {
      const p = pathOf(u);
      return LIB_FILE_RE.test(p) || CONFERENCE_REQUEST_RE.test(p);
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
