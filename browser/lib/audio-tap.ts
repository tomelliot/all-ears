import { isCurrentEpoch } from "./epoch";
import {
  liveTracks,
  setEncodedAudioListener,
  setTrackSink,
  type EncodedAudioFrameLike,
  type TrackSink,
} from "./rtc-hook";
import type { PlatformAdapter } from "./identity/adapter";
import { postToIsolated, type ParticipantId, type Platform } from "./protocol";

// The per-epoch capture sink. Owns the N→N map: one live MediaStreamTrack →
// one isolated pipeline. Identity resolves through the adapter, degrading to a
// stable speaker-<n> rather than ever blocking audio.
//
// Each pipeline: a platform-dependent frame source → downmix → resample to
// 16 kHz mono → Int16 frames → a bounded ring buffer → postToIsolated. Two
// frame sources feed the same downstream logic (see §Frame sources below):
// MediaStreamTrackProcessor for Zoom/Teams, and an AudioDecoder fed by
// rtc-hook.ts's Meet encoded-audio tee for Meet. Neither is ever connected to
// an AudioContext destination: no playback, no feedback into the user's mic.

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

  // Platform selects the frame source; the standard MediaStreamTrackProcessor
  // path must never run on Meet (no frames ever reach it there) and the Meet
  // tee must never run elsewhere (it would double-capture where the standard
  // path already works).
  const makeSource = cfg.platform === "meet" ? meetDecodeSource(track) : trackProcessorSource(track);
  const capture = new TrackCapture(participantId, () => pipeline.generation, makeSource, () => stopPipeline(track));
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

// ── Shared pipeline: frame source → 16 kHz mono pcm_s16le ───────────────────

const FRAME_SAMPLES = 1600; // 100 ms @ 16 kHz → ~10 frames/s

// Debug instrumentation for live-call verification — off by default, no
// rebuild needed to use. Enable per-tab from the page's DevTools console:
//   localStorage.setItem("__earsDebugAudio", "1")   // then reload the tab
//   localStorage.removeItem("__earsDebugAudio")     // to turn back off
// Adds a throttled peak/RMS log per participant (proves PCM is non-silent,
// not just flowing) and dumps recent frame sizes/timestamps if AudioDecoder
// errors (WebCodecs gives no other way to correlate an error to a frame).
function debugAudioEnabled(): boolean {
  try {
    return localStorage.getItem("__earsDebugAudio") === "1";
  } catch {
    return false;
  }
}
const DEBUG_AUDIO = debugAudioEnabled();

// WebCodecs AudioData surface we use (avoids ambient-declaration conflicts).
interface AudioDataLike {
  readonly sampleRate: number;
  readonly numberOfFrames: number;
  readonly numberOfChannels: number;
  readonly format: string | null;
  copyTo(dest: Float32Array, options: { planeIndex: number; format?: string }): void;
  close(): void;
}

interface FrameSource {
  /** Begin producing frames. Called at most once. */
  start(): void;
  /** Stop producing frames and release resources. Idempotent. */
  stop(): void;
}

type FrameSourceFactory = (
  onFrame: (frame: AudioDataLike) => void,
  onFatalError: (reason: string) => void,
) => FrameSource;

/** One track → its own frame source, resampler, ring buffer, and PCM emitter. */
class TrackCapture {
  private stopped = false;
  private resampler?: LinearResampler;
  private readonly acc: number[] = []; // 16 kHz mono float, awaiting a full frame
  private readonly ring: RingBuffer;
  private source?: FrameSource;
  // Debug-only state — see DEBUG_AUDIO above.
  private vSum = 0;
  private vPeak = 0;
  private vCount = 0;

  constructor(
    private readonly participantId: ParticipantId,
    private readonly currentGeneration: () => number,
    private readonly makeSource: FrameSourceFactory,
    private readonly onFatal: () => void,
  ) {
    this.ring = new RingBuffer(RING_CAPACITY, participantId);
  }

  start(): void {
    this.source = this.makeSource(
      (frame) => this.consume(frame),
      (reason) => this.fail(reason),
    );
    this.source.start();
  }

  stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    this.source?.stop();
  }

  private fail(reason: string): void {
    console.error(`[ears] ${this.participantId} capture failed: ${reason}`);
    this.stop();
    this.onFatal();
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

    if (DEBUG_AUDIO) this.debugLog(mono, inRate);

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

  // Throttled to ~1 log/s/participant — frame counts alone don't prove the
  // samples aren't all-zero, so this checks actual amplitude. DEBUG_AUDIO-gated.
  private debugLog(mono: Float32Array, inRate: number): void {
    for (let i = 0; i < mono.length; i++) {
      const a = Math.abs(mono[i]!);
      if (a > this.vPeak) this.vPeak = a;
      this.vSum += mono[i]! * mono[i]!;
    }
    this.vCount += mono.length;
    if (this.vCount >= inRate) {
      const rms = Math.sqrt(this.vSum / this.vCount);
      console.log(
        `[ears/debug] ${this.participantId} rms=${rms.toFixed(4)} peak=${this.vPeak.toFixed(4)} ` +
          `(${this.vPeak > 0.005 ? "AUDIO" : "silent"})`,
      );
      this.vSum = 0;
      this.vPeak = 0;
      this.vCount = 0;
    }
  }
}

// ── Standard path: MediaStreamTrackProcessor (Zoom, Teams) ─────────────────
//
// Read decoded audio frames straight off the MediaStreamTrack (WebCodecs
// breakout box). Unlike a WebAudio MediaStreamAudioSourceNode, this needs no
// AudioContext and no playing media element, so it doesn't hit the remote-track
// silence bug (verified: on real Meet the WebAudio tap read digital silence
// even with a playing mirror; the breakout box reads the true audio — though
// on Meet even this reads nothing at all, see MeetDecodeSource below).

type TrackProcessorCtor = new (init: { track: MediaStreamTrack }) => {
  readable: ReadableStream<AudioDataLike>;
};

class TrackProcessorSource implements FrameSource {
  private stopped = false;
  private reader?: ReadableStreamDefaultReader<AudioDataLike>;
  private unmuteHandler?: () => void;

  constructor(
    private readonly track: MediaStreamTrack,
    private readonly onFrame: (frame: AudioDataLike) => void,
    private readonly onFatalError: (reason: string) => void,
  ) {}

  start(): void {
    if (this.track.muted) {
      // A MediaStreamTrackProcessor constructed on a MUTED track never delivers
      // frames — even after the track unmutes — and a track allows only one
      // processor ever. So defer construction until the track's first unmute.
      const onUnmute = () => {
        this.track.removeEventListener("unmute", onUnmute);
        this.unmuteHandler = undefined;
        if (!this.stopped) this.begin();
      };
      this.unmuteHandler = onUnmute;
      this.track.addEventListener("unmute", onUnmute);
      return;
    }
    this.begin();
  }

  stop(): void {
    this.stopped = true;
    if (this.unmuteHandler) {
      this.track.removeEventListener("unmute", this.unmuteHandler);
      this.unmuteHandler = undefined;
    }
    this.reader?.cancel().catch(() => {});
  }

  private begin(): void {
    const Ctor = (globalThis as unknown as { MediaStreamTrackProcessor?: TrackProcessorCtor })
      .MediaStreamTrackProcessor;
    if (!Ctor) {
      this.onFatalError("MediaStreamTrackProcessor unavailable");
      return;
    }
    try {
      this.reader = new Ctor({ track: this.track }).readable.getReader();
    } catch (err) {
      this.onFatalError(`failed to construct processor: ${String(err)}`);
      return;
    }
    void this.loop();
  }

  private async loop(): Promise<void> {
    const reader = this.reader!;
    while (!this.stopped) {
      let done = false;
      let value: AudioDataLike | undefined;
      try {
        ({ done, value } = await reader.read());
      } catch (err) {
        if (!this.stopped) this.onFatalError(`reader.read() threw: ${String(err)}`);
        return;
      }
      if (done) {
        if (!this.stopped) this.onFatalError("track reader closed");
        return;
      }
      if (!value) continue;
      try {
        this.onFrame(value);
      } finally {
        value.close();
      }
    }
  }
}

function trackProcessorSource(track: MediaStreamTrack): FrameSourceFactory {
  return (onFrame, onFatalError) => new TrackProcessorSource(track, onFrame, onFatalError);
}

// ── Meet path: AudioDecoder fed by rtc-hook.ts's encoded-audio tee ─────────
//
// Standard path never works on Meet (confirmed empirically — see rtc-hook.ts
// and specs/extension.md §Audio extraction). Readiness here is "rtc-hook.ts
// has a tee'd branch for this track and is willing to dispatch frames to us",
// not track-mute state: once createEncodedStreams() is in play, Meet's own
// decode pipeline owns track.muted and it stops reflecting anything
// meaningful for our purposes.

interface EncodedAudioChunkInit {
  type: "key" | "delta";
  timestamp: number;
  data: ArrayBuffer;
}
type EncodedAudioChunkCtor = new (init: EncodedAudioChunkInit) => unknown;

interface AudioDecoderLike {
  configure(config: { codec: string; sampleRate: number; numberOfChannels: number }): void;
  decode(chunk: unknown): void;
  close(): void;
}
type AudioDecoderCtor = new (init: {
  output: (frame: AudioDataLike) => void;
  error: (err: Error) => void;
}) => AudioDecoderLike;

class MeetDecodeSource implements FrameSource {
  private stopped = false;
  private decoder?: AudioDecoderLike;
  private chunkCtor?: EncodedAudioChunkCtor;
  // Debug-only forensics — see DEBUG_AUDIO above. AudioDecoder's error
  // callback gets a generic DOMException with no reference to which chunk
  // failed, so keep a small rolling window of what we recently fed it to
  // correlate by eye after the fact.
  private recentFrames: { byteLength: number; timestamp: number }[] = [];

  constructor(
    private readonly track: MediaStreamTrack,
    private readonly onFrame: (frame: AudioDataLike) => void,
    private readonly onFatalError: (reason: string) => void,
  ) {}

  start(): void {
    const DecoderCtor = (globalThis as unknown as { AudioDecoder?: AudioDecoderCtor }).AudioDecoder;
    const ChunkCtor = (globalThis as unknown as { EncodedAudioChunk?: EncodedAudioChunkCtor }).EncodedAudioChunk;
    if (!DecoderCtor || !ChunkCtor) {
      // Not expected to trigger (AudioDecoder opus support confirmed on-build),
      // but fall back cleanly: skip this participant, don't crash the hook.
      this.onFatalError("AudioDecoder/EncodedAudioChunk unavailable — cannot decode Meet audio");
      return;
    }
    this.chunkCtor = ChunkCtor;
    try {
      this.decoder = new DecoderCtor({
        output: (frame) => this.onFrame(frame),
        error: (err) => {
          if (DEBUG_AUDIO) {
            console.error(
              `[ears/debug] ${this.track.id} decoder error — last ${this.recentFrames.length} frames fed:`,
              this.recentFrames,
            );
          }
          this.onFatalError(`AudioDecoder error: ${err.message ?? String(err)}`);
        },
      });
      this.decoder.configure({ codec: "opus", sampleRate: 48000, numberOfChannels: 1 });
    } catch (err) {
      this.onFatalError(`failed to construct AudioDecoder: ${String(err)}`);
      return;
    }
    setEncodedAudioListener(this.track, (frame) => this.onEncodedFrame(frame));
  }

  stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    setEncodedAudioListener(this.track, null);
    try {
      this.decoder?.close();
    } catch {
      // already closed
    }
  }

  private onEncodedFrame(frame: EncodedAudioFrameLike): void {
    if (this.stopped || !this.decoder || !this.chunkCtor) return;
    if (DEBUG_AUDIO) {
      this.recentFrames.push({ byteLength: frame.data.byteLength, timestamp: frame.timestamp });
      if (this.recentFrames.length > 8) this.recentFrames.shift();
    }
    try {
      // Opus has no inter-frame prediction — every chunk is a keyframe.
      this.decoder.decode(new this.chunkCtor({ type: "key", timestamp: frame.timestamp, data: frame.data }));
    } catch (err) {
      if (DEBUG_AUDIO) {
        console.error(
          `[ears/debug] ${this.track.id} decode() threw on frame byteLength=${frame.data.byteLength} timestamp=${frame.timestamp} — last ${this.recentFrames.length} frames:`,
          this.recentFrames,
        );
      }
      this.onFatalError(`decode() threw: ${String(err)}`);
    }
  }
}

function meetDecodeSource(track: MediaStreamTrack): FrameSourceFactory {
  return (onFrame, onFatalError) => new MeetDecodeSource(track, onFrame, onFatalError);
}

/**
 * Streaming linear resampler (inRate → outRate), phase-continuous across chunks.
 * Linear interpolation is adequate for speech at these rates. Shared unmodified
 * by every frame source — TrackCapture doesn't know or care where a frame came from.
 */
export class LinearResampler {
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
  new TrackCapture(participantId, () => 1, trackProcessorSource(track), () => {}).start();
}

// Bounded ring buffer, drop-oldest, with a logged dropped counter — never grows
// unbounded. Drop-oldest keeps the freshest audio when the consumer stalls.
export class RingBuffer {
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
