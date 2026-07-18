// Single source of truth for messages crossing the four contexts.
//
//   injected.ts ──win──► content.ts ──rt──► background.ts
//    (MAIN world)         (isolated)         (SW / bg page)
//
// "win" = window.postMessage (main↔isolated). "rt" = chrome.runtime (browser.*).

/** Marker on every window.postMessage envelope crossing the world boundary. */
export const EARS_MARKER = "__ears" as const;

/** Platform tag, mirrored into the earsd `browser:<platform>:<participant>` label. */
export type Platform = "meet" | "zoom" | "teams";

/** Stable within a call; used verbatim as the earsd source-label suffix. */
export type ParticipantId = string;

/**
 * Main-world → isolated-world messages. PCM rides the same channel as a
 * transferable Int16Array (structured-cloned across the world boundary).
 */
export type MainMessage =
  | { kind: "participant-joined"; platform: Platform; participantId: ParticipantId; generation: number; displayName?: string }
  | { kind: "participant-left"; participantId: ParticipantId; generation: number }
  | { kind: "pcm"; participantId: ParticipantId; generation: number; samples: Int16Array }
  | { kind: "status"; text: string };

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
export type ControlMessage = { kind: "capture-state"; enabled: boolean };

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
  | { type: "pcm"; participantId: ParticipantId; platform: Platform; b64: string }
  | { type: "left"; participantId: ParticipantId };

// ── earsd wire (background.ts → earsd) ───────────────────────────────────────

/** v1 always declares 16 kHz mono pcm_s16le; keys match earsd's AudioFormatSpec. */
export const INGEST_FORMAT = { sample_rate: 16000, channels: 1, encoding: "pcm_s16le" } as const;

/** earsd source labels are `[A-Za-z0-9._-]`; sanitize the participant suffix. */
export function sanitizeLabel(id: string): string {
  const cleaned = id.replace(/[^A-Za-z0-9._-]/g, "-").replace(/-+/g, "-").replace(/^-|-$/g, "");
  return cleaned || "unknown";
}

export function sourceLabel(platform: Platform, participantId: ParticipantId): string {
  return `browser:${platform}:${sanitizeLabel(participantId)}`;
}

/**
 * Binary PCM frame: [u8 idLen][stream_id ASCII][pcm_s16le bytes]. stream_id is
 * short (earsd assigns "s7"-style ids), so it always fits a u8 length.
 */
export function encodeBinaryFrame(streamId: string, pcm: Uint8Array): Uint8Array {
  const idBytes = new TextEncoder().encode(streamId);
  if (idBytes.length > 255) throw new Error(`stream_id too long: ${streamId}`);
  const out = new Uint8Array(1 + idBytes.length + pcm.length);
  out[0] = idBytes.length;
  out.set(idBytes, 1);
  out.set(pcm, 1 + idBytes.length);
  return out;
}
