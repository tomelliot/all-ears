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
  /** Whether this pipeline has decoded at least one audio frame (debug report). */
  receiving(): boolean;
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
// track.id → the participant id its pipeline last captured under. Unlike
// `fallbackIds` this is keyed by the *string* id and survives the track object,
// so a late identity for an already-dead track (adapter onRename) can still be
// translated back to the id whose audio is on disk. Bounded by the number of
// tracks seen in the page's life; never cleared mid-call on purpose.
const participantIdsByTrackId = new Map<string, ParticipantId>();
let speakerCounter = 0;
let cfg: CaptureConfig;

// True once ANY participant on this call has produced a decoded frame. Gates the
// per-track silent warning: Meet legitimately delivers no audio for an unmuted
// but silent participant (DTX / noise suppression), so "unmuted + no frames" is
// not on its own proof of breakage. Only escalate to a loud "SILENT" warning
// when nothing has decoded anywhere on the call (see silentReport). Not reset on
// epoch handoff — a mid-call re-inject must not forget that audio once flowed.
let anyAudioDecodedThisCall = false;

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
  cfg.adapter?.onRename?.(handleLateIdentity);
  // Forward roster names (id → display name) the adapter resolves to the daemon,
  // decoupled from track capture, so a participant's name reaches meeting.toml
  // even when the speaking-onset correlation never tied them to a track (#23).
  cfg.adapter?.onRoster?.((entries) => {
    if (!isCurrentEpoch(cfg.epoch) || entries.length === 0) return;
    postToIsolated({ kind: "participant-roster", platform: cfg.platform, entries });
  });

  // Catch-up: adopt tracks that were already live when this epoch loaded.
  for (const [track, rec] of liveTracks()) {
    sink(track, rec.stream, rec.transceiver);
  }

  // Arm the reconciler for this epoch (prevTeardown cleared any prior timer).
  if (reconcileTimer !== undefined) clearInterval(reconcileTimer);
  reconcileTimer = setInterval(reconcile, RECONCILE_INTERVAL_MS);

  postToIsolated({ kind: "status", text: `capture epoch ${config.epoch} active (${config.platform})` });
  console.debug(`[ears][capture] capture active — epoch ${config.epoch}, platform ${config.platform}`);
}

/** Capture-side state for the popup's debug report (see hook.content.ts). */
export function captureDebugState(): {
  platform: Platform | undefined;
  epoch: number | undefined;
  pipelineCount: number;
  anyAudioDecodedThisCall: boolean;
  participants: Array<{ id: ParticipantId; generation: number; receiving: boolean }>;
} {
  return {
    platform: cfg?.platform,
    epoch: cfg?.epoch,
    pipelineCount: pipelines.size,
    anyAudioDecodedThisCall,
    participants: [...pipelines.values()].map((p) => ({
      id: p.participantId,
      generation: p.generation,
      receiving: p.receiving(),
    })),
  };
}

/**
 * Consume a late identity upgrade pushed by an adapter (Meet's collections-
 * datachannel correlation — see lib/identity/meet.ts) for a track that
 * already started capturing under a different id (typically speaker-<n>).
 *
 * Chosen approach: stop the running pipeline and start a new one under the
 * upgraded id, rather than renaming the id on the live segment in place.
 * Reasons: (1) restart reuses the exact lifecycle audio-tap.ts already has —
 * stopPipeline's participant-left / startPipeline's participant-joined, each
 * with its own fresh `generations` counter — so earsd sees the same "old
 * segment ended, new one began" shape it already handles for every
 * reconnect; (2) it's exactly analogous to how a re-adopted track across an
 * epoch handoff already keeps continuity via `fallbackIds`, just triggered
 * by an identity event instead of an epoch. Trade-off: a few frames of audio
 * are lost across the restart (fresh AudioDecoder/processor) — acceptable
 * given upgrades are rare (≤ once per track, after CONFIRM_THRESHOLD
 * confirming turns).
 *
 * When the restart is impossible — the track already ended before the
 * confirmation landed — the fallback is `handleLateIdentity`'s
 * "participant-renamed" message, which joins the already-recorded audio's
 * source to the named attendee daemon-side instead of relabeling anything.
 */
function handleIdentityUpgrade(track: MediaStreamTrack, id: ParticipantId): void {
  if (!isCurrentEpoch(cfg.epoch)) return;
  const pipeline = pipelines.get(track);
  if (!pipeline || pipeline.participantId === id) return;
  const rec = liveTracks().get(track);
  if (!rec) {
    // Track already ended between the correlator's match and this callback;
    // nothing to restart — same late-join shape as the adapter's onRename.
    handleLateIdentity(track.id, id);
    return;
  }
  console.debug(`[ears][capture] identity upgrade: track ${track.id} ${pipeline.participantId} → ${id} — restarting as a new segment`);
  stopPipeline(track);
  startPipeline(track, rec.stream, rec.transceiver, id);
}

/**
 * A confirmed identity arrived for a track whose pipeline can no longer be
 * restarted (the track died first — e.g. to the Meet AudioDecoder bug,
 * journal #45). The audio already recorded stays under the fallback id's
 * source; tell the daemon the two ids are the same person so the transcript
 * still labels that source by the attendee's name.
 */
function handleLateIdentity(trackId: string, id: ParticipantId): void {
  if (!isCurrentEpoch(cfg.epoch)) return;
  const fromId = participantIdsByTrackId.get(trackId);
  if (!fromId || fromId === id) return;
  console.debug(`[ears][capture] late identity: track ${trackId} ${fromId} → ${id} — sending rename (track already ended)`);
  postToIsolated({ kind: "participant-renamed", platform: cfg.platform, fromId, toId: id });
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
  participantIdsByTrackId.set(track.id, participantId);
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
    receiving: () => capture.receiving,
  };
  pipelines.set(track, pipeline);
  capture.start();

  postToIsolated({ kind: "participant-joined", platform: cfg.platform, participantId, generation, displayName });
  console.debug(
    `[ears][capture] +track → ${participantId} (gen ${generation})` +
      `${displayName ? ` "${displayName}"` : ""} — ${pipelines.size} live`,
  );

  // Lifecycle. Delete from the map *before* stop() so a late frame can't
  // resurrect a dead entry.
  const end = () => stopPipeline(track);
  track.addEventListener("ended", end);
  track.addEventListener("mute", () => console.debug(`[ears][capture] mute → ${participantId}`));
  track.addEventListener("unmute", () => {
    console.debug(`[ears][capture] unmute → ${participantId}`);
    // Meet identity: an unmute pairs with the collections channel's per-device
    // mic-open edge (the only per-device event that channel still carries).
    try {
      cfg.adapter?.onTrackUnmute?.(track);
    } catch {
      // best-effort — identity must never affect capture
    }
  });
}

function stopPipeline(track: MediaStreamTrack): void {
  const pipeline = pipelines.get(track);
  if (!pipeline) return;
  pipelines.delete(track);
  pipeline.stop();
  postToIsolated({ kind: "participant-left", participantId: pipeline.participantId, generation: pipeline.generation });
  console.debug(`[ears][capture] -track → ${pipeline.participantId} (gen ${pipeline.generation}) — ${pipelines.size} live`);
}

function teardownAll(): void {
  if (reconcileTimer !== undefined) {
    clearInterval(reconcileTimer);
    reconcileTimer = undefined;
  }
  for (const track of [...pipelines.keys()]) stopPipeline(track);
}

/** Adopt any epoch-owned live track that lost (or never got) a pipeline, and
 * re-harvest the participant roster so names for silent (never-speaking)
 * participants still reach the daemon (#23). */
function reconcile(): void {
  if (!isCurrentEpoch(cfg.epoch)) return;
  for (const [track, rec] of liveTracks()) {
    if (!pipelines.has(track)) sink(track, rec.stream, rec.transceiver);
  }
  cfg.adapter?.pollIdentities?.();
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
// A track that unmutes but never yields a decoded frame is the silent-capture
// failure (journal #72): on Meet the encoded-audio tee may never wrap the
// receiver, so the decoder is fed nothing and the whole call records silence
// while +track/unmute/identity all still look healthy. The grace window covers
// the ~1-frame latency between an unmute and the first decoded frame with wide
// margin, so a brief blip never false-positives.
export const SILENT_CAPTURE_GRACE_MS = 4_000;

/**
 * Decide how to surface a track that unmuted but produced no decoded frame.
 * Meet delivers no audio for an unmuted-but-silent participant (DTX / noise
 * suppression), so "no frames" alone is NOT proof of breakage. Escalate to a
 * loud warning only when nothing has decoded anywhere on the call
 * (`anyAudioThisCall === false`) — the same condition the call-level tee
 * watchdog flags. If other participants are being captured, this one is simply
 * quiet: a benign info note, never a scary ⚠ (journal #67: quiet ≠ broken).
 */
export function silentReport(
  participantId: ParticipantId,
  platform: Platform | undefined,
  anyAudioThisCall: boolean,
  graceMs: number,
): { level: "warn" | "info"; text: string } {
  const secs = Math.round(graceMs / 1000);
  if (anyAudioThisCall) {
    return {
      level: "info",
      text:
        `${participantId} unmuted but no audio decoded in ${secs}s` +
        " — likely silent or noise-suppressed (other participants are being captured)",
    };
  }
  const hint =
    platform === "meet"
      ? " — Meet exposes no decodable track audio, so no encoded frames reached the decoder" +
        " (createEncodedStreams not intercepted, or Meet changed its audio pipeline)." +
        " Reload the tab to re-arm."
      : "";
  return {
    level: "warn",
    text: `⚠ ${participantId} unmuted but no audio decoded in ${secs}s — capture is SILENT for this participant${hint}`,
  };
}

/**
 * Per-track detector for the silent-capture failure. `armOnUnmute()` starts a
 * one-shot timer; unless `noteFrame()` lands before it fires, `onSilent` runs
 * once (latched for the track's life). Kept free of TrackCapture's
 * window/postMessage wiring so it unit-tests under fake timers.
 */
export class SilentCaptureWatchdog {
  private firstFrameSeen = false;
  private reported = false;
  private timer?: ReturnType<typeof setTimeout>;

  constructor(
    private readonly onSilent: (graceMs: number) => void,
    private readonly graceMs: number = SILENT_CAPTURE_GRACE_MS,
  ) {}

  /** The track unmuted — a decoded frame must follow. Arm once; ignore repeat
   * unmutes and any unmute after a frame already proved capture live. */
  armOnUnmute(): void {
    if (this.firstFrameSeen || this.reported || this.timer !== undefined) return;
    this.timer = setTimeout(() => {
      this.timer = undefined;
      if (this.firstFrameSeen || this.reported) return;
      this.reported = true;
      this.onSilent(this.graceMs);
    }, this.graceMs);
  }

  /** A decoded frame arrived — capture is live; cancel the watchdog for good. */
  noteFrame(): void {
    if (this.firstFrameSeen) return;
    this.firstFrameSeen = true;
    this.clearTimer();
  }

  stop(): void {
    this.clearTimer();
  }

  private clearTimer(): void {
    if (this.timer !== undefined) {
      clearTimeout(this.timer);
      this.timer = undefined;
    }
  }
}

class TrackCapture {
  private stopped = false;
  private resampler?: LinearResampler;
  private readonly acc: number[] = []; // 16 kHz mono float, awaiting a full frame
  private readonly ring: RingBuffer;
  private source?: FrameSource;
  private firstFrameSeen = false;
  private readonly silentWatchdog: SilentCaptureWatchdog;
  private unmuteHandler?: () => void;
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
    this.silentWatchdog = new SilentCaptureWatchdog((graceMs) => this.reportSilent(graceMs));
  }

  /** Whether at least one audio frame has decoded on this track (debug report). */
  get receiving(): boolean {
    return this.firstFrameSeen;
  }

  start(): void {
    this.source = this.makeSource(
      (frame) => this.consume(frame),
      (reason) => this.fail(reason),
    );
    this.source.start();
    // An unmute means the platform says this participant is producing audio now,
    // so a decoded frame must follow; if none does, capture is silently dropping
    // them (journal #72). Arm on unmute, not on start — a genuinely quiet
    // participant yields no frames and that is not a failure.
    this.unmuteHandler = () => this.silentWatchdog.armOnUnmute();
    this.track.addEventListener("unmute", this.unmuteHandler);
  }

  stop(): void {
    if (this.stopped) return;
    this.stopped = true;
    if (this.unmuteHandler) {
      this.track.removeEventListener("unmute", this.unmuteHandler);
      this.unmuteHandler = undefined;
    }
    this.silentWatchdog.stop();
    this.source?.stop();
  }

  private fail(reason: string): void {
    console.error(`[ears][capture] ${this.participantId} capture failed: ${reason}`);
    // Tell the isolated relay (and through it the background/daemon) that this
    // participant's capture died mid-call, so the audio gap is attributable
    // rather than looking like the source just went quiet (issue #22).
    postToIsolated({ kind: "capture-failed", participantId: this.participantId, generation: this.currentGeneration(), reason });
    this.stop();
    this.onFatal();
  }

  /** The silent-capture watchdog fired: this participant unmuted but no decoded
   * frame ever arrived. Loud console error plus a `status` line the isolated-
   * world relay logs (and can surface in the popup/daemon). See journal #72. */
  private reportSilent(graceMs: number): void {
    const report = silentReport(this.participantId, cfg?.platform, anyAudioDecodedThisCall, graceMs);
    if (report.level === "warn") {
      console.error(`[ears][capture] ${report.text}`);
      postToIsolated({ kind: "status", text: report.text });
    } else {
      // Benign: the pipeline works, this participant is just quiet. Keep it low
      // so it never reads as a failure to a user scanning the console.
      console.debug(`[ears][capture] ${report.text}`);
    }
  }

  private consume(frame: AudioDataLike): void {
    if (!this.firstFrameSeen) {
      this.firstFrameSeen = true;
      anyAudioDecodedThisCall = true;
      this.silentWatchdog.noteFrame();
      console.debug(`[ears][capture] ✓ ${this.participantId} first audio frame — capture confirmed live`);
    }
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
      console.debug(
        `[ears][debug][audio] ${entry.iso} ${this.participantId} (track ${this.trackId}) speaking-${entry.state} peak=${entry.framePeak}`,
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
      console.debug(
        `[ears][debug][audio] ${this.participantId} rms=${rms.toFixed(4)} peak=${this.vPeak.toFixed(4)} ` +
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
// feeding this track for its whole life, so a rebuilt decoder resumes with no
// participant-left/joined churn and no daemon-source close.
//
// The spiral issue #22 fixes: Meet changes the Opus stream mid-call (bitrate /
// DTX as speakers pause) and a short burst of frames won't decode from a cold
// decoder. The old budget counted every rebuild equally, so a poisoned burst
// re-fed into a fresh decoder frame-by-frame exhausted all 5 restarts in under
// a second and dropped the track. Two changes break that, distinguishing "same
// frame fails repeatedly" (skip it) from "decoder broken" (rebuild):
//
//   1. A rebuilt decoder that dies before decoding anything (a *barren*
//      restart) does NOT re-feed the frames that just failed. It cools down for
//      DECODER_RESTART_COOLDOWN_MS — dropping the poisoned window — then
//      rebuilds on the next live frame: "resume at the next decodable
//      boundary", not "replay the recent frame window". That paces barren
//      restarts at most one per cooldown, so one bad burst can't burn the whole
//      budget in <1s.
//   2. A decoder that WAS decoding cleanly (>= DECODER_HEALTHY_FRAMES) before an
//      error is a distinct incident, not a spiral: it rebuilds immediately
//      (near-zero audio loss) and its recovery resets the restart budget. Only
//      barren restarts count toward giving up.
//
// Past DECODER_MAX_RESTARTS barren restarts within a sliding
// DECODER_RESTART_WINDOW_MS we stop and fall through to the fatal path (stops
// the pipeline once; TrackCapture then emits a capture-failed event so the
// daemon can attribute the gap instead of just seeing the source go quiet).
const DECODER_RESTART_WINDOW_MS = 30_000;
export const DECODER_MAX_RESTARTS = 5;
// A rebuilt decoder that decodes this many frames (~200ms of Opus at 20ms /
// frame) has proven it can decode from a cold start — the poisoned boundary is
// behind it. Reaching it resets the restart budget; an error after it rebuilds
// immediately instead of counting toward give-up.
export const DECODER_HEALTHY_FRAMES = 10;
// After a barren restart, drop incoming frames for this long before spending the
// next restart. Long enough for a mid-stream Opus parameter change to finish so
// the rebuilt decoder lands on a decodable boundary; short enough that recovery
// costs ~1s of audio, not the whole speaking turn.
export const DECODER_RESTART_COOLDOWN_MS = 1_000;

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

/** One recently-fed encoded frame, kept for post-hoc error forensics. */
interface FrameForensic {
  byteLength: number;
  timestamp: number;
  /** Opus TOC byte (config / stereo / frame-count code). A mid-stream bitrate
   * or DTX change — the suspected poison — shows up here as a changed config. */
  toc: number;
}

/**
 * Unwrap an RFC 2198 RED payload to its primary (current) block, or return
 * null when `data` doesn't parse as RED.
 *
 * Meet wraps its Opus stream in RED adaptively (redundancy kicks in under
 * packet loss), and those packets reach the encoded-audio tee as-is: the
 * 2026-07-24 live captures show every "AudioDecoder error: Decoding error"
 * frame starting 0xEF — not an Opus TOC but the RED block header
 * `F=1 | PT=111` (111 is Meet's Opus payload type). Feeding RED to a plain
 * Opus decoder fails per-packet, which is journal #45's entire error class.
 *
 * Wire shape (RFC 2198): N redundant-block headers (4 bytes each, F bit set:
 * F|PT, 14-bit timestamp offset, 10-bit block length), one primary header
 * (1 byte, F bit clear), then the blocks in header order — redundant blocks
 * first at their declared lengths, primary block last taking the remainder.
 * The primary block is the current frame; redundant blocks re-carry earlier
 * frames the decoder has usually already seen, so only the primary is fed.
 *
 * Defensive by contract: a genuine Opus TOC can also carry the high bit, so
 * a payload is only treated as RED when the full header chain parses — every
 * header PT identical and the declared redundant lengths fitting exactly
 * inside the payload. Anything else returns null and is fed to the decoder
 * unchanged.
 */
export function unwrapRedPayload(data: ArrayBuffer): ArrayBuffer | null {
  const bytes = new Uint8Array(data);
  let offset = 0;
  let redundantBytes = 0;
  let redundantHeaders = 0;
  let primaryPT = -1;
  while (offset < bytes.length) {
    const first = bytes[offset]!;
    const pt = first & 0x7f;
    if (primaryPT === -1) primaryPT = pt;
    else if (pt !== primaryPT) return null; // mixed PTs — not a RED chain
    if ((first & 0x80) === 0) {
      // Primary header (1 byte) — blocks follow.
      if (redundantHeaders === 0) return null; // no redundancy → plain payload
      const blocksStart = offset + 1;
      const primaryStart = blocksStart + redundantBytes;
      if (primaryStart >= bytes.length) return null; // lengths don't fit
      return bytes.slice(primaryStart).buffer;
    }
    if (offset + 4 > bytes.length) return null; // truncated header
    redundantBytes += ((bytes[offset + 2]! & 0x03) << 8) | bytes[offset + 3]!;
    redundantHeaders += 1;
    offset += 4;
  }
  return null; // ran out of bytes before a primary header
}

export class MeetDecodeSource implements FrameSource {
  private stopped = false;
  private decoder?: AudioDecoderLike;
  private decoderCtor?: AudioDecoderCtor;
  private chunkCtor?: EncodedAudioChunkCtor;
  private readonly subscribe: (track: MediaStreamTrack, listener: EncodedAudioListener | null) => void;
  private readonly now: () => number;
  /** ms timestamps of barren restarts still inside the sliding window. */
  private restarts: number[] = [];
  /** Successful decodes since the current decoder was built. 0 = barren so far;
   * >= DECODER_HEALTHY_FRAMES = the decoder has recovered. */
  private framesSinceBuild = 0;
  /** Set when the decoder has died and is cooling down before its next rebuild;
   * frames arriving before now() reaches it + COOLDOWN are dropped (skipping the
   * poisoned window). undefined while a decoder is live. */
  private coolingSince?: number;
  // AudioDecoder's error callback gives a generic DOMException with no reference
  // to which chunk failed, so keep a small rolling window of what we recently
  // fed it. Always populated (small, cheap) — you can't arm the debug flag after
  // the error already happened, and issue #22 needs this for every error.
  private recentFrames: FrameForensic[] = [];
  // Per-track give-up summary (logged when we stop restarting).
  private readonly startedAt: number;
  private totalFramesDecoded = 0;
  private totalErrors = 0;
  private framesDroppedRecovering = 0;
  /** RED payloads unwrapped to their primary block (see unwrapRedPayload). */
  private redFramesUnwrapped = 0;
  private firstErrorReason?: string;
  private lastErrorReason?: string;

  constructor(
    private readonly track: MediaStreamTrack,
    private readonly onFrame: (frame: AudioDataLike) => void,
    private readonly onFatalError: (reason: string) => void,
    private readonly deps: MeetDecodeDeps = {},
  ) {
    this.subscribe = deps.subscribe ?? setEncodedAudioListener;
    this.now = deps.now ?? (() => Date.now());
    this.startedAt = this.now();
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
        output: (frame) => this.onDecodedFrame(frame),
        error: (err) => this.onDecoderError(`AudioDecoder error: ${err.message ?? String(err)}`),
      });
      // Stereo, not mono: every "Decoding error" frame captured live carries
      // TOC 0xef — Opus config 29 with the STEREO flag set. Meet switches its
      // per-speaker stream between mono and stereo packets mid-call, and a
      // mono-configured decoder dies on each stereo packet (journal #45's
      // whole error class, root-caused 2026-07-24 during the drift capture —
      // dev/captures/2026-07-24-meet-collections-drift.md). An Opus decoder
      // configured stereo decodes BOTH: mono packets upmix to two identical
      // channels, and consume()'s downmix folds either shape back to mono.
      this.decoder.configure({ codec: "opus", sampleRate: 48000, numberOfChannels: 2 });
      this.framesSinceBuild = 0;
      this.coolingSince = undefined;
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

  /** A frame decoded successfully. Track health so a decoder that gets going
   * again resets the restart budget (its failure was a distinct incident, not a
   * spiral). */
  private onDecodedFrame(frame: AudioDataLike): void {
    this.framesSinceBuild++;
    this.totalFramesDecoded++;
    if (this.framesSinceBuild === DECODER_HEALTHY_FRAMES && this.restarts.length > 0) {
      console.debug(
        `[ears][capture] ${this.track.id} decoder recovered — ` +
          `${DECODER_HEALTHY_FRAMES} frames decoded since rebuild; restart budget reset`,
      );
      this.restarts = [];
    }
    this.onFrame(frame);
  }

  /** Decoder-level failure (error callback or decode() throw). A decoder that
   * was healthy rebuilds immediately; a barren one cools down (see the class
   * comment) so a poisoned burst can't spiral through the budget. */
  private onDecoderError(reason: string): void {
    if (this.stopped) return;
    const now = this.now();
    this.totalErrors++;
    this.firstErrorReason ??= reason;
    this.lastErrorReason = reason;

    const decodedThisLife = this.framesSinceBuild;
    const healthy = decodedThisLife >= DECODER_HEALTHY_FRAMES;
    this.logDecoderError(reason, decodedThisLife, healthy);
    this.closeDecoder();

    if (healthy) {
      // Isolated error after a clean run — a distinct incident, not the spiral.
      // Rebuild immediately (near-zero audio loss) and clear the barren budget.
      this.restarts = [];
      console.warn(`[ears][capture] ${this.track.id} decoder rebuilt in place after a healthy run — ${reason}`);
      this.buildDecoder();
      return;
    }

    // Barren: the decoder died before proving it could decode from here. Don't
    // re-feed the same frames — cool down, dropping them, and rebuild on the
    // next live frame past the cooldown (see onEncodedFrame). Budget is spent at
    // that rebuild, so barren restarts can't accumulate faster than one per
    // cooldown.
    this.coolingSince = now;
    const pending = this.restarts.filter((t) => now - t <= DECODER_RESTART_WINDOW_MS).length;
    console.warn(
      `[ears][capture] ${this.track.id} decoder died barren (${decodedThisLife} frame(s) since rebuild) — ` +
        `cooling down ${DECODER_RESTART_COOLDOWN_MS}ms before restart ${pending + 1}/${DECODER_MAX_RESTARTS}`,
    );
  }

  /** Rebuild after a barren restart's cooldown. Spends a budget slot; gives up
   * (fatal, exactly once) if the budget is exhausted. Returns false on give-up. */
  private restartDecoder(): boolean {
    const now = this.now();
    this.restarts = this.restarts.filter((t) => now - t <= DECODER_RESTART_WINDOW_MS);
    if (this.restarts.length >= DECODER_MAX_RESTARTS) {
      this.giveUp(now);
      return false;
    }
    this.restarts.push(now);
    console.warn(
      `[ears][capture] ${this.track.id} decoder restart ${this.restarts.length}/${DECODER_MAX_RESTARTS} ` +
        `(resuming at a fresh frame; ${this.framesDroppedRecovering} frame(s) dropped while recovering)`,
    );
    return this.buildDecoder();
  }

  /** Restart budget exhausted: log a per-track summary and go fatal once. */
  private giveUp(now: number): void {
    const seconds = ((now - this.startedAt) / 1000).toFixed(1);
    console.error(
      `[ears][capture] ${this.track.id} giving up — capture summary: ` +
        `${this.totalFramesDecoded} frame(s) decoded over ${seconds}s, ` +
        `${this.totalErrors} decoder error(s), ${this.restarts.length} restart(s) in window, ` +
        `${this.framesDroppedRecovering} frame(s) dropped while recovering, ` +
        `${this.redFramesUnwrapped} RED payload(s) unwrapped; ` +
        `first error: ${this.firstErrorReason ?? "n/a"}; last error: ${this.lastErrorReason ?? "n/a"}`,
    );
    this.onFatalError(
      `${this.lastErrorReason ?? "decoder error"} — ${this.restarts.length} decoder restarts within ` +
        `${DECODER_RESTART_WINDOW_MS / 1000}s, giving up`,
    );
  }

  private logDecoderError(reason: string, decodedThisLife: number, healthy: boolean): void {
    const last = this.recentFrames.at(-1);
    const frameDesc = last
      ? `${last.byteLength}B ts=${last.timestamp} toc=0x${(last.toc & 0xff).toString(16).padStart(2, "0")}`
      : "none";
    console.error(
      `[ears][capture] ${this.track.id} ${reason} — ${healthy ? "decoder was healthy" : "barren decoder"}, ` +
        `${decodedThisLife} frame(s) decoded since rebuild; failing frame ~${frameDesc}`,
    );
    if (DEBUG_AUDIO_NOW()) {
      console.debug(
        `[ears][debug][audio] ${this.track.id} decoder error — last ${this.recentFrames.length} frames fed:`,
        this.recentFrames,
      );
    }
  }

  private onEncodedFrame(raw: EncodedAudioFrameLike): void {
    if (this.stopped) return;
    // Meet interleaves RED-encapsulated packets into the Opus stream when its
    // redundancy kicks in; unwrap those to their primary Opus block before
    // decode (see unwrapRedPayload). Non-RED payloads pass through untouched.
    let frame = raw;
    const primary = unwrapRedPayload(raw.data);
    if (primary) {
      frame = { data: primary, timestamp: raw.timestamp };
      this.redFramesUnwrapped++;
      if (this.redFramesUnwrapped === 1) {
        console.debug(
          `[ears][capture] ${this.track.id} RED-encapsulated audio detected — unwrapping primary Opus blocks`,
        );
      }
    }
    this.recordFrame(frame);
    if (!this.decoder) {
      // Decoder died and is cooling down: drop frames from before the next
      // decodable boundary rather than re-feeding the poisoned window into a
      // fresh decoder (the old restart spiral). Rebuild once the cooldown has
      // elapsed, resuming at this live frame.
      const cooling = this.coolingSince ?? 0;
      if (this.now() - cooling < DECODER_RESTART_COOLDOWN_MS) {
        this.framesDroppedRecovering++;
        return;
      }
      if (!this.restartDecoder()) return; // gave up — fatal already reported
    }
    if (!this.decoder || !this.chunkCtor) return;
    try {
      // Opus has no inter-frame prediction — every chunk is a keyframe.
      this.decoder.decode(new this.chunkCtor({ type: "key", timestamp: frame.timestamp, data: frame.data }));
    } catch (err) {
      this.onDecoderError(`decode() threw: ${String(err)}`);
    }
  }

  private recordFrame(frame: EncodedAudioFrameLike): void {
    const toc = frame.data.byteLength > 0 ? new Uint8Array(frame.data)[0]! : -1;
    this.recentFrames.push({ byteLength: frame.data.byteLength, timestamp: frame.timestamp, toc });
    if (this.recentFrames.length > 8) this.recentFrames.shift();
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
        console.warn(`[ears][capture] ring overflow for ${this.label}: dropped ${this.dropped} frame(s)`);
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
