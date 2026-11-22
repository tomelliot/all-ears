// Single source of truth for messages crossing the four contexts.
//
//   injected.ts ──win──► content.ts ──rt──► background.ts
//    (MAIN world)         (isolated)         (SW / bg page)
//
// "win" = window.postMessage (main↔isolated). "rt" = chrome.runtime (browser.*).

import type { LogEntry } from "./debug-log";
import type { PerfRecord } from "./perf";

/** Marker on every window.postMessage envelope crossing the world boundary. */
export const EARS_MARKER = "__ears" as const;

/**
 * Platform tag, mirrored into the earsd `browser:<platform>:<track-slug>` label.
 * `web` is any site the user enabled hooks on from the popup (site-hooks.ts).
 */
export type Platform = "meet" | "zoom" | "teams" | "daily" | "jitsi" | "web";

/**
 * Where a participant reference was minted. `platform` ids come from the
 * platform itself (a Meet device path like `spaces/x/devices/y`, a Zoom node
 * id) and can be joined against the platform's own roster; `synthetic` ids
 * are extension-minted handles that name a captured track, not a person —
 * the per-track source slugs (`t<n>`) and the dev-only stand-ins
 * (`graphtap-<n>`). The distinction travels to the daemon as the attendee's
 * `origin`, so a synthetic roster row is never mistaken for a platform-observed
 * one (attribution refactor R4; reconciler bug B7).
 */
export type ParticipantOrigin = "platform" | "synthetic";

/**
 * A typed reference to a call participant: the id plus where it was minted.
 * This is the one participant vocabulary inside the extension; it is flattened
 * to a plain string only at the wire edges — the earsd source label
 * (`sourceLabel`) and the `session.attendee` upsert's `id`, where the kind
 * rides separately as `origin`. Messages that merely *refer back* to a
 * participant already declared by `participant-joined` (pcm, left,
 * capture-failed) carry the bare `id` as a key.
 */
export interface ParticipantRef {
  kind: ParticipantOrigin;
  id: string;
}

/** A reference under an extension-minted track handle (`t<n>`, …). */
export function syntheticParticipant(id: string): ParticipantRef {
  return { kind: "synthetic", id };
}

/**
 * One (participantId → displayName) pair harvested from the platform's own
 * participant roster/UI, independent of whether that participant's audio track
 * has been correlated to this id yet (issue #23). The daemon upserts these onto
 * the session's attendee roster, so a name lands even when the speaking-onset
 * correlation never tied the participant to a captured track (in which case the
 * track's source stays an anonymous handle and this named entry sits beside it,
 * rather than the name being silently lost). `displayName` is always a
 * non-empty string — empties are dropped before an entry is built.
 */
export interface RosterEntry {
  /** Always a platform-minted id: roster entries are harvested from the
   * platform's own UI, which only ever speaks its own ids. */
  participantId: string;
  displayName: string;
  /**
   * This entry is the local participant — you. Present only when the adapter
   * could establish it beyond doubt; absent means "not known to be you", never
   * "known not to be you".
   *
   * The daemon needs it because the local participant is captured on `mic`,
   * so a browser-tapped remote track bound to them is an impossible state
   * rather than an unlikely one — the failure behind journal #158/#172. The
   * live guard in meet.ts already refuses such a binding, but it fails *open*
   * when the platform withholds its "(You)" marker, so the flag travels to
   * the daemon as well and the same invariant is enforced again at session
   * end, on durable state.
   */
  isLocal?: boolean;
}

/**
 * Main-world → isolated-world messages. PCM rides the same channel as a
 * transferable Int16Array (structured-cloned across the world boundary).
 */
export type MainMessage =
  // Declares a capture participant — always a track-scoped handle (`t<n>`,
  // kind `synthetic`): source ids carry no identity (R3). Later messages
  // refer back by the bare `participantId` key. Identity, when it resolves,
  // rides `participant-identified` / `participant-roster`, never this.
  | { kind: "participant-joined"; platform: Platform; participant: ParticipantRef; generation: number }
  | { kind: "participant-left"; participantId: string; generation: number }
  // A batch of participant identities (id → display name) the adapter resolved
  // from the platform's roster/UI, not necessarily tied to a captured track.
  // Distinct from participant-joined (which is a capture-pipeline lifecycle
  // event): a roster entry carries only identity, so names reach the daemon even
  // for a participant whose track never correlated to a device id (issue #23).
  | { kind: "participant-roster"; platform: Platform; entries: RosterEntry[] }
  // `seq` is per-participant and monotonic from the first frame of the
  // pipeline; `sentAt` is epoch ms at the moment the MAIN world handed the
  // frame over. Both ride all the way to earsd (see encodeBinaryFrame), which
  // uses them to tell a silent speaker apart from a stalled extension — a
  // distinction the ingest wire previously could not express at all.
  | {
      kind: "pcm";
      participantId: string;
      generation: number;
      samples: Int16Array;
      seq: number;
      sentAt: number;
    }
  // A confirmed identity for a captured source: the platform id (and display
  // name, when resolved) that owns the audio recorded under `captureId`'s
  // source. Source ids are stable per-track handles that never carry identity,
  // so this upsert is the ONLY way a platform identity reaches the daemon's
  // roster with a source link — sent whenever the identity is known, whether
  // at admission (Zoom MSID, a Meet tile hit), after speaking-onset
  // correlation confirms mid-call, or after the track already died. Nothing
  // restarts and no audio is lost: the daemon just gains a roster row joining
  // name and source. `participantId` is always platform-minted.
  | {
      kind: "participant-identified";
      platform: Platform;
      participantId: string;
      captureId: string;
      displayName?: string;
    }
  | { kind: "status"; text: string }
  // A participant's capture pipeline died for good (e.g. the Meet decoder gave
  // up after exhausting its restart budget). Distinct from participant-left: the
  // participant is still in the call, but their audio after this point is lost.
  // Forwarded to the background so the gap is attributable rather than looking
  // like the source merely went quiet (issue #22).
  | { kind: "capture-failed"; participantId: string; generation: number; reason: string }
  // Fired once per call (not per participant): the platform's own meeting id
  // resolved (Meet's spaces/<space> segment — see identity/meet-meeting-id.ts),
  // and the call ended (capture toggled off / teardown). May arrive after
  // capture starts — meeting bookkeeping never gates capture.
  | {
      kind: "meeting-started";
      platform: Platform;
      externalMeetingId: string;
      /** The meeting's human name, when the tab already knows it at declare
       * time. Absent means "not found (yet)" — the daemon's own default
       * (identity → Meet id) stands, and a later `meeting-renamed` may still
       * supply one. */
      title?: string;
    }
  | { kind: "meeting-renamed"; platform: Platform; externalMeetingId: string; title: string }
  | { kind: "meeting-ended"; platform: Platform; externalMeetingId: string }
  // Debug logging only: a batch of the MAIN-world hook's tapped console
  // entries, which the isolated relay forwards to the background's log store.
  // The MAIN world has no extension APIs, so this is its only route to disk.
  | { kind: "log"; entries: LogEntry[] }
  // A flush of the MAIN world's perf collector (perf.ts). Kept off the `log`
  // channel on purpose: these must not pass through the console tap, whose
  // synchronous serialization runs on the thread being measured.
  | { kind: "perf"; records: PerfRecord[] }
  // A batch of attribution flight-recorder events (attribution-log.ts), each
  // already encoded as one JSONL line. Pre-encoded on purpose: the relay,
  // background, and daemon all treat the lines as opaque and append them
  // verbatim to the session's attribution.jsonl, so what lands on disk is
  // byte-for-byte what the MAIN world recorded.
  | { kind: "attribution"; platform: Platform; events: string[] };

/** The envelope actually posted; `event.source === window` + marker gate it. */
export interface MainEnvelope {
  [EARS_MARKER]: true;
  msg: MainMessage;
}

export function postToIsolated(msg: MainMessage): void {
  const envelope: MainEnvelope = { [EARS_MARKER]: true, msg };
  // Transfer the PCM buffer to avoid a copy on the main-world side.
  const transfer = msg.kind === "pcm" ? [msg.samples.buffer] : [];
  window.postMessage(envelope, "*", transfer as Transferable[]);
}

export function isMainEnvelope(data: unknown): data is MainEnvelope {
  return (
    typeof data === "object" &&
    data !== null &&
    (data as Record<string, unknown>)[EARS_MARKER] === true &&
    typeof (data as MainEnvelope).msg === "object"
  );
}

// ── Isolated-world → main-world control messages ─────────────────────────────

/** Marker for the reverse direction, distinct from EARS_MARKER so neither
 * listener ever mistakes its own outbound envelope for inbound traffic. */
export const EARS_CTL_MARKER = "__earsCtl" as const;

/**
 * Isolated → main-world messages. The MAIN world has no extension APIs, so
 * anything it needs from storage/runtime arrives on this channel — today
 * that's just the capture toggle (see capture-toggle.ts).
 */
export type ControlMessage =
  | { kind: "capture-state"; enabled: boolean }
  // Debug: dump a MAIN-world capture/probe/hook state snapshot to this tab's
  // console. Triggered from the popup via a storage-key nudge (content.ts),
  // so it reaches every open meeting tab and needs no extra permissions.
  | { kind: "report-state" }
  // Debug: record a `track-snapshot` attribution event (every WebAudio track
  // and provenance record) and ship it to earsd. Same popup trigger path.
  | { kind: "send-track-snapshot" }
  // The popup was opened on this tab: run platform detection again now
  // (identity/jitsi-detect.ts), in case it missed or gave up at page load.
  // Sent to the active tab only (tabs.sendMessage → content.ts), every frame.
  | { kind: "recheck-platform" }
  // Debug logging flag, mirrored from storage.local (which the MAIN world
  // can't read) so the hook installs/removes its console tap. Same
  // storage ⇄ content ⇄ MAIN path as capture-state.
  | { kind: "debug-log-state"; enabled: boolean }
  // Perf instrumentation flags, same mirroring path. `enabled` gates the
  // whole collector (Tier 1: long tasks, video stats, counters); `detail`
  // additionally gates the per-audio-frame stage timing and heap sampling,
  // which cost more than they should to leave on unattended.
  | { kind: "perf-state"; enabled: boolean; detail: boolean };

export interface ControlEnvelope {
  [EARS_CTL_MARKER]: true;
  msg: ControlMessage;
}

export function postToMain(msg: ControlMessage): void {
  const envelope: ControlEnvelope = { [EARS_CTL_MARKER]: true, msg };
  window.postMessage(envelope, "*");
}

export function isControlEnvelope(data: unknown): data is ControlEnvelope {
  return (
    typeof data === "object" &&
    data !== null &&
    (data as Record<string, unknown>)[EARS_CTL_MARKER] === true &&
    typeof (data as ControlEnvelope).msg === "object"
  );
}

// ── Isolated → background port (content.ts → background.ts) ──────────────────

/**
 * Messages on the long-lived "pcm" runtime port. PCM rides base64 on this
 * internal hop (runtime messaging mangles TypedArrays); the earsd wire is
 * binary. Lifecycle events share the port so the transport can ingest.close.
 */
export type PortMessage =
  | {
      type: "pcm";
      participantId: string;
      platform: Platform;
      b64: string;
      seq: number;
      sentAt: number;
    }
  // A capture participant (track-scoped handle) — what the background upserts
  // onto the daemon session's roster as a synthetic row. Carries the full
  // ref: the upsert needs `kind` to stamp the attendee's `origin`.
  | { type: "joined"; participant: ParticipantRef; platform: Platform }
  // Identity-only roster names (see MainMessage "participant-roster"). The
  // background upserts each onto the daemon session's attendee roster without
  // treating them as capture participants (no `left` is ever stamped on them).
  | { type: "roster"; platform: Platform; entries: RosterEntry[] }
  // A confirmed identity for a captured source (see MainMessage
  // "participant-identified"): the background upserts `captureId`'s source
  // label onto the `participantId` attendee, joining name and source on one
  // roster row.
  | {
      type: "identified";
      platform: Platform;
      participantId: string;
      captureId: string;
      displayName?: string;
    }
  | { type: "left"; participantId: string }
  // A participant's capture died mid-call (see MainMessage "capture-failed").
  | { type: "capture-failed"; participantId: string; platform: Platform; reason: string }
  | { type: "meeting-started"; platform: Platform; externalMeetingId: string; title?: string }
  | { type: "meeting-renamed"; platform: Platform; externalMeetingId: string; title: string }
  | { type: "meeting-ended"; platform: Platform; externalMeetingId: string }
  // A batch of attribution flight-recorder events (see MainMessage
  // "attribution"): opaque pre-encoded JSONL lines the background ships to
  // earsd as `ingest.attribution`, filed under the port's live session.
  | { type: "attribution"; platform: Platform; events: string[] };

// ── earsd wire (background.ts → earsd) ───────────────────────────────────────

/** v1 always declares 16 kHz mono pcm_s16le; keys match earsd's AudioFormatSpec. */
export const INGEST_FORMAT = { sample_rate: 16000, channels: 1, encoding: "pcm_s16le" } as const;

/** earsd source labels are `[A-Za-z0-9._-]`; sanitize the capture-id suffix.
 * Today's track slugs (`t<n>`) are already clean — this guards the label
 * grammar against any historic or dev-minted id shape. */
export function sanitizeLabel(id: string): string {
  const cleaned = id.replace(/[^A-Za-z0-9._-]/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "");
  return cleaned || "unknown";
}

/** Wire edge: the earsd source label for a capture participant. `captureId`
 * is the track-scoped handle the audio is recorded under — an opaque slug,
 * never an identity (R3). Whose voice the source carries rides separately, on
 * the `session.attendee` upsert linking this label. */
export function sourceLabel(platform: Platform, captureId: string): string {
  return `browser:${platform}:${sanitizeLabel(captureId)}`;
}

// ── earsd control-plane wire (background.ts → earsd ws://…/control) ──────────
//
// Control protocol v2 (docs/specs/control-protocol.md): an
// id-correlated {id, method, params} envelope, a mandatory `hello`
// handshake, and revision-tagged {event, params, rev} notifications. The
// same frames the CLI speaks over the Unix socket; this transport's
// capability tier is `observe` + `sessions`.

/** Provenance recorded on daemon sessions this extension declares (earsd's
 * TriggerKind.browserExtension). */
export const BROWSER_TRIGGER = "browser-extension" as const;

/** The one protocol version both sides of this repo speak. */
export const PROTOCOL_VERSION = 2;

export type RequestId = number | string;

/** Stable machine-readable error codes — switch on `code`, never `message`. */
export interface WireError {
  code: string;
  message: string;
}

/** Response frame: exactly one per request, correlated by the echoed id. */
export interface ResponseFrame {
  id: RequestId;
  result?: unknown;
  error?: WireError;
}

/** Notification frame; `rev` is present iff the event is a state event. */
export interface EventFrame {
  event: string;
  params: Record<string, unknown>;
  rev?: number;
}

/** `hello`'s result. */
export interface HelloResult {
  protocol: number;
  daemon: string;
  boot_id: string;
  capabilities: string[];
}

/** The v2 session object (wire shape). */
export interface SessionWire {
  id: string;
  identity?: { platform: string; external_id: string };
  title: string;
  state: "active" | "paused" | "ended";
  started: string;
  ended?: string | null;
  intervals: Array<{ start: string; end: string | null }>;
  attendees: Array<{
    id: string;
    display_name?: string;
    joined?: string;
    left?: string;
    source?: string;
    /** Provenance of `id` (see {@link ParticipantOrigin}); absent on rosters
     * recorded before provenance existed. */
    origin?: ParticipantOrigin;
  }>;
  sources: string[];
  trigger: string;
  rev: number;
}

/** `subscribe`'s snapshot result. */
export interface SnapshotWire {
  rev: number;
  sessions: SessionWire[];
  sources: Array<{ id: string; state: string }>;
}

/** `session.attendee` upsert params (minus the session id, which the
 * transport fills in). */
export interface AttendeeUpsert {
  id: string;
  display_name?: string;
  joined?: string;
  left?: string;
  source?: string;
  /** Where `id` was minted — the flattened `ParticipantRef.kind`. Platform
   * ids came from the platform's own roster/streams; synthetic ids are
   * extension stand-ins (`speaker-<n>`, …) that name a track, not a person.
   * The reconciler counts only platform-origin rows as named remote
   * participants (bug B7). Omitted when the sender doesn't know (a stream
   * link for an id whose join was never seen) — absent means unknown, and
   * the daemon leaves the stored value untouched. */
  origin?: ParticipantOrigin;
  /** This attendee is the local participant (see `RosterEntry.isLocal`).
   * Omitted rather than sent `false`: the daemon latches it and never clears
   * it, so a later upsert that simply doesn't know cannot un-flag them. */
  self?: boolean;
}

/**
 * JSON frame builders for the v2 requests the extension sends over the
 * control WebSocket (control-transport.ts).
 */
export const controlRequest = {
  hello: (id: RequestId, client: string) =>
    ({ id, method: "hello", params: { protocol: PROTOCOL_VERSION, client } }) as const,
  subscribe: (id: RequestId, events: readonly string[]) =>
    ({ id, method: "subscribe", params: { events } }) as const,
  sessionStart: (id: RequestId, platform: Platform, externalMeetingId: string, title?: string) =>
    ({
      id,
      method: "session.start",
      params: {
        platform,
        external_id: externalMeetingId,
        trigger: BROWSER_TRIGGER,
        ...(title ? { title } : {}),
      },
    }) as const,
  /** `if_rev` makes the rename a compare-and-set: the daemon rejects it with
   * `conflict` if the session moved on, so a scraped name never clobbers one
   * the user set by hand. */
  sessionRename: (id: RequestId, session: string, title: string, ifRev?: number) =>
    ({
      id,
      method: "session.rename",
      params: { session, title, ...(ifRev === undefined ? {} : { if_rev: ifRev }) },
    }) as const,
  sessionEnd: (id: RequestId, session: string) =>
    ({ id, method: "session.end", params: { session } }) as const,
  sessionPause: (id: RequestId, session: string) =>
    ({ id, method: "session.pause", params: { session } }) as const,
  sessionResume: (id: RequestId, session: string) =>
    ({ id, method: "session.resume", params: { session } }) as const,
  sessionAttendee: (id: RequestId, session: string, attendee: AttendeeUpsert) =>
    ({ id, method: "session.attendee", params: { session, ...attendee } }) as const,
};

/**
 * Binary PCM frame. Two wire shapes, distinguished by the first byte:
 *
 *   legacy:   [u8 idLen>0][stream_id ASCII][pcm_s16le]
 *   extended: [0x00][u8 ver=1][u8 idLen][stream_id ASCII][u32le seq][f64le sentAt][pcm_s16le]
 *
 * A zero first byte is impossible in the legacy shape — earsd assigns non-empty
 * "s7"-style stream ids — which is what makes it a safe discriminator. earsd
 * parses both, so a daemon upgraded ahead of the extension keeps working.
 *
 * `seq` is per-stream and monotonic (wrapping at 2^32, ~2.7 years at 50 fps);
 * `sentAt` is epoch ms. Together they let the daemon compute one-way delay and
 * detect genuinely lost frames instead of inferring both from arrival times.
 */
export const INGEST_FRAME_VERSION = 1;

export function encodeBinaryFrame(
  streamId: string,
  pcm: Uint8Array,
  stamp?: { seq: number; sentAt: number },
): Uint8Array {
  const idBytes = new TextEncoder().encode(streamId);
  if (idBytes.length > 255) throw new Error(`stream_id too long: ${streamId}`);
  if (idBytes.length === 0) throw new Error("stream_id must not be empty");
  if (!stamp) {
    const out = new Uint8Array(1 + idBytes.length + pcm.length);
    out[0] = idBytes.length;
    out.set(idBytes, 1);
    out.set(pcm, 1 + idBytes.length);
    return out;
  }
  const headerLen = 3 + idBytes.length + 4 + 8;
  const out = new Uint8Array(headerLen + pcm.length);
  out[0] = 0;
  out[1] = INGEST_FRAME_VERSION;
  out[2] = idBytes.length;
  out.set(idBytes, 3);
  // Unaligned by construction; DataView handles that, a typed-array view would not.
  const view = new DataView(out.buffer, out.byteOffset, out.byteLength);
  view.setUint32(3 + idBytes.length, stamp.seq >>> 0, true);
  view.setFloat64(3 + idBytes.length + 4, stamp.sentAt, true);
  out.set(pcm, headerLen);
  return out;
}

/** Inverse of {@link encodeBinaryFrame}; exists for tests and for the dev
 * harness, which replays captured frames without a daemon. */
export function decodeBinaryFrame(
  frame: Uint8Array,
): { streamId: string; pcm: Uint8Array; seq?: number; sentAt?: number } | null {
  if (frame.length < 1) return null;
  const decoder = new TextDecoder();
  const idLen = frame[0]!;
  if (idLen > 0) {
    if (frame.length < 1 + idLen) return null;
    return {
      streamId: decoder.decode(frame.subarray(1, 1 + idLen)),
      pcm: frame.subarray(1 + idLen),
    };
  }
  if (frame.length < 3 || frame[1] !== INGEST_FRAME_VERSION) return null;
  const extLen = frame[2]!;
  const headerLen = 3 + extLen + 12;
  if (extLen === 0 || frame.length < headerLen) return null;
  const view = new DataView(frame.buffer, frame.byteOffset, frame.byteLength);
  return {
    streamId: decoder.decode(frame.subarray(3, 3 + extLen)),
    seq: view.getUint32(3 + extLen, true),
    sentAt: view.getFloat64(3 + extLen + 4, true),
    pcm: frame.subarray(headerLen),
  };
}
