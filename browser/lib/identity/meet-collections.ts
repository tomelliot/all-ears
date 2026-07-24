// Defensive, dependency-free extraction of two specific fields from Meet's
// private "collections" RTCDataChannel wire format. This is a private,
// undocumented, unversioned format — every read defaults to "might be
// garbage": any parse failure (wrong tag, truncated buffer, missing path,
// non-gzip payload) returns null, never throws. See
// docs/specs/browser/extension.md's MUST-NOT #6 exception and
// docs/specs/browser/extension.md (the collections exception) before
// decoding anything beyond the two fields below — that's the whole point of
// the exception being narrow.
//
// Wire shape: gzip-compressed protobuf. Field-number path from the message
// root:
//   1.2.3.2.6    string  device id, "spaces/<space>/devices/<device>"
//   1.2.3.2.10.1 varint  mute flag: 0 = mic open (unmute), 1 = muted
//
// LIVE-VERIFIED 2026-07-19 against a real 3-participant Meet call (journal
// follow-up entries after #54) — this corrected the flag path from what
// journal #49 originally documented (1.2.3.10.1, four levels). The real
// wire nests the flag one level deeper, inside the same per-device record
// (field 2) that holds the device id, not as a sibling of it under field 3:
// 1.2.3.2.10.1 (five levels). #49's device-id path was already correct.
//
// RE-INTERPRETED 2026-07-24 (dev/captures/2026-07-24-meet-collections-drift.md):
// the flag is a MUTE-STATE EDGE, not a speaking-turn indicator. A controlled
// two-account call showed zero collections messages during minutes of
// conversation with clean turn-taking, and one message per deliberate
// mute/unmute toggle (flag 0 on unmute, 1 on mute, decoded offline from raw
// captures). The 2026-07-19 verification watched manual unmutes, which is why
// the flag looked like a turn indicator. Whether per-turn events ever existed
// on this channel or the 07-19 run was always seeing mute edges is unknowable
// now; what matters is the current build only emits mute edges. Identity
// correlation therefore pairs these edges against track-level unmute events
// (see meet.ts), not against decoded-audio speaking onsets.
//
// (1.2.3.2.4, the secondary participant-number string, is documented in the
// prompt but unused — identify() only needs the device id.)

export interface CollectionsMuteEvent {
  deviceId: string;
  /** true = mic open (flag 0, sent on unmute and on joining unmuted), false = muted (flag 1). */
  micOpen: boolean;
}

const DEVICE_ID_PATH = [1, 2, 3, 2, 6] as const;
const MUTE_FLAG_PATH = [1, 2, 3, 2, 10, 1] as const;

/** Parse a raw datachannel message payload end to end. Never throws. */
export async function parseCollectionsMessage(raw: ArrayBuffer): Promise<CollectionsMuteEvent | null> {
  try {
    const inflated = await inflateGzip(raw);
    if (!inflated) return null;
    const deviceId = readStringAtPath(inflated, DEVICE_ID_PATH);
    if (!deviceId) return null;
    const flag = readVarintAtPath(inflated, MUTE_FLAG_PATH);
    if (flag !== 0 && flag !== 1) return null;
    return { deviceId, micOpen: flag === 0 };
  } catch {
    return null;
  }
}

function looksLikeGzip(bytes: Uint8Array): boolean {
  return bytes.length >= 4 && bytes[0] === 0x1f && bytes[1] === 0x8b && bytes[2] === 0x08 && bytes[3] === 0x00;
}

/** gzip → raw bytes, or null on anything that isn't a well-formed gzip stream. */
export async function inflateGzip(buf: ArrayBuffer): Promise<Uint8Array | null> {
  try {
    const bytes = new Uint8Array(buf);
    if (!looksLikeGzip(bytes)) return null;
    const DS = (globalThis as { DecompressionStream?: typeof DecompressionStream }).DecompressionStream;
    if (!DS) return null;
    const stream = new Blob([bytes]).stream().pipeThrough(new DS("gzip"));
    return new Uint8Array(await new Response(stream).arrayBuffer());
  } catch {
    return null;
  }
}

// ── Minimal protobuf wire-format walker ─────────────────────────────────────
//
// Hand-rolled on purpose (Task 1): the surface we need is tiny (varint +
// length-delimited fields, walked by a fixed field-number path) and a real
// protobuf library is unwarranted build weight for reading two fields out of
// a format we don't even have a .proto for.

interface Field {
  wireType: number;
  varint?: bigint; // wireType 0
  bytes?: Uint8Array; // wireType 2
}

/** Parse one message level into its fields, keyed by field number. Returns
 * null on any structural inconsistency (truncated varint, length past the
 * buffer end, unsupported/deprecated wire type). */
function parseFields(bytes: Uint8Array): Map<number, Field[]> | null {
  const fields = new Map<number, Field[]>();
  let offset = 0;
  while (offset < bytes.length) {
    const tagRes = readVarint(bytes, offset);
    if (!tagRes) return null;
    const [tag, tagLen] = tagRes;
    offset += tagLen;
    const fieldNumber = Number(tag >> 3n);
    const wireType = Number(tag & 0x7n);
    if (fieldNumber <= 0) return null;

    let field: Field;
    if (wireType === 0) {
      const vRes = readVarint(bytes, offset);
      if (!vRes) return null;
      field = { wireType, varint: vRes[0] };
      offset += vRes[1];
    } else if (wireType === 2) {
      const lenRes = readVarint(bytes, offset);
      if (!lenRes) return null;
      offset += lenRes[1];
      const length = Number(lenRes[0]);
      if (!Number.isSafeInteger(length) || length < 0 || offset + length > bytes.length) return null;
      field = { wireType, bytes: bytes.slice(offset, offset + length) };
      offset += length;
    } else if (wireType === 1) {
      if (offset + 8 > bytes.length) return null;
      offset += 8;
      continue; // fixed64 — not on either path we need, skip
    } else if (wireType === 5) {
      if (offset + 4 > bytes.length) return null;
      offset += 4;
      continue; // fixed32 — skip
    } else {
      return null; // wire types 3/4 (deprecated groups) or unknown — treat as corrupt
    }

    const list = fields.get(fieldNumber);
    if (list) list.push(field);
    else fields.set(fieldNumber, [field]);
  }
  return fields;
}

/** Varint at `offset`. Returns [value, byteLength] or null if truncated/malformed. */
function readVarint(bytes: Uint8Array, offset: number): [bigint, number] | null {
  let result = 0n;
  let shift = 0n;
  let i = offset;
  while (i < bytes.length) {
    const byte = bytes[i]!;
    result |= BigInt(byte & 0x7f) << shift;
    i++;
    if ((byte & 0x80) === 0) return [result, i - offset];
    shift += 7n;
    if (shift > 63n) return null; // longer than any real varint we expect — corrupt
  }
  return null; // ran off the end mid-varint
}

/** Walk down `path`, descending into embedded messages for every element but
 * the last, whose raw field is returned. null on any missing/mismatched step.
 * Protobuf semantics: the last occurrence of a field number wins. */
function walkToField(bytes: Uint8Array, path: readonly number[]): Field | null {
  let current = bytes;
  for (let i = 0; i < path.length; i++) {
    const fields = parseFields(current);
    if (!fields) return null;
    const list = fields.get(path[i]!);
    if (!list || list.length === 0) return null;
    const field = list[list.length - 1]!;
    if (i === path.length - 1) return field;
    if (field.wireType !== 2 || !field.bytes) return null; // must be an embedded message to descend
    current = field.bytes;
  }
  return null;
}

export function readStringAtPath(bytes: Uint8Array, path: readonly number[]): string | null {
  try {
    const field = walkToField(bytes, path);
    if (!field || field.wireType !== 2 || !field.bytes) return null;
    const s = new TextDecoder("utf-8", { fatal: true }).decode(field.bytes);
    return s.length > 0 ? s : null;
  } catch {
    return null;
  }
}

export function readVarintAtPath(bytes: Uint8Array, path: readonly number[]): number | null {
  try {
    const field = walkToField(bytes, path);
    if (!field || field.wireType !== 0 || field.varint === undefined) return null;
    if (field.varint < 0n || field.varint > 0xffffffffn) return null; // sanity bound; flag is 0/1
    return Number(field.varint);
  } catch {
    return null;
  }
}

// ── Debug-only structure dump ───────────────────────────────────────────────
//
// Not used by parseCollectionsMessage — this is a generic recursive
// pretty-printer for inspecting *any* field of a collections message during
// live debugging (rtc-hook.ts's debug-only channel tracer calls this when
// __earsDebugChannels is set). Distinct from the narrow production walker
// above: it shows every field, including ones outside the two paths this
// module is scoped to decode in production. Never call this outside a
// debug/investigation context — reading it is fine (it's just printing wire
// structure back at a developer), but nothing downstream should ever depend
// on a field this prints unless it's promoted through the same review the
// two production paths went through (see extension.md's MUST-NOT #6 exception).
export function debugDecodeStructure(bytes: Uint8Array, depth = 0): string[] {
  const out: string[] = [];
  const indent = "  ".repeat(depth);
  let offset = 0;
  while (offset < bytes.length) {
    const tagRes = readVarint(bytes, offset);
    if (!tagRes) {
      out.push(`${indent}[trailing ${bytes.length - offset} bytes, bad varint]`);
      break;
    }
    const [tag, tagLen] = tagRes;
    offset += tagLen;
    const fieldNumber = Number(tag >> 3n);
    const wireType = Number(tag & 0x7n);

    if (wireType === 0) {
      const v = readVarint(bytes, offset);
      if (!v) break;
      out.push(`${indent}${fieldNumber} (varint) = ${v[0]}`);
      offset += v[1];
    } else if (wireType === 2) {
      const l = readVarint(bytes, offset);
      if (!l) break;
      offset += l[1];
      const len = Number(l[0]);
      if (!Number.isSafeInteger(len) || len < 0 || offset + len > bytes.length) {
        out.push(`${indent}${fieldNumber} (LEN) truncated`);
        break;
      }
      const sub = bytes.slice(offset, offset + len);
      offset += len;
      let asString: string | null = null;
      try {
        const s = new TextDecoder("utf-8", { fatal: true }).decode(sub);
        if (/^[\x20-\x7e]*$/.test(s) && s.length > 0) asString = s;
      } catch {
        // not valid UTF-8 — leave asString null, fall through to sub-message decode
      }
      out.push(`${indent}${fieldNumber} (LEN len=${len})${asString ? ` STRING="${asString}"` : ""}`);
      if (!asString) out.push(...debugDecodeStructure(sub, depth + 1));
    } else if (wireType === 1) {
      if (offset + 8 > bytes.length) break;
      out.push(`${indent}${fieldNumber} (fixed64)`);
      offset += 8;
    } else if (wireType === 5) {
      if (offset + 4 > bytes.length) break;
      out.push(`${indent}${fieldNumber} (fixed32)`);
      offset += 4;
    } else {
      out.push(`${indent}[unknown wiretype ${wireType}]`);
      break;
    }
  }
  return out;
}
