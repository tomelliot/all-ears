import { beforeEach, describe, expect, it } from "vitest";
import { LinearResampler, MeetDecodeSource, RingBuffer, type MeetDecodeDeps } from "./audio-tap";
import type { EncodedAudioListener } from "./rtc-hook";

describe("LinearResampler", () => {
  it("halves the sample count at 2:1 (e.g. 48kHz → 24kHz)", () => {
    const r = new LinearResampler(48000, 24000);
    const input = new Float32Array(480).fill(1);
    const out = r.process(input);
    expect(out.length).toBeCloseTo(240, -1);
  });

  it("resamples 48kHz → 16kHz (the real Meet/decoder rate) to a third the length", () => {
    const r = new LinearResampler(48000, 16000);
    const input = new Float32Array(4800).fill(0.5);
    const out = r.process(input);
    expect(out.length).toBeCloseTo(1600, -1);
    for (const s of out) expect(s).toBeCloseTo(0.5, 5);
  });

  it("passes a constant signal through unchanged in value", () => {
    const r = new LinearResampler(44100, 16000);
    const input = new Float32Array(1000).fill(-0.25);
    const out = r.process(input);
    expect(out.length).toBeGreaterThan(0);
    for (const s of out) expect(s).toBeCloseTo(-0.25, 5);
  });

  it("is phase-continuous across chunks — splitting one signal into two calls yields the same tail as one call", () => {
    const full = new Float32Array(2000);
    for (let i = 0; i < full.length; i++) full[i] = Math.sin(i * 0.05);

    const whole = new LinearResampler(48000, 16000).process(full);

    const chunked = new LinearResampler(48000, 16000);
    const a = chunked.process(full.slice(0, 900));
    const b = chunked.process(full.slice(900));
    const combined = Float32Array.from([...a, ...b]);

    // Same total output length, and closely matching values (allowing for a
    // possible ±1 sample boundary rounding difference).
    expect(Math.abs(combined.length - whole.length)).toBeLessThanOrEqual(1);
    const n = Math.min(combined.length, whole.length);
    for (let i = 0; i < n; i++) {
      expect(combined[i]).toBeCloseTo(whole[i]!, 4);
    }
  });

  it("reuses correctly across independent source instances (standard vs. Meet decode)", () => {
    // Two frame sources feeding two different tracks must not share resampler
    // state — each TrackCapture owns its own instance.
    const a = new LinearResampler(48000, 16000);
    const b = new LinearResampler(16000, 16000);
    const outA = a.process(new Float32Array(480).fill(1));
    const outB = b.process(new Float32Array(160).fill(-1));
    expect(outA.every((s) => s === 1)).toBe(true);
    expect(outB.every((s) => s === -1)).toBe(true);
  });
});

describe("RingBuffer", () => {
  it("drains frames in push order", () => {
    const ring = new RingBuffer(4, "test");
    ring.push(Int16Array.from([1]));
    ring.push(Int16Array.from([2]));
    ring.push(Int16Array.from([3]));
    expect(ring.drain().map((f) => f[0])).toEqual([1, 2, 3]);
  });

  it("drain empties the buffer", () => {
    const ring = new RingBuffer(4, "test");
    ring.push(Int16Array.from([1]));
    ring.drain();
    expect(ring.drain()).toEqual([]);
  });

  it("drops the oldest frame on overflow, keeping the freshest", () => {
    const ring = new RingBuffer(2, "test");
    ring.push(Int16Array.from([1]));
    ring.push(Int16Array.from([2]));
    ring.push(Int16Array.from([3])); // overflow: drops [1]
    expect(ring.drain().map((f) => f[0])).toEqual([2, 3]);
  });

  it("never grows past capacity even under sustained overflow", () => {
    const ring = new RingBuffer(3, "test");
    for (let i = 0; i < 100; i++) ring.push(Int16Array.from([i]));
    const drained = ring.drain();
    expect(drained.length).toBe(3);
    expect(drained.map((f) => f[0])).toEqual([97, 98, 99]);
  });
});

// ── Meet decoder recovery (restart-in-place, bounded budget) ────────────────

// A fake WebCodecs AudioDecoder whose `error` callback the test drives on
// demand. Every construction (including a post-error rebuild) records itself.
class FakeDecoder {
  static instances: FakeDecoder[] = [];
  readonly error: (err: Error) => void;
  configured = false;
  closed = false;
  decoded: unknown[] = [];
  constructor(init: { output: (frame: unknown) => void; error: (err: Error) => void }) {
    this.error = init.error;
    FakeDecoder.instances.push(this);
  }
  configure(): void {
    this.configured = true;
  }
  decode(chunk: unknown): void {
    this.decoded.push(chunk);
  }
  close(): void {
    this.closed = true;
  }
}

class FakeChunk {
  constructor(readonly init: { type: string; timestamp: number; data: ArrayBuffer }) {}
}

const DECODING_ERROR = new Error("Decoding error.");
const aFrame = () => ({ data: new ArrayBuffer(2), timestamp: 0 });

describe("MeetDecodeSource decoder recovery", () => {
  let clock = 0;
  let listener: EncodedAudioListener | null;
  let subscribeCalls: Array<EncodedAudioListener | null>;
  let fatals: string[];
  let src: MeetDecodeSource;

  function makeSource(): MeetDecodeSource {
    const deps: MeetDecodeDeps = {
      decoderCtor: FakeDecoder as unknown as MeetDecodeDeps["decoderCtor"],
      chunkCtor: FakeChunk as unknown as MeetDecodeDeps["chunkCtor"],
      subscribe: (_track, l) => {
        listener = l;
        subscribeCalls.push(l);
      },
      now: () => clock,
    };
    const track = { id: "track-x" } as unknown as MediaStreamTrack;
    // Mirror TrackCapture.fail's wiring: a fatal error stops the source.
    const s = new MeetDecodeSource(track, () => {}, (reason) => {
      fatals.push(reason);
      s.stop();
    }, deps);
    return s;
  }

  beforeEach(() => {
    FakeDecoder.instances = [];
    clock = 0;
    listener = null;
    subscribeCalls = [];
    fatals = [];
    src = makeSource();
  });

  it("restarts the decoder in place on a single error — capture continues, not fatal", () => {
    src.start();
    expect(FakeDecoder.instances).toHaveLength(1);
    const first = FakeDecoder.instances[0]!;

    first.error(DECODING_ERROR);

    expect(fatals).toEqual([]); // recovered, no participant-left/joined churn
    expect(first.closed).toBe(true); // old decoder torn down
    expect(FakeDecoder.instances).toHaveLength(2); // fresh one built
    expect(FakeDecoder.instances[1]!.configured).toBe(true);

    // The same encoded-audio listener keeps feeding the fresh decoder.
    listener!(aFrame());
    expect(FakeDecoder.instances[1]!.decoded).toHaveLength(1);
    expect(subscribeCalls).toEqual([expect.any(Function)]); // never re-subscribed
  });

  it("treats a decode() throw the same as a decoder error (restart in place)", () => {
    class ThrowOnceDecoder extends FakeDecoder {
      override decode(chunk: unknown): void {
        // Throw only on the first (errored) instance; rebuilt ones decode fine.
        if (FakeDecoder.instances[0] === this) throw new Error("bad state");
        super.decode(chunk);
      }
    }
    const deps: MeetDecodeDeps = {
      decoderCtor: ThrowOnceDecoder as unknown as MeetDecodeDeps["decoderCtor"],
      chunkCtor: FakeChunk as unknown as MeetDecodeDeps["chunkCtor"],
      subscribe: (_t, l) => {
        listener = l;
      },
      now: () => clock,
    };
    const s = new MeetDecodeSource({ id: "t" } as unknown as MediaStreamTrack, () => {}, (r) => fatals.push(r), deps);
    s.start();
    listener!(aFrame()); // decode throws → restart, not fatal

    expect(fatals).toEqual([]);
    expect(FakeDecoder.instances).toHaveLength(2);
  });

  it("gives up (fatal exactly once) when the decoder keeps dying past the budget", () => {
    src.start();
    // Drive errors well past the 5-restart budget; each error hits the newest decoder.
    for (let i = 0; i < 12; i++) {
      FakeDecoder.instances.at(-1)!.error(DECODING_ERROR);
    }
    expect(fatals).toHaveLength(1);
    expect(fatals[0]).toContain("giving up");
    // 1 initial + exactly 5 restarts, then fatal (no further rebuilds).
    expect(FakeDecoder.instances).toHaveLength(6);
    // Fatal path stopped the source: the tee was unsubscribed.
    expect(subscribeCalls.at(-1)).toBeNull();
  });

  it("resets the restart budget once the sliding window passes", () => {
    src.start();
    for (let i = 0; i < 5; i++) FakeDecoder.instances.at(-1)!.error(DECODING_ERROR);
    expect(fatals).toEqual([]); // 5 restarts, still within budget

    clock = 31_000; // advance past the 30s window
    FakeDecoder.instances.at(-1)!.error(DECODING_ERROR);
    expect(fatals).toEqual([]); // fresh budget — restarted, not fatal
  });

  it("stays fatal when the decoder constructor is unavailable", () => {
    const deps: MeetDecodeDeps = {
      decoderCtor: undefined,
      chunkCtor: undefined,
      subscribe: () => {},
      now: () => 0,
    };
    const s = new MeetDecodeSource({ id: "t" } as unknown as MediaStreamTrack, () => {}, (r) => fatals.push(r), deps);
    s.start();
    expect(fatals).toEqual(["AudioDecoder/EncodedAudioChunk unavailable — cannot decode Meet audio"]);
    expect(FakeDecoder.instances).toHaveLength(0);
  });
});
