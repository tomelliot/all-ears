import { isCurrentEpoch } from "./epoch";
import {
  liveTracks,
  setEncodedAudioListener,
  setTrackSink,
  type EncodedAudioFrameLike,
  type EncodedAudioListener,
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

// Low-frequency safety net: sweep liveTracks() for any track this epoch owns
// but has no pipeline for, and (re)adopt it. Covers a new-attendee track whose
// dispatchTrack landed between epoch handoff replays, and any pipeline that
// died without the track ending (belt-and-braces alongside decoder restart).
const RECONCILE_INTERVAL_MS = 3000;
let reconcileTimer: ReturnType<typeof setInterval> | undefined;

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
  cfg.adapter?.onIdentify?.(handleIdentityUpgrade);

  // Catch-up: adopt tracks that were already live when this epoch loaded.
  for (const [track, rec] of liveTracks()) {
    sink(track, rec.stream, rec.transceiver);
  }

  // Arm the reconciler for this epoch (prevTeardown cleared any prior timer).
  if (reconcileTimer !== undefined) clearInterval(reconcileTimer);
  reconcileTimer = setInterval(reconcile, RECONCILE_INTERVAL_MS);

  postToIsolated({ kind: "status", text: `capture epoch ${config.epoch} active (${config.platform})` });
  console.log(`[ears] capture active — epoch ${config.epoch}, platform ${config.platform}`);
}

/**
 * Consume a late identity upgrade pushed by an adapter (Meet's collections-
 * datachannel correlation — see lib/identity/meet.ts) for a track that
 * already started capturing under a different id (typically speaker-<n>).
 *
 * Chosen approach: stop the running pipeline and start a new one under the
 * upgraded id, rather than renaming the id on the live segment in place.
 * Reasons: (1) protocol.ts has no "rename" message — participantId is
 * embedded in every already-sent "pcm"/"participant-joined" message and in
 * the earsd source label (sourceLabel()), so relabeling an in-progress
 * recording would need a new wire message type and daemon-side handling,
 * out of scope here; (2) restart reuses the exact lifecycle audio-tap.ts
 * already has — stopPipeline's participant-left / startPipeline's
 * participant-joined, each with its own fresh `generations` counter — so
 * earsd sees the same "old segment ended, new one began" shape it already
 * handles for every reconnect; (3) it's exactly analogous to how a re-
 * adopted track across an epoch handoff already keeps continuity via
 * `fallbackIds`, just triggered by an identity event instead of an epoch.
 * Trade-off: a few frames of audio are lost across the restart (fresh
 * AudioDecoder/processor) — acceptable given upgrades are rare (≤ once per
 * track, after CONFIRM_THRESHOLD confirming turns) and the alternative is a
 * cross-process protocol change.
 */
function handleIdentityUpgrade(track: MediaStreamTrack, id: ParticipantId): void {
  if (!isCurrentEpoch(cfg.epoch)) return;
  const pipeline = pipelines.get(track);
  if (!pipeline || pipeline.participantId === id) return;
  const rec = liveTracks().get(track);
  if (!rec) return; // track already ended; nothing to restart
  console.log(`[ears] identity upgrade: track ${track.id} ${pipeline.participantId} → ${id} — restarting as a new segment`);
  stopPipeline(track);
  startPipeline(track, rec.stream, rec.transceiver, id);
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
  forcedId?: ParticipantId,
): void {
  const participantId = forcedId ?? resolveIdentity(track, stream, transceiver);
  const generation = (generations.get(participantId) ?? 0) + 1;
  generations.set(participantId, generation);

  const displayName = cfg.adapter?.displayName?.(participantId);

  // Platform selects the frame source; the standard MediaStreamTrackProcessor
  // path must never run on Meet (no frames ever reach it there) and the Meet
  // tee must never run elsewhere (it would double-capture where the standard
  // path already works).
  const makeSource = cfg.platform === "meet" ? meetDecodeSource(track) : trackProcessorSource(track);
  const capture = new TrackCapture(participantId, () => pipeline.generation, makeSource, () => stopPipeline(track), track);
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
  if (reconcileTimer !== undefined) {
    clearInterval(reconcileTimer);
    reconcileTimer = undefined;
  }
  for (const track of [...pipelines.keys()]) stopPipeline(track);
}

/** Adopt any epoch-owned live track that lost (or never got) a pipeline. */
function reconcile(): void {
  if (!isCurrentEpoch(cfg.epoch)) return;
  for (const [track, rec] of liveTracks()) {
    if (!pipelines.has(track)) sink(track, rec.stream, rec.transceiver);
  }
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
// Read fresh each call (not cached at module load) — a stale cached value was
// a plausible reason debug logging silently stayed off across an epoch handoff
// or re-injection even with the localStorage flag set to "1".
function DEBUG_AUDIO_NOW(): boolean {
  return debugAudioEnabled();
}

// Phase 4 investigation instrumentation (meet-speaking-indicator-correlation
// prompt): edge-triggered speaking-start/stop events per track, in the same
// shape/timestamp-precision as the DOM MutationObserver log used to watch
// Meet's tile speaking indicator, so the two can be diffed directly. Gated by
// the same __earsDebugAudio flag — no behavior change when off.
const SPEAK_THRESHOLD = 0.005; // matches the existing periodic AUDIO/silent cutoff below

interface AudioLogEntry {
  t: number;
  iso: string;
  participantId: ParticipantId;
  trackId: string;
  state: "start" | "stop";
  framePeak: number;
}
interface AudioLogWindow extends Window {
  __earsAudioLog?: AudioLogEntry[];
}
function audioLog(): AudioLogEntry[] {
  const g = window as unknown as AudioLogWindow;
  if (!g.__earsAudioLog) g.__earsAudioLog = [];
  return g.__earsAudioLog;
}

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
  private speaking = false; // edge-detection state, see SPEAK_THRESHOLD above — always tracked, not debug-only
  private readonly trackId: string;

  constructor(
    private readonly participantId: ParticipantId,
    private readonly currentGeneration: () => number,
    private readonly makeSource: FrameSourceFactory,
    private readonly onFatal: () => void,
    private readonly track: MediaStreamTrack,
  ) {
    this.ring = new RingBuffer(RING_CAPACITY, participantId);
    this.trackId = track.id;
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

    // Always tracked (not debug-gated): MeetAdapter's collections-datachannel
    // correlation needs a real speaking-edge signal, not just a debug log —
    // see lib/identity/meet.ts and PlatformAdapter.onTrackSpeaking.
    this.updateSpeaking(mono);
    if (DEBUG_AUDIO_NOW()) this.debugLog(mono, inRate);

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

  // Edge-triggered start/stop, ~frame-resolution (10-100ms depending on
  // source) — comparable granularity to the DOM speaking-indicator's
  // mutation-observer log (journal #47/#48), so the two can be correlated by
  // timestamp. Always runs (see the call site in consume()): the collections-
  // datachannel correlation (lib/identity/meet-correlator.ts) needs this
  // signal live, not just when __earsDebugAudio is set. Debug logging below
  // stays gated; only the edge detection and the adapter callback are unconditional.
  private updateSpeaking(mono: Float32Array): void {
    let framePeak = 0;
    for (let i = 0; i < mono.length; i++) {
      const a = Math.abs(mono[i]!);
      if (a > framePeak) framePeak = a;
    }
    const isSpeaking = framePeak > SPEAK_THRESHOLD;
    if (isSpeaking === this.speaking) return;
    this.speaking = isSpeaking;
    cfg.adapter?.onTrackSpeaking?.(this.track, isSpeaking);

    if (DEBUG_AUDIO_NOW()) {
      const t = Date.now();
      const entry: AudioLogEntry = {
        t,
        iso: new Date(t).toISOString(),
        participantId: this.participantId,
        trackId: this.trackId,
        state: isSpeaking ? "start" : "stop",
        framePeak: Number(framePeak.toFixed(4)),
      };
      audioLog().push(entry);
      console.log(
        `[ears/audio] ${entry.iso} ${this.participantId} (track ${this.trackId}) speaking-${entry.state} peak=${entry.framePeak}`,
      );
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

// A single transient bad frame puts the whole AudioDecoder into a permanent
// error state (WebCodecs gives no per-frame recovery, and the error callback
// carries no chunk reference). Killing the participant's capture over one such
// frame is wrong: live evidence shows the *same* track decodes cleanly on a
// fresh decoder immediately afterwards (a decoder that died mid-call went on
// to decode ~9.8k subsequent frames with zero errors once reconstructed). So
// MeetDecodeSource restarts its decoder in place — the encoded-audio tee keeps
// feeding this track for its whole life, so a rebuilt decoder resumes within
// ~1 frame, with no participant-left/joined churn and no daemon-source close.
// A decoder that keeps dying is genuinely broken: past DECODER_MAX_RESTARTS
// within a sliding DECODER_RESTART_WINDOW_MS, we stop restarting and fall
// through to the pre-existing fatal path (stops the pipeline once).
const DECODER_RESTART_WINDOW_MS = 30_000;
const DECODER_MAX_RESTARTS = 5;

/** Injection seam for MeetDecodeSource — production reads globals + rtc-hook;
 * tests supply fakes and a controllable clock. All optional. */
export interface MeetDecodeDeps {
  decoderCtor?: AudioDecoderCtor;
  chunkCtor?: EncodedAudioChunkCtor;
  /** Subscribe to (listener) / unsubscribe from (null) this track's encoded-audio tee. */
  subscribe?: (track: MediaStreamTrack, listener: EncodedAudioListener | null) => void;
  /** ms clock for the restart sliding window. */
  now?: () => number;
}

export class MeetDecodeSource implements FrameSource {
  private stopped = false;
  private decoder?: AudioDecoderLike;
  private decoderCtor?: AudioDecoderCtor;
  private chunkCtor?: EncodedAudioChunkCtor;
  private readonly subscribe: (track: MediaStreamTrack, listener: EncodedAudioListener | null) => void;
  private readonly now: () => number;
  /** ms timestamps of recent in-place restarts (sliding-window budget). */
  private restarts: number[] = [];
  // Debug-only forensics — see DEBUG_AUDIO above. AudioDecoder's error
  // callback gets a generic DOMException with no reference to which chunk
  // failed, so keep a small rolling window of what we recently fed it to
  // correlate by eye after the fact.
  private recentFrames: { byteLength: number; timestamp: number }[] = [];

  constructor(
    private readonly track: MediaStreamTrack,
    private readonly onFrame: (frame: AudioDataLike) => void,
    private readonly onFatalError: (reason: string) => void,
    private readonly deps: MeetDecodeDeps = {},
  ) {
    this.subscribe = deps.subscribe ?? setEncodedAudioListener;
    this.now = deps.now ?? (() => Date.now());
  }

  start(): void {
    const DecoderCtor = this.deps.decoderCtor ?? (globalThis as unknown as { AudioDecoder?: AudioDecoderCtor }).AudioDecoder;
    const ChunkCtor = this.deps.chunkCtor ?? (globalThis as unknown as { EncodedAudioChunk?: EncodedAudioChunkCtor }).EncodedAudioChunk;
    if (!DecoderCtor || !ChunkCtor) {
      // Not expected to trigger (AudioDecoder opus support confirmed on-build),
      // but fall back cleanly: skip this participant, don't crash the hook.
      this.onFatalError("AudioDecoder/EncodedAudioChunk unavailable — cannot decode Meet audio");
      return;
    }
    this.decoderCtor = DecoderCtor;
    this.chunkCtor = ChunkCtor;
    if (!this.buildDecoder()) return; // construction failed — fatal already reported
    this.subscribe(this.track, (frame) => this.onEncodedFrame(frame));
  }

  stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    this.subscribe(this.track, null);
    this.closeDecoder();
  }

  /** Construct + configure a fresh decoder. Returns false (after reporting a
   * fatal error) if construction itself fails — that's not recoverable. */
  private buildDecoder(): boolean {
    try {
      this.decoder = new this.decoderCtor!({
        output: (frame) => this.onFrame(frame),
        error: (err) => this.onDecoderError(`AudioDecoder error: ${err.message ?? String(err)}`),
      });
      this.decoder.configure({ codec: "opus", sampleRate: 48000, numberOfChannels: 1 });
      return true;
    } catch (err) {
      this.onFatalError(`failed to construct AudioDecoder: ${String(err)}`);
      return false;
    }
  }

  private closeDecoder(): void {
    try {
      this.decoder?.close();
    } catch {
      // already closed (an errored decoder self-closes)
    }
    this.decoder = undefined;
  }

  /** Decoder-level failure (error callback or decode() throw). Restart in place
   * within budget; otherwise fall through to the fatal path exactly once. */
  private onDecoderError(reason: string): void {
    if (this.stopped) return;
    if (DEBUG_AUDIO_NOW()) {
      console.error(
        `[ears/debug] ${this.track.id} decoder error — last ${this.recentFrames.length} frames fed:`,
        this.recentFrames,
      );
    }
    const now = this.now();
    this.restarts = this.restarts.filter((t) => now - t <= DECODER_RESTART_WINDOW_MS);
    if (this.restarts.length >= DECODER_MAX_RESTARTS) {
      this.onFatalError(
        `${reason} — ${this.restarts.length} decoder restarts within ${DECODER_RESTART_WINDOW_MS / 1000}s, giving up`,
      );
      return;
    }
    this.restarts.push(now);
    this.closeDecoder();
    console.warn(`[ears] ${this.track.id} decoder restart ${this.restarts.length}/${DECODER_MAX_RESTARTS} after: ${reason}`);
    // Same encoded-audio listener stays attached; onEncodedFrame reads the fresh decoder.
    this.buildDecoder();
  }

  private onEncodedFrame(frame: EncodedAudioFrameLike): void {
    if (this.stopped || !this.decoder || !this.chunkCtor) return;
    if (DEBUG_AUDIO_NOW()) {
      this.recentFrames.push({ byteLength: frame.data.byteLength, timestamp: frame.timestamp });
      if (this.recentFrames.length > 8) this.recentFrames.shift();
    }
    try {
      // Opus has no inter-frame prediction — every chunk is a keyframe.
      this.decoder.decode(new this.chunkCtor({ type: "key", timestamp: frame.timestamp, data: frame.data }));
    } catch (err) {
      this.onDecoderError(`decode() threw: ${String(err)}`);
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
  new TrackCapture(participantId, () => 1, trackProcessorSource(track), () => {}, track).start();
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
