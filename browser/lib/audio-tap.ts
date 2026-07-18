import { isCurrentEpoch } from "./epoch";
import { liveTracks, setTrackSink, type TrackSink } from "./rtc-hook";
import type { PlatformAdapter } from "./identity/adapter";
import { postToIsolated, type ParticipantId, type Platform } from "./protocol";

// The per-epoch capture sink. Owns the N→N map: one live MediaStreamTrack →
// one isolated pipeline. Identity resolves through the adapter, degrading to a
// stable speaker-<n> rather than ever blocking audio.
//
// Each pipeline: AudioContext(16 kHz) → MediaStreamSource → pcm-16k worklet →
// Int16 frames → a bounded ring buffer → postToIsolated. The worklet is NEVER
// connected to ctx.destination: no playback, no feedback into the user's mic.

// TEMP: live-Meet audio diagnostics to the page console. Flip off before ship.
const EARS_DIAG = true;

const TARGET_SAMPLE_RATE = 16000;
// Bounded per-participant ring buffer. ~10 frames/s; 50 frames ≈ 5 s of slack
// before we drop the oldest frame (back-pressure toward the transport).
const RING_CAPACITY = 50;

interface Pipeline {
  participantId: ParticipantId;
  generation: number;
  stop(): void;
}

interface CaptureConfig {
  epoch: number;
  platform: Platform;
  adapter: PlatformAdapter | null;
}

interface TeardownWindow extends Window {
  __earsTeardown?: () => void;
}

const pipelines = new Map<MediaStreamTrack, Pipeline>();
const generations = new Map<ParticipantId, number>(); // participantId → segment counter
// Fallback speaker ids are keyed to the track so a re-adopted track (epoch
// handoff) keeps its id. WeakMap: entries vanish when the track is GC'd.
const fallbackIds = new WeakMap<MediaStreamTrack, ParticipantId>();
let speakerCounter = 0;
let cfg: CaptureConfig;

/**
 * Take over capture for `config.epoch`. Tears down the previous epoch's
 * pipelines (no doubling), points the hook's sink here, and replays the live
 * track registry (no dropped streams) so a re-inject is seamless.
 */
export function initCapture(config: CaptureConfig): void {
  cfg = config;

  const g = window as unknown as TeardownWindow;
  const prevTeardown = g.__earsTeardown;
  g.__earsTeardown = teardownAll;
  prevTeardown?.(); // stop the superseded epoch before we start emitting

  setTrackSink(sink);

  // Catch-up: adopt tracks that were already live when this epoch loaded.
  for (const [track, rec] of liveTracks()) {
    sink(track, rec.stream, rec.transceiver);
  }

  postToIsolated({ kind: "status", text: `capture epoch ${config.epoch} active (${config.platform})` });
  console.log(`[ears] capture active — epoch ${config.epoch}, platform ${config.platform}`);
}

const sink: TrackSink = (track, stream, transceiver) => {
  if (!isCurrentEpoch(cfg.epoch)) return; // a newer epoch owns capture
  if (pipelines.has(track)) return; // already capturing this track
  startPipeline(track, stream, transceiver);
};

function startPipeline(
  track: MediaStreamTrack,
  stream: MediaStream,
  transceiver: RTCRtpTransceiver,
): void {
  const participantId = resolveIdentity(track, stream, transceiver);
  const generation = (generations.get(participantId) ?? 0) + 1;
  generations.set(participantId, generation);

  const displayName = cfg.adapter?.displayName?.(participantId);

  // Read decoded audio frames straight off the track (MediaStreamTrackProcessor)
  // — no AudioContext, no playing-element requirement. This sidesteps the
  // remote-track→WebAudio silence bug that a hidden <audio> mirror only
  // unreliably worked around.
  const capture = new TrackCapture(track, participantId, () => pipeline.generation);
  const pipeline: Pipeline = {
    participantId,
    generation,
    stop() {
      capture.stop();
    },
  };
  pipelines.set(track, pipeline);
  capture.start();

  postToIsolated({ kind: "participant-joined", platform: cfg.platform, participantId, generation, displayName });
  console.log(
    `[ears] +track → ${participantId} (gen ${generation})` +
      `${displayName ? ` "${displayName}"` : ""} — ${pipelines.size} live`,
  );

  // Lifecycle. Delete from the map *before* stop() so a late frame can't
  // resurrect a dead entry.
  const end = () => stopPipeline(track);
  track.addEventListener("ended", end);
  track.addEventListener("mute", () => console.log(`[ears] mute → ${participantId}`));
  track.addEventListener("unmute", () => console.log(`[ears] unmute → ${participantId}`));
}

function stopPipeline(track: MediaStreamTrack): void {
  const pipeline = pipelines.get(track);
  if (!pipeline) return;
  pipelines.delete(track);
  pipeline.stop();
  postToIsolated({ kind: "participant-left", participantId: pipeline.participantId, generation: pipeline.generation });
  console.log(`[ears] -track → ${pipeline.participantId} (gen ${pipeline.generation}) — ${pipelines.size} live`);
}

function teardownAll(): void {
  for (const track of [...pipelines.keys()]) stopPipeline(track);
}

/** Adapter identity, else a stable speaker-<n> so audio never blocks. */
function resolveIdentity(
  track: MediaStreamTrack,
  stream: MediaStream,
  transceiver: RTCRtpTransceiver,
): ParticipantId {
  const id = cfg.adapter?.identify(track, stream, transceiver) ?? null;
  if (id) return id;
  // Stable per-track fallback: same track → same speaker-<n> across re-adoption.
  const existing = fallbackIds.get(track);
  if (existing) return existing;
  speakerCounter += 1;
  const assigned = `speaker-${speakerCounter}`;
  fallbackIds.set(track, assigned);
  return assigned;
}

// ── Capture: MediaStreamTrackProcessor → 16 kHz mono pcm_s16le ───────────────
//
// Read decoded audio frames straight off the MediaStreamTrack (WebCodecs
// breakout box). Unlike a WebAudio MediaStreamAudioSourceNode, this needs no
// AudioContext and no playing media element, so it doesn't hit the remote-track
// silence bug (verified: on real Meet the WebAudio tap read digital silence
// even with a playing mirror; the breakout box reads the true audio).

const FRAME_SAMPLES = 1600; // 100 ms @ 16 kHz → ~10 frames/s

// WebCodecs AudioData surface we use (avoids ambient-declaration conflicts).
interface AudioDataLike {
  readonly sampleRate: number;
  readonly numberOfFrames: number;
  readonly numberOfChannels: number;
  readonly format: string | null;
  copyTo(dest: Float32Array, options: { planeIndex: number; format?: string }): void;
  close(): void;
}
type TrackProcessorCtor = new (init: { track: MediaStreamTrack }) => {
  readable: ReadableStream<AudioDataLike>;
};

/** One track → its own read loop, resampler, ring buffer, and PCM emitter. */
class TrackCapture {
  private stopped = false;
  private reader?: ReadableStreamDefaultReader<AudioDataLike>;
  private resampler?: LinearResampler;
  private readonly acc: number[] = []; // 16 kHz mono float, awaiting a full frame
  private readonly ring: RingBuffer;
  private unmuteHandler?: () => void;
  private frameCount = 0;
  // diagnostics
  private diagSum = 0;
  private diagCount = 0;
  private diagPeak = 0;

  constructor(
    private readonly track: MediaStreamTrack,
    private readonly participantId: ParticipantId,
    private readonly currentGeneration: () => number,
  ) {
    this.ring = new RingBuffer(RING_CAPACITY, participantId);
  }

  start(): void {
    console.log(
      `[ears/diag] ${this.participantId} start(): muted=${this.track.muted} enabled=${this.track.enabled} readyState=${this.track.readyState}`,
    );
    if (this.track.muted) {
      // A MediaStreamTrackProcessor constructed on a MUTED track never delivers
      // frames — even after the track unmutes — and a track allows only one
      // processor ever. So defer construction until the track's first unmute.
      const onUnmute = () => {
        this.track.removeEventListener("unmute", onUnmute);
        this.unmuteHandler = undefined;
        console.log(`[ears/diag] ${this.participantId} unmute → beginning capture`);
        if (!this.stopped) this.begin();
      };
      this.unmuteHandler = onUnmute;
      this.track.addEventListener("unmute", onUnmute);
      return;
    }
    this.begin();
  }

  private begin(): void {
    const Ctor = (globalThis as unknown as { MediaStreamTrackProcessor?: TrackProcessorCtor })
      .MediaStreamTrackProcessor;
    if (!Ctor) {
      console.error("[ears] MediaStreamTrackProcessor unavailable — cannot capture audio");
      return;
    }
    try {
      this.reader = new Ctor({ track: this.track }).readable.getReader();
    } catch (err) {
      console.error(`[ears] ${this.participantId} failed to construct processor:`, err);
      return;
    }
    console.log(`[ears/diag] ${this.participantId} processor constructed (muted=${this.track.muted}); reading…`);
    if (EARS_DIAG) this.webAudioProbe();
    void this.loop();
  }

  // Compare a parallel WebAudio tap on the same track, to tell whether Meet
  // routes decoded audio through the raw track at all (both taps see it), only
  // one path works, or neither (Meet's NetEQ bypasses the track).
  private webAudioProbe(): void {
    try {
      const ac = new AudioContext();
      const src = ac.createMediaStreamSource(new MediaStream([this.track]));
      const an = ac.createAnalyser();
      src.connect(an);
      const d = new Float32Array(an.fftSize);
      let n = 0;
      const iv = setInterval(() => {
        an.getFloatTimeDomainData(d);
        let peak = 0;
        for (const v of d) if (Math.abs(v) > peak) peak = Math.abs(v);
        console.log(`[ears/diag] ${this.participantId} WEBAUDIO peak=${peak.toFixed(4)} state=${ac.state} (${peak > 0.001 ? "AUDIO" : "silent"})`);
        if (++n > 20 || this.stopped) {
          clearInterval(iv);
          ac.close().catch(() => {});
        }
      }, 1000);
    } catch (err) {
      console.warn(`[ears/diag] ${this.participantId} webaudio probe failed:`, err);
    }
  }

  stop(): void {
    this.stopped = true;
    if (this.unmuteHandler) {
      this.track.removeEventListener("unmute", this.unmuteHandler);
      this.unmuteHandler = undefined;
    }
    this.reader?.cancel().catch(() => {});
  }

  private async loop(): Promise<void> {
    const reader = this.reader!;
    let first = true;
    while (!this.stopped) {
      let value: AudioDataLike | undefined;
      let done = false;
      try {
        ({ done, value } = await reader.read());
      } catch (err) {
        console.error(`[ears] ${this.participantId} reader.read() threw:`, err);
        break;
      }
      if (done) {
        console.warn(`[ears] ${this.participantId} track reader closed (done=true)`);
        break;
      }
      if (!value) continue;
      this.frameCount++;
      if (first) {
        first = false;
        console.log(
          `[ears/diag] ${this.participantId} FIRST frame: fmt=${value.format} rate=${value.sampleRate} ch=${value.numberOfChannels} n=${value.numberOfFrames}`,
        );
      } else if (this.frameCount % 200 === 0) {
        console.log(`[ears/diag] ${this.participantId} ${this.frameCount} frames read`);
      }
      try {
        this.consume(value);
      } catch (err) {
        console.error(`[ears] ${this.participantId} consume() threw:`, err);
      } finally {
        value.close();
      }
    }
  }

  private consume(frame: AudioDataLike): void {
    const inRate = frame.sampleRate;
    const nFrames = frame.numberOfFrames;
    const nCh = frame.numberOfChannels;
    const format = frame.format ?? "f32-planar";

    // Downmix to mono float32.
    const mono = new Float32Array(nFrames);
    if (format.endsWith("-planar")) {
      const plane = new Float32Array(nFrames);
      for (let ch = 0; ch < nCh; ch++) {
        frame.copyTo(plane, { planeIndex: ch, format: "f32-planar" });
        for (let i = 0; i < nFrames; i++) mono[i]! += plane[i]! / nCh;
      }
    } else {
      const inter = new Float32Array(nFrames * nCh);
      frame.copyTo(inter, { planeIndex: 0, format: "f32" });
      for (let i = 0; i < nFrames; i++) {
        let s = 0;
        for (let ch = 0; ch < nCh; ch++) s += inter[i * nCh + ch]!;
        mono[i] = s / nCh;
      }
    }

    if (EARS_DIAG) this.diag(mono, inRate, nCh, format);

    // Resample native → 16 kHz and slice into fixed frames.
    if (!this.resampler) this.resampler = new LinearResampler(inRate, TARGET_SAMPLE_RATE);
    const out = this.resampler.process(mono);
    for (let i = 0; i < out.length; i++) this.acc.push(out[i]!);

    while (this.acc.length >= FRAME_SAMPLES) {
      const chunk = this.acc.splice(0, FRAME_SAMPLES);
      const int16 = new Int16Array(FRAME_SAMPLES);
      for (let i = 0; i < FRAME_SAMPLES; i++) {
        let s = chunk[i]!;
        if (s > 1) s = 1;
        else if (s < -1) s = -1;
        int16[i] = s < 0 ? s * 0x8000 : s * 0x7fff;
      }
      this.ring.push(int16);
    }
    for (const f of this.ring.drain()) {
      postToIsolated({ kind: "pcm", participantId: this.participantId, generation: this.currentGeneration(), samples: f });
    }
  }

  private diag(mono: Float32Array, inRate: number, nCh: number, format: string): void {
    for (let i = 0; i < mono.length; i++) {
      const a = Math.abs(mono[i]!);
      if (a > this.diagPeak) this.diagPeak = a;
      this.diagSum += mono[i]! * mono[i]!;
    }
    this.diagCount += mono.length;
    if (this.diagCount >= inRate) {
      const rms = Math.sqrt(this.diagSum / this.diagCount);
      console.log(
        `[ears/diag] ${this.participantId} track-rms=${rms.toFixed(5)} peak=${this.diagPeak.toFixed(4)} ` +
          `(${this.diagPeak > 0.001 ? "AUDIO" : "silent"}) rate=${inRate} ch=${nCh} fmt=${format}`,
      );
      this.diagSum = 0;
      this.diagCount = 0;
      this.diagPeak = 0;
    }
  }
}

/**
 * Streaming linear resampler (inRate → outRate), phase-continuous across chunks.
 * Linear interpolation is adequate for speech at these rates.
 */
class LinearResampler {
  private readonly step: number; // input samples advanced per output sample
  private cursor = 0; // fractional read position within the pending buffer
  private buf = new Float32Array(0);

  constructor(inRate: number, outRate: number) {
    this.step = inRate / outRate;
  }

  process(input: Float32Array): Float32Array {
    const merged = new Float32Array(this.buf.length + input.length);
    merged.set(this.buf);
    merged.set(input, this.buf.length);

    const out: number[] = [];
    let pos = this.cursor;
    while (Math.floor(pos) + 1 < merged.length) {
      const i = Math.floor(pos);
      const frac = pos - i;
      out.push(merged[i]! * (1 - frac) + merged[i + 1]! * frac);
      pos += this.step;
    }
    const keep = Math.floor(pos);
    this.buf = merged.slice(keep);
    this.cursor = pos - keep;
    return Float32Array.from(out);
  }
}

/**
 * Dev-only: run a LOCAL MediaStream through the real capture path, bypassing the
 * RTC hook (the sandboxed test harness can't establish a WebRTC loopback).
 */
export function __devCaptureStream(stream: MediaStream, participantId: ParticipantId): void {
  const track = stream.getAudioTracks()[0];
  if (!track) return;
  postToIsolated({ kind: "participant-joined", platform: cfg?.platform ?? "meet", participantId, generation: 1 });
  new TrackCapture(track, participantId, () => 1).start();
}

// Bounded ring buffer, drop-oldest, with a logged dropped counter — never grows
// unbounded. Drop-oldest keeps the freshest audio when the consumer stalls.
class RingBuffer {
  private q: Int16Array[] = [];
  private dropped = 0;
  constructor(
    private readonly capacity: number,
    private readonly label: string,
  ) {}

  push(frame: Int16Array): void {
    if (this.q.length >= this.capacity) {
      this.q.shift();
      this.dropped++;
      if (this.dropped % 50 === 1) {
        console.warn(`[ears] ring overflow for ${this.label}: dropped ${this.dropped} frame(s)`);
      }
    }
    this.q.push(frame);
  }

  drain(): Int16Array[] {
    const out = this.q;
    this.q = [];
    return out;
  }
}
