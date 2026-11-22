// The local participant's Jitsi endpoint id, read from the URL of the page's
// bridge-channel WebSocket. Read from lib-jitsi-meet and jitsi-videobridge
// sources (2026-11-22). Not yet verified on a live call.
//
// Why the socket URL. Remote tracks name their sender because LocalSdpMunger
// rewrites the MSID — but only in the SDP lib-jitsi-meet *signals*
// (TraceablePeerConnection's `localDescription` getter). The native
// `RTCPeerConnection.localDescription` and the sender's MediaStream keep the
// browser's own random ids, so nothing on our own peer connections names us.
// The bridge channel does: Jicofo hands each endpoint its own colibri-ws URL
// (`<web-socket>` in session-initiate), which the videobridge mints as
// `<base>/colibri-ws/<serverId>/<conferenceId>/<endpointId>?pwd=<pwd>`
// (ColibriWebSocketService.getColibriWebSocketUrls). A page only ever opens
// that socket for its own endpoint, so the last path segment is you.
//
// The constructor wrap is passive, like the RTCPeerConnection one: it builds
// the real socket, reads its `url`, and returns the native object untouched.
// It never reads messages, and keeps only the endpoint id — never the URL,
// whose query carries the channel password. Installed only on Jitsi and `web`
// pages, at document_start, before lib-jitsi-meet opens the channel (it looks
// `WebSocket` up at call time, so a later install would still work, but there
// is no reason to wait).

interface ColibriWindow {
  WebSocket: typeof WebSocket;
  __earsColibriWatch?: boolean;
  __earsJitsiLocalEndpoint?: string;
}

function cw(): ColibriWindow {
  return window as unknown as ColibriWindow;
}

// `/colibri-ws/<serverId>/<conferenceId>/<endpointId>`, anywhere in the path
// so a reverse-proxy prefix still matches. Relay sockets use
// `/colibri-relay-ws/` and never match.
const COLIBRI_PATH_RE = /\/colibri-ws\/[^/]+\/[^/]+\/([^/]+)\/?$/;
// Same character set the MSID parser accepts for an endpoint id.
const ENDPOINT_ID_RE = /^[A-Za-z0-9_.~-]{1,256}$/;

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

/** The local endpoint id, once this realm has seen a colibri-ws socket open.
 * Shared on `window` so every capture epoch's adapter reads the same value. */
export function colibriLocalEndpointId(): string | null {
  try {
    return cw().__earsJitsiLocalEndpoint ?? null;
  } catch {
    return null;
  }
}

/** Record a socket URL. Exported for tests; the wrap is the only caller. The
 * newest socket wins: a rejoin in the same page gets a fresh endpoint id. */
export function noteColibriSocket(url: string | null | undefined): void {
  const id = parseColibriEndpointId(url);
  if (!id) return;
  const g = cw();
  if (g.__earsJitsiLocalEndpoint === id) return;
  g.__earsJitsiLocalEndpoint = id;
  console.debug(`[ears][jitsi] local endpoint id from the bridge channel: ${id}`);
}

/** Wrap the WebSocket constructor once per realm to see colibri-ws URLs. */
export function installColibriSocketWatch(): void {
  const g = cw();
  if (g.__earsColibriWatch) return;
  const Original = g.WebSocket;
  if (typeof Original !== "function") return;
  g.__earsColibriWatch = true;

  function Wrapped(this: unknown, ...args: unknown[]): WebSocket {
    const ws = new (Original as unknown as new (...a: unknown[]) => WebSocket)(...args);
    try {
      noteColibriSocket(ws.url);
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
