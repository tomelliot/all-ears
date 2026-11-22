// The Jitsi bridge channel (Colibri): the local participant's endpoint id and
// the owners of SSRC-rewriting audio slots. Read from lib-jitsi-meet and
// jitsi-videobridge sources, and checked on a live meet.jit.si call
// (2026-11-22, three people, current lib-jitsi-meet production build).
//
// Two transports carry the same JSON messages (`colibriClass` names the type):
//   - An `RTCDataChannel` labelled `JVB data channel` on the bridge peer
//     connection. meet.jit.si uses this (`config.openBridgeChannel` unset,
//     BridgeChannel `_mode === "datachannel"`). rtc-hook.ts finds the channel
//     and hands it to observeBridgeDataChannel below.
//   - A WebSocket to `<base>/colibri-ws/<serverId>/<conferenceId>/<endpointId>`
//     on deployments that set `openBridgeChannel: "websocket"`. Its URL also
//     names us: Jicofo hands each endpoint its own colibri-ws URL
//     (`<web-socket>` in session-initiate), minted by the videobridge
//     (ColibriWebSocketService.getColibriWebSocketUrls), and a page only opens
//     that socket for its own endpoint.
//
// Two message types are read; everything else is ignored unparsed:
//   - `SenderSourceConstraints` {sourceName: "<endpointId>-v<n>"}. The bridge
//     sends it only to the sender of that source, so it names us. It is only
//     sent while we send video: with the camera off there may be no local id,
//     and then nothing is flagged local (protocol.ts RosterEntry.isLocal).
//   - `AudioSourcesMap` {mappedSources: [{source, owner, ssrc}]}. With SSRC
//     rewriting on, remote audio arrives on a pool of reused slot tracks
//     (`remote-audio-<n>`), and this names the endpoint now sending on each
//     slot's SSRC. Sent only when assignments change, including the initial
//     map when the channel opens, so the listener must be attached from the
//     channel's creation (the hook runs at document_start).
// Remote MSIDs cannot name us: LocalSdpMunger rewrites MSIDs only in the SDP
// lib-jitsi-meet signals, so our own peer connection keeps the browser's ids.
//
// Passive throughout. The constructor wrap builds the real socket and returns
// it untouched; every observer is an added `message` listener that never
// consumes, alters or re-dispatches an event. Memory is bounded: one local id
// and at most MAX_AUDIO_OWNERS slot owners. The socket URL is never kept (its
// query carries the channel password). The Colibri messages are the bridge's
// documented JSON protocol, not a private store (extension spec MUST-NOT #6).
//
// State lives on `window` so every capture epoch's adapter reads the same
// values, whichever module instance installed the observers.

interface ColibriWindow {
  WebSocket: typeof WebSocket;
  __earsColibriWatch?: boolean;
  __earsJitsiLocalEndpoint?: string;
  __earsJitsiAudioOwners?: Map<number, string>;
  __earsJitsiBridgeListener?: () => void;
}

function cw(): ColibriWindow {
  return window as unknown as ColibriWindow;
}

/** The label lib-jitsi-meet gives the bridge channel (BridgeChannel.js). */
export const JVB_DATA_CHANNEL_LABEL = "JVB data channel";

// `/colibri-ws/<serverId>/<conferenceId>/<endpointId>`, anywhere in the path
// so a reverse-proxy prefix still matches. Relay sockets use
// `/colibri-relay-ws/` and never match.
const COLIBRI_PATH_RE = /\/colibri-ws\/[^/]+\/[^/]+\/([^/]+)\/?$/;
// Same character set the MSID parser accepts for an endpoint id.
const ENDPOINT_ID_RE = /^[A-Za-z0-9_.~-]{1,256}$/;
// A source name: `<endpointId>-<a|v><index>` (lib-jitsi-meet getSourceNameForJitsiTrack).
const SOURCE_NAME_RE = /^(.+)-[av]\d+$/;
/** Slot owners kept at most. The bridge's slot pool is a handful of entries;
 * this only stops a misbehaving peer from growing the map without limit. */
const MAX_AUDIO_OWNERS = 64;
/** Entries read from one AudioSourcesMap at most. */
const MAX_MAPPED_SOURCES = 64;
/** Messages longer than this are not parsed. Both types read here are tiny;
 * the bulky ones (stats, ForwardedSources) are skipped before parsing. */
const MAX_MESSAGE_CHARS = 64 * 1024;

/** The endpoint id from a colibri-ws URL, or null for any other URL. */
export function parseColibriEndpointId(url: string | null | undefined): string | null {
  if (!url) return null;
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  if (u.protocol !== "wss:" && u.protocol !== "ws:") return null;
  const raw = u.pathname.match(COLIBRI_PATH_RE)?.[1];
  if (!raw) return null;
  let id: string;
  try {
    id = decodeURIComponent(raw);
  } catch {
    return null;
  }
  return ENDPOINT_ID_RE.test(id) ? id : null;
}

/** The endpoint id from a source name (`<endpointId>-v0`), or null. */
export function endpointIdFromSourceName(sourceName: unknown): string | null {
  if (typeof sourceName !== "string") return null;
  const id = sourceName.match(SOURCE_NAME_RE)?.[1];
  return id && ENDPOINT_ID_RE.test(id) ? id : null;
}

/** One parsed bridge message: only the two types this module reads. */
export type BridgeMessage =
  | { kind: "local-endpoint"; endpointId: string }
  | { kind: "audio-sources"; sources: Array<{ ssrc: number; owner: string }> };

/**
 * Parse one bridge-channel message. Null for every other `colibriClass`, for
 * non-string frames, and for anything malformed. Never throws.
 */
export function parseBridgeMessage(data: unknown): BridgeMessage | null {
  if (typeof data !== "string" || data.length > MAX_MESSAGE_CHARS) return null;
  // Cheap pre-filter: stats and the other frequent types never reach JSON.parse.
  const ssc = data.includes("SenderSourceConstraints");
  if (!ssc && !data.includes("AudioSourcesMap")) return null;
  let msg: unknown;
  try {
    msg = JSON.parse(data);
  } catch {
    return null;
  }
  if (!msg || typeof msg !== "object") return null;
  const m = msg as Record<string, unknown>;
  if (m.colibriClass === "SenderSourceConstraints") {
    const endpointId = endpointIdFromSourceName(m.sourceName);
    return endpointId ? { kind: "local-endpoint", endpointId } : null;
  }
  if (m.colibriClass === "AudioSourcesMap" && Array.isArray(m.mappedSources)) {
    const sources: Array<{ ssrc: number; owner: string }> = [];
    for (const entry of m.mappedSources.slice(0, MAX_MAPPED_SOURCES)) {
      if (!entry || typeof entry !== "object") continue;
      const { ssrc, owner } = entry as Record<string, unknown>;
      if (typeof ssrc !== "number" || !Number.isInteger(ssrc) || ssrc < 0 || ssrc > 0xffffffff) continue;
      if (typeof owner !== "string" || !ENDPOINT_ID_RE.test(owner)) continue;
      sources.push({ ssrc, owner });
    }
    return sources.length > 0 ? { kind: "audio-sources", sources } : null;
  }
  return null;
}

/** The local endpoint id, once this realm has seen it on the bridge channel
 * (a SenderSourceConstraints message, or the colibri-ws URL). */
export function colibriLocalEndpointId(): string | null {
  try {
    return cw().__earsJitsiLocalEndpoint ?? null;
  } catch {
    return null;
  }
}

/** The endpoint the bridge last said sends on `ssrc`, or null. */
export function colibriAudioOwner(ssrc: number): string | null {
  try {
    return cw().__earsJitsiAudioOwners?.get(ssrc) ?? null;
  } catch {
    return null;
  }
}

/**
 * Register the one callback told when the local id or a slot owner changes.
 * Latest registration wins, as with rtc-hook's setCollectionsListener: the
 * current epoch's adapter registers, and a disposed one unregisters only if it
 * is still the registered one (pass the same function back with `null`).
 */
export function setBridgeListener(listener: (() => void) | null, previous?: () => void): void {
  const g = cw();
  if (listener) g.__earsJitsiBridgeListener = listener;
  else if (!previous || g.__earsJitsiBridgeListener === previous) delete g.__earsJitsiBridgeListener;
}

function notifyBridgeListener(): void {
  try {
    cw().__earsJitsiBridgeListener?.();
  } catch {
    // identity is best-effort; a listener never affects the page's channel
  }
}

function noteLocalEndpoint(id: string, via: string): boolean {
  const g = cw();
  if (g.__earsJitsiLocalEndpoint === id) return false;
  g.__earsJitsiLocalEndpoint = id;
  console.debug(`[ears][jitsi] local endpoint id from the bridge channel (${via}): ${id}`);
  return true;
}

/** Apply one bridge message to the shared state. Exported for tests; the
 * channel and socket observers are the only callers. Newest values win: a
 * rejoin in the same page gets a fresh endpoint id, and the bridge reuses
 * slots for new owners. */
export function noteBridgeMessage(data: unknown): void {
  const msg = parseBridgeMessage(data);
  if (!msg) return;
  let changed = false;
  if (msg.kind === "local-endpoint") {
    changed = noteLocalEndpoint(msg.endpointId, "SenderSourceConstraints");
  } else {
    const g = cw();
    const owners = (g.__earsJitsiAudioOwners ??= new Map());
    for (const { ssrc, owner } of msg.sources) {
      if (owners.get(ssrc) === owner) continue;
      owners.delete(ssrc); // re-insert so eviction drops the stalest slot first
      owners.set(ssrc, owner);
      changed = true;
      console.debug(`[ears][jitsi] bridge audio slot ssrc ${ssrc} → ${owner}`);
    }
    while (owners.size > MAX_AUDIO_OWNERS) owners.delete(owners.keys().next().value!);
  }
  if (changed) notifyBridgeListener();
}

/** What the observers need from a channel or socket. */
export interface MessageSource {
  addEventListener(type: "message", listener: (ev: { data: unknown }) => void): void;
}

/** Watch one bridge data channel's messages. rtc-hook.ts calls this for each
 * channel labelled JVB_DATA_CHANNEL_LABEL, from its creation. */
export function observeBridgeDataChannel(channel: MessageSource): void {
  channel.addEventListener("message", (ev) => {
    try {
      noteBridgeMessage(ev.data);
    } catch {
      // identity is best-effort; it never affects the page's channel
    }
  });
}

/** Record a socket URL. Exported for tests; the wrap is the only caller. The
 * newest socket wins: a rejoin in the same page gets a fresh endpoint id.
 * True when the URL is a colibri-ws URL. */
export function noteColibriSocket(url: string | null | undefined): boolean {
  const id = parseColibriEndpointId(url);
  if (!id) return false;
  if (noteLocalEndpoint(id, "colibri-ws URL")) notifyBridgeListener();
  return true;
}

/** Wrap the WebSocket constructor once per realm to see colibri-ws sockets:
 * their URL (the local id) and their messages (the same parser as the data
 * channel, for deployments that run the bridge channel over a socket). */
export function installColibriSocketWatch(): void {
  const g = cw();
  if (g.__earsColibriWatch) return;
  const Original = g.WebSocket;
  if (typeof Original !== "function") return;
  g.__earsColibriWatch = true;

  function Wrapped(this: unknown, ...args: unknown[]): WebSocket {
    const ws = new (Original as unknown as new (...a: unknown[]) => WebSocket)(...args);
    try {
      if (noteColibriSocket(ws.url)) observeBridgeDataChannel(ws);
    } catch {
      // identity is best-effort; it never affects the page's socket
    }
    return ws; // returning the real socket supersedes `this`
  }

  Wrapped.prototype = Original.prototype; // instanceof stays true
  Object.setPrototypeOf(Wrapped, Original); // inherit statics (OPEN, CLOSED…)
  Object.defineProperty(Wrapped, "__earsWrapped", { value: true, enumerable: false });
  g.WebSocket = Wrapped as unknown as typeof WebSocket;
}
