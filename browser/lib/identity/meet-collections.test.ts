import { gzipSync } from "node:zlib";
import { describe, expect, it } from "vitest";
import { inflateGzip, parseCollectionsMessage, readStringAtPath, readVarintAtPath } from "./meet-collections";

// NOTE on fixtures, corrected 2026-07-19 after live verification: the
// implementation prompt's one "known-good" gzip hex fixture (claimed to
// decode to device 377, flag 0) does NOT decode to that — gunzipping it
// yields 13 bytes with no device-id string. That earlier led us to flag it as
// fabricated. Live testing against a real 3-participant Meet call showed
// otherwise: the exact same 33-byte message is the very first message Meet
// sends on the "collections" channel after it opens (captured live,
// byte-for-byte identical). It's real, just not a speaking-turn message —
// some other small handshake/sync frame. The prompt's fixture wasn't
// fabricated, it was mislabeled. parseCollectionsMessage correctly returns
// null for it either way (not every collections message is a speaking-turn
// message; anything that doesn't match the two known paths is defensively
// dropped), so this doesn't change any implementation, only this comment. See
// journal for the live-verification session that found this.
//
// The `real captured fixtures` describe block below uses genuine wire bytes
// captured from that live call (2 devices × flag 0/1 = 4 messages), which is
// what actually caught a real bug: the speaking-flag path documented in
// journal #49 (1.2.3.10.1) was missing a nesting level — the real path is
// 1.2.3.2.10.1 (see meet-collections.ts's header comment). The synthetic
// fixtures further down build messages by hand at the corrected path, useful
// for exercising edge cases the live call didn't happen to produce (absent
// fields, out-of-range flags, corruption) — but the real fixtures are what
// should be trusted first if the two ever disagree.

function encodeVarint(n: bigint): number[] {
  const out: number[] = [];
  let v = n;
  do {
    let byte = Number(v & 0x7fn);
    v >>= 7n;
    if (v > 0n) byte |= 0x80;
    out.push(byte);
  } while (v > 0n);
  return out;
}

function tag(fieldNumber: number, wireType: number): number[] {
  return encodeVarint(BigInt((fieldNumber << 3) | wireType));
}

function lenDelim(fieldNumber: number, payload: number[]): number[] {
  return [...tag(fieldNumber, 2), ...encodeVarint(BigInt(payload.length)), ...payload];
}

function varintField(fieldNumber: number, value: number): number[] {
  return [...tag(fieldNumber, 0), ...encodeVarint(BigInt(value))];
}

function stringField(fieldNumber: number, value: string): number[] {
  return lenDelim(fieldNumber, Array.from(new TextEncoder().encode(value)));
}

/**
 * Build a synthetic message shaped like the live-verified schema: device id
 * and the speaking flag are both fields *inside* the same per-device record
 * (field 2, nested under field 3) — the flag is not a sibling of that record.
 */
function buildMessage(opts: { deviceId?: string; participantNumber?: string; flag?: number }): Uint8Array {
  const field2Parts: number[] = [];
  if (opts.participantNumber !== undefined) field2Parts.push(...stringField(4, opts.participantNumber));
  if (opts.deviceId !== undefined) field2Parts.push(...stringField(6, opts.deviceId));
  if (opts.flag !== undefined) field2Parts.push(...lenDelim(10, varintField(1, opts.flag)));

  const field3Parts: number[] = [];
  if (field2Parts.length) field3Parts.push(...lenDelim(2, field2Parts));

  const field2 = lenDelim(3, field3Parts);
  const field1Inner = lenDelim(2, field2);
  const root = lenDelim(1, field1Inner);
  return Uint8Array.from(root);
}

function gzipOf(bytes: Uint8Array): ArrayBuffer {
  const buf = gzipSync(Buffer.from(bytes));
  return buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
}

const DEVICE_ID_PATH = [1, 2, 3, 2, 6];
const SPEAKING_FLAG_PATH = [1, 2, 3, 2, 10, 1];

// ── Real captured fixtures (live-verified 2026-07-19) ───────────────────────
//
// Raw wire bytes (gzip, as received on the "collections" RTCDataChannel),
// captured from a real 3-participant Meet call while manually unmuting two
// non-self participants in turn and watching the flag flip. These are the
// actual bytes, not synthetic — this is what first caught the missing
// nesting level in the speaking-flag path (see meet-collections.ts's header
// comment). Keep these forever as a regression guard: if a future Meet build
// changes the schema, these are the canonical "this is what a real message
// looked like on 2026-07-19" reference.
const REAL_FIXTURES = {
  device444_flag0: [
    31, 139, 8, 0, 0, 0, 0, 0, 0, 0, 227, 10, 21, 10, 150, 10, 228, 226, 224, 232, 189, 118, 224, 248, 134, 247, 233,
    66, 174, 28, 140, 2, 140, 74, 92, 70, 134, 134, 102, 70, 150, 134, 198, 134, 134, 70, 242, 197, 5, 137, 201, 169,
    197, 250, 233, 25, 89, 110, 85, 101, 38, 137, 217, 85, 145, 78, 250, 41, 169, 101, 153, 32, 65, 19, 19, 19, 39,
    54, 142, 247, 83, 39, 124, 100, 247, 98, 18, 96, 12, 98, 226, 96, 40, 98, 226, 96, 0, 0, 152, 85, 29, 119, 87, 0,
    0, 0,
  ],
  device444_flag1: [
    31, 139, 8, 0, 0, 0, 0, 0, 0, 0, 227, 10, 21, 10, 150, 10, 228, 226, 224, 232, 187, 118, 224, 248, 134, 247, 233,
    66, 174, 28, 140, 2, 140, 74, 92, 70, 134, 134, 102, 70, 150, 134, 198, 134, 134, 70, 242, 197, 5, 137, 201, 169,
    197, 250, 233, 25, 89, 110, 85, 101, 38, 137, 217, 85, 145, 78, 250, 41, 169, 101, 153, 32, 65, 19, 19, 19, 39,
    54, 142, 247, 83, 39, 124, 100, 247, 98, 18, 96, 12, 98, 226, 96, 44, 98, 226, 96, 0, 0, 6, 64, 233, 151, 87, 0,
    0, 0,
  ],
  device445_flag0: [
    31, 139, 8, 0, 0, 0, 0, 0, 0, 0, 227, 10, 21, 10, 150, 10, 228, 226, 224, 232, 191, 118, 224, 248, 134, 247, 233,
    66, 174, 28, 140, 2, 140, 74, 92, 198, 150, 22, 230, 134, 230, 166, 230, 70, 166, 70, 242, 197, 5, 137, 201, 169,
    197, 250, 233, 25, 89, 110, 85, 101, 38, 137, 217, 85, 145, 78, 250, 41, 169, 101, 153, 32, 65, 19, 19, 83, 39,
    54, 142, 181, 159, 230, 190, 229, 243, 98, 18, 96, 12, 98, 226, 96, 40, 98, 226, 96, 0, 0, 127, 95, 178, 44, 87,
    0, 0, 0,
  ],
  device445_flag1: [
    31, 139, 8, 0, 0, 0, 0, 0, 0, 0, 227, 10, 21, 10, 150, 10, 228, 226, 224, 152, 112, 237, 192, 241, 13, 239, 211,
    133, 92, 57, 24, 5, 24, 149, 184, 140, 45, 45, 204, 13, 205, 77, 205, 141, 76, 141, 228, 139, 11, 18, 147, 83,
    139, 245, 211, 51, 178, 220, 170, 202, 76, 18, 179, 171, 34, 157, 244, 83, 82, 203, 50, 65, 130, 38, 38, 166, 78,
    108, 28, 107, 63, 205, 125, 203, 231, 197, 36, 192, 24, 196, 196, 193, 88, 196, 196, 193, 0, 0, 194, 224, 60,
    214, 87, 0, 0, 0,
  ],
} as const;

function realFixtureBuffer(bytes: readonly number[]): ArrayBuffer {
  return Uint8Array.from(bytes).buffer;
}

describe("parseCollectionsMessage (real captured fixtures, live 2026-07-19)", () => {
  it("device 444, flag 0 (turn start) → speaking=true", async () => {
    const parsed = await parseCollectionsMessage(realFixtureBuffer(REAL_FIXTURES.device444_flag0));
    expect(parsed).toEqual({ deviceId: "spaces/ghjFzv4akzYB/devices/444", speaking: true });
  });

  it("device 444, flag 1 (turn end) → speaking=false", async () => {
    const parsed = await parseCollectionsMessage(realFixtureBuffer(REAL_FIXTURES.device444_flag1));
    expect(parsed).toEqual({ deviceId: "spaces/ghjFzv4akzYB/devices/444", speaking: false });
  });

  it("device 445, flag 0 (turn start) → speaking=true", async () => {
    const parsed = await parseCollectionsMessage(realFixtureBuffer(REAL_FIXTURES.device445_flag0));
    expect(parsed).toEqual({ deviceId: "spaces/ghjFzv4akzYB/devices/445", speaking: true });
  });

  it("device 445, flag 1 (turn end) → speaking=false", async () => {
    const parsed = await parseCollectionsMessage(realFixtureBuffer(REAL_FIXTURES.device445_flag1));
    expect(parsed).toEqual({ deviceId: "spaces/ghjFzv4akzYB/devices/445", speaking: false });
  });

  it("the real captured channel-open handshake message (33B) parses as null, not a crash", async () => {
    // The prompt's original fixture — real bytes, not a speaking-turn message.
    const handshake = [
      31, 139, 8, 0, 0, 0, 0, 0, 0, 0, 227, 226, 22, 226, 204, 98, 239, 98, 100, 225, 98, 226, 96, 4, 0, 4, 158, 227,
      76, 13, 0, 0, 0,
    ];
    await expect(parseCollectionsMessage(realFixtureBuffer(handshake))).resolves.toBeNull();
  });
});

describe("parseCollectionsMessage (end to end)", () => {
  it("extracts device id and speaking=true for flag 0 (turn start)", async () => {
    const msg = buildMessage({ deviceId: "spaces/SNeKtGxvmH0B/devices/377", participantNumber: "112470408", flag: 0 });
    const parsed = await parseCollectionsMessage(gzipOf(msg));
    expect(parsed).toEqual({ deviceId: "spaces/SNeKtGxvmH0B/devices/377", speaking: true });
  });

  it("extracts device id and speaking=false for flag 1 (turn end)", async () => {
    const msg = buildMessage({ deviceId: "spaces/SNeKtGxvmH0B/devices/378", flag: 1 });
    const parsed = await parseCollectionsMessage(gzipOf(msg));
    expect(parsed).toEqual({ deviceId: "spaces/SNeKtGxvmH0B/devices/378", speaking: false });
  });

  it("returns null when the device id field is absent", async () => {
    const msg = buildMessage({ flag: 0 });
    expect(await parseCollectionsMessage(gzipOf(msg))).toBeNull();
  });

  it("returns null when the speaking flag field is absent", async () => {
    const msg = buildMessage({ deviceId: "spaces/x/devices/1" });
    expect(await parseCollectionsMessage(gzipOf(msg))).toBeNull();
  });

  it("returns null for a flag value outside {0,1}", async () => {
    const msg = buildMessage({ deviceId: "spaces/x/devices/1", flag: 7 });
    expect(await parseCollectionsMessage(gzipOf(msg))).toBeNull();
  });

  it("returns null, never throws, for a truncated gzip buffer", async () => {
    const full = gzipOf(buildMessage({ deviceId: "spaces/x/devices/1", flag: 0 }));
    const truncated = full.slice(0, 6);
    await expect(parseCollectionsMessage(truncated)).resolves.toBeNull();
  });

  it("returns null, never throws, when the first bytes aren't the gzip magic", async () => {
    const bytes = new Uint8Array([0x00, 0x01, 0x02, 0x03, 0x04, 0x05]);
    await expect(parseCollectionsMessage(bytes.buffer)).resolves.toBeNull();
  });

  it("returns null, never throws, for valid gzip wrapping a non-protobuf payload", async () => {
    const text = Buffer.from("this is plain text, not protobuf at all", "utf-8");
    const gz = gzipSync(text);
    await expect(parseCollectionsMessage(gz.buffer.slice(gz.byteOffset, gz.byteOffset + gz.byteLength))).resolves.toBeNull();
  });

  it("returns null, never throws, for an empty buffer", async () => {
    await expect(parseCollectionsMessage(new ArrayBuffer(0))).resolves.toBeNull();
  });
});

describe("inflateGzip", () => {
  it("round-trips a gzip buffer", async () => {
    const payload = new Uint8Array([1, 2, 3, 4, 5]);
    const out = await inflateGzip(gzipOf(payload));
    expect(out).toEqual(payload);
  });

  it("returns null for non-gzip input", async () => {
    expect(await inflateGzip(new Uint8Array([1, 2, 3]).buffer)).toBeNull();
  });
});

describe("readStringAtPath / readVarintAtPath (pure walker, no gzip)", () => {
  it("reads a string at the documented device-id path", () => {
    const msg = buildMessage({ deviceId: "spaces/abc/devices/42" });
    expect(readStringAtPath(msg, DEVICE_ID_PATH)).toBe("spaces/abc/devices/42");
  });

  it("reads a varint at the documented speaking-flag path", () => {
    const msg = buildMessage({ flag: 1 });
    expect(readVarintAtPath(msg, SPEAKING_FLAG_PATH)).toBe(1);
  });

  it("returns null when an intermediate path element is the wrong wire type", () => {
    // field 3 present as a varint instead of an embedded message — can't descend.
    const bytes = Uint8Array.from([...tag(3, 0), ...encodeVarint(5n)]);
    const wrapped = Uint8Array.from([...lenDelim(2, Array.from(bytes)), ...[]]);
    const root = Uint8Array.from(lenDelim(1, Array.from(wrapped)));
    expect(readStringAtPath(root, DEVICE_ID_PATH)).toBeNull();
  });

  it("returns null on a truncated varint (continuation bit never clears)", () => {
    const bytes = new Uint8Array([0x8a, 0xff, 0xff, 0xff]); // tag byte with continuation bit set forever
    expect(readStringAtPath(bytes, DEVICE_ID_PATH)).toBeNull();
    expect(readVarintAtPath(bytes, SPEAKING_FLAG_PATH)).toBeNull();
  });

  it("returns null when a length-delimited field's length exceeds the buffer", () => {
    const bytes = Uint8Array.from([...tag(1, 2), 0xff, 0x01]); // claims 127 bytes, buffer has 0
    expect(readStringAtPath(bytes, [1])).toBeNull();
  });

  it("returns null on an empty buffer", () => {
    expect(readStringAtPath(new Uint8Array(0), DEVICE_ID_PATH)).toBeNull();
    expect(readVarintAtPath(new Uint8Array(0), SPEAKING_FLAG_PATH)).toBeNull();
  });

  it("returns null for a non-UTF8 string field", () => {
    const invalid = Uint8Array.from([...tag(6, 2), 2, 0xff, 0xfe]); // invalid UTF-8 bytes
    expect(readStringAtPath(invalid, [6])).toBeNull();
  });

  it("returns null when asking for a string but the field is a varint", () => {
    const msg = Uint8Array.from(varintField(6, 5));
    expect(readStringAtPath(msg, [6])).toBeNull();
  });

  it("returns null when asking for a varint but the field is length-delimited", () => {
    const msg = Uint8Array.from(stringField(1, "x"));
    expect(readVarintAtPath(msg, [1])).toBeNull();
  });

  it("uses the last occurrence when a field number repeats (protobuf semantics)", () => {
    const msg = Uint8Array.from([...varintField(1, 0), ...varintField(1, 1)]);
    expect(readVarintAtPath(msg, [1])).toBe(1);
  });
});
