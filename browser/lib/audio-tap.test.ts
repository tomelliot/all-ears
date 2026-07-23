import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  DECODER_HEALTHY_FRAMES,
  DECODER_MAX_RESTARTS,
  DECODER_RESTART_COOLDOWN_MS,
  LinearResampler,
  MeetDecodeSource,
  RingBuffer,
  SILENT_CAPTURE_GRACE_MS,
  SilentCaptureWatchdog,
  silentReport,
  type MeetDecodeDeps,
} from "./audio-tap";
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

// ── Silent-capture watchdog (journal #72) ───────────────────────────────────

describe("SilentCaptureWatchdog", () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  it("fires once when an unmuted track never yields a frame", () => {
    const silent: number[] = [];
    const wd = new SilentCaptureWatchdog((ms) => silent.push(ms));
    wd.armOnUnmute();
    vi.advanceTimersByTime(SILENT_CAPTURE_GRACE_MS);
    expect(silent).toEqual([SILENT_CAPTURE_GRACE_MS]);
  });

  it("stays quiet when a frame arrives within the grace window", () => {
    const silent: number[] = [];
    const wd = new SilentCaptureWatchdog((ms) => silent.push(ms));
    wd.armOnUnmute();
    vi.advanceTimersByTime(SILENT_CAPTURE_GRACE_MS / 2);
    wd.noteFrame();
    vi.advanceTimersByTime(SILENT_CAPTURE_GRACE_MS);
    expect(silent).toEqual([]);
  });

  it("reports at most once across repeated unmutes", () => {
    const silent: number[] = [];
    const wd = new SilentCaptureWatchdog((ms) => silent.push(ms));
    wd.armOnUnmute();
    vi.advanceTimersByTime(SILENT_CAPTURE_GRACE_MS);
    wd.armOnUnmute(); // a later speaking turn must not re-warn
    vi.advanceTimersByTime(SILENT_CAPTURE_GRACE_MS);
    expect(silent).toHaveLength(1);
  });

  it("a frame seen before an unmute keeps the track silent-free forever", () => {
    const silent: number[] = [];
    const wd = new SilentCaptureWatchdog((ms) => silent.push(ms));
    wd.noteFrame();
    wd.armOnUnmute();
    vi.advanceTimersByTime(SILENT_CAPTURE_GRACE_MS * 2);
    expect(silent).toEqual([]);
  });

  it("stop() cancels a pending warning (track ended mid-grace)", () => {
    const silent: number[] = [];
    const wd = new SilentCaptureWatchdog((ms) => silent.push(ms));
    wd.armOnUnmute();
    wd.stop();
    vi.advanceTimersByTime(SILENT_CAPTURE_GRACE_MS * 2);
    expect(silent).toEqual([]);
  });
});

describe("silentReport", () => {
  it("escalates to a loud warning when nothing has decoded on the call", () => {
    const r = silentReport("speaker-1", "meet", false, SILENT_CAPTURE_GRACE_MS);
    expect(r.level).toBe("warn");
    expect(r.text).toContain("SILENT");
    expect(r.text).toContain("createEncodedStreams");
  });

  it("downgrades to a benign note when other participants are being captured (a quiet/noise-gated speaker)", () => {
    const r = silentReport("speaker-3", "meet", true, SILENT_CAPTURE_GRACE_MS);
    expect(r.level).toBe("info");
    expect(r.text).toContain("noise-suppressed");
    expect(r.text).not.toContain("SILENT");
  });

  it("omits the Meet-specific hint on other platforms", () => {
    const r = silentReport("speaker-1", "zoom", false, SILENT_CAPTURE_GRACE_MS);
    expect(r.level).toBe("warn");
    expect(r.text).not.toContain("createEncodedStreams");
  });
});

// ── Meet decoder recovery (restart-in-place, bounded budget) ────────────────

// A fake WebCodecs AudioDecoder whose `error` callback the test drives on
// demand. Every construction (including a post-error rebuild) records itself.
// decode() synchronously fires the output callback, modelling a real decoder
// that emits a decoded frame per chunk — so the source's health counter (frames
// decoded since rebuild) advances the way it does in production.
class FakeDecoder {
  static instances: FakeDecoder[] = [];
  readonly output: (frame: unknown) => void;
  readonly error: (err: Error) => void;
  configured = false;
  closed = false;
  decoded: unknown[] = [];
  constructor(init: { output: (frame: unknown) => void; error: (err: Error) => void }) {
    this.output = init.output;
    this.error = init.error;
    FakeDecoder.instances.push(this);
  }
  configure(): void {
    this.configured = true;
  }
  decode(chunk: unknown): void {
    this.decoded.push(chunk);
    this.output({}); // a real decoder emits a decoded frame here
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

  /** Feed n live encoded frames to the current listener. */
  function feed(n: number): void {
    for (let i = 0; i < n; i++) listener!(aFrame());
  }

  beforeEach(() => {
    FakeDecoder.instances = [];
    clock = 0;
    listener = null;
    subscribeCalls = [];
    fatals = [];
    src = makeSource();
  });

  it("rebuilds immediately when a healthy decoder hits an isolated error — capture continues, not fatal", () => {
    src.start();
    expect(FakeDecoder.instances).toHaveLength(1);
    const first = FakeDecoder.instances[0]!;
    feed(DECODER_HEALTHY_FRAMES); // decoder proves healthy

    first.error(DECODING_ERROR);

    expect(fatals).toEqual([]); // recovered, no participant-left/joined churn
    expect(first.closed).toBe(true); // old decoder torn down
    expect(FakeDecoder.instances).toHaveLength(2); // fresh one built at once
    expect(FakeDecoder.instances[1]!.configured).toBe(true);

    // The same encoded-audio listener keeps feeding the fresh decoder.
    feed(1);
    expect(FakeDecoder.instances[1]!.decoded).toHaveLength(1);
    expect(subscribeCalls).toEqual([expect.any(Function)]); // never re-subscribed
  });

  it("a poisoned burst cannot exhaust the restart budget in under a second", () => {
    src.start();
    FakeDecoder.instances.at(-1)!.error(DECODING_ERROR); // barren → cooldown, no rebuild yet
    expect(FakeDecoder.instances).toHaveLength(1);

    // Meet floods poisoned frames every 20ms; all land inside the first second.
    for (clock = 20; clock < 1000; clock += 20) feed(1);

    expect(fatals).toEqual([]); // did NOT give up in <1s …
    expect(FakeDecoder.instances).toHaveLength(1); // … because the frames were dropped, not re-fed
  });

  it("resumes at the next decodable frame after the cooldown elapses", () => {
    src.start();
    FakeDecoder.instances.at(-1)!.error(DECODING_ERROR); // barren → cooldown
    feed(1); // within cooldown → dropped
    expect(FakeDecoder.instances).toHaveLength(1);

    clock = DECODER_RESTART_COOLDOWN_MS; // cooldown elapsed
    feed(1); // rebuilds and decodes on the fresh decoder
    expect(FakeDecoder.instances).toHaveLength(2);
    expect(FakeDecoder.instances[1]!.decoded).toHaveLength(1);
    expect(fatals).toEqual([]);
  });

  it("treats a decode() throw the same as a decoder error (barren → cooldown → rebuild)", () => {
    class ThrowOnceDecoder extends FakeDecoder {
      override decode(chunk: unknown): void {
        // Throw only on the first instance; rebuilt ones decode fine.
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
    listener!(aFrame()); // decode throws → barren → cooldown, not fatal
    expect(fatals).toEqual([]);
    expect(FakeDecoder.instances).toHaveLength(1);

    clock = DECODER_RESTART_COOLDOWN_MS;
    listener!(aFrame()); // rebuild → decodes fine
    expect(fatals).toEqual([]);
    expect(FakeDecoder.instances).toHaveLength(2);
  });

  it("gives up (fatal exactly once) only after sustained barren restarts across seconds", () => {
    src.start();
    FakeDecoder.instances.at(-1)!.error(DECODING_ERROR); // first barren → cooldown

    // Each cooldown boundary yields exactly one restart that immediately dies barren.
    for (let i = 0; i <= DECODER_MAX_RESTARTS; i++) {
      clock += DECODER_RESTART_COOLDOWN_MS;
      feed(1); // rebuild attempt (or the final give-up)
      FakeDecoder.instances.at(-1)!.error(DECODING_ERROR); // dies barren again
    }

    expect(fatals).toHaveLength(1);
    expect(fatals[0]).toContain("giving up");
    // Budget was time-gated: give-up took at least MAX cooldowns of wall time.
    expect(clock).toBeGreaterThanOrEqual(DECODER_MAX_RESTARTS * DECODER_RESTART_COOLDOWN_MS);
    // 1 initial + exactly MAX restarts, then fatal (no further rebuilds).
    expect(FakeDecoder.instances).toHaveLength(DECODER_MAX_RESTARTS + 1);
    // Fatal path stopped the source: the tee was unsubscribed.
    expect(subscribeCalls.at(-1)).toBeNull();
  });

  it("resets the restart budget after a recovery — distinct incidents don't accumulate", () => {
    src.start();
    // Eight separate incidents (far more than the budget). The first death is
    // barren (spends/clears a restart slot, which a full recovery then wipes);
    // every later death lands on a decoder that recovered to full health, so it
    // rebuilds immediately without spending the budget. None of them add up to a
    // give-up.
    for (let incident = 0; incident < 8; incident++) {
      FakeDecoder.instances.at(-1)!.error(DECODING_ERROR);
      clock += DECODER_RESTART_COOLDOWN_MS;
      feed(1); // rebuild path (immediate for a healthy decoder; post-cooldown for the barren one)
      feed(DECODER_HEALTHY_FRAMES); // decoder proves healthy → budget resets
    }
    expect(fatals).toEqual([]);
  });

  it("resets the restart budget once the sliding window passes", () => {
    src.start();
    // Five barren restarts, each spaced a cooldown apart, all within the window.
    FakeDecoder.instances.at(-1)!.error(DECODING_ERROR);
    for (let i = 0; i < DECODER_MAX_RESTARTS - 1; i++) {
      clock += DECODER_RESTART_COOLDOWN_MS;
      feed(1);
      FakeDecoder.instances.at(-1)!.error(DECODING_ERROR);
    }
    expect(fatals).toEqual([]); // at budget, not over

    clock += 31_000; // advance past the 30s window before the next restart
    feed(1); // window pruned → restarts, not fatal
    expect(fatals).toEqual([]);
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
