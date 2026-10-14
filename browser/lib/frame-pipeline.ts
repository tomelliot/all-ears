import type { MainMessage, Platform } from "./protocol";
import type { AttributionEvent } from "./attribution-log";
import type { SilentDiagnosis } from "./silent-diagnosis";
import { seamUsesReceiverTracks, type SeamId } from "./capture-seams";
import { perfDetailEnabled, perfEnabled } from "./perf-main";
import {
  audioLog,
  captureMetrics,
  DEBUG_AUDIO_NOW,
  SPEAK_THRESHOLD,
  type AudioLogEntry,
} from "./capture-instrumentation";

// The seam-agnostic frame pipeline (refactor R7): everything between "a frame
// source produced decoded audio" and "16 kHz mono Int16 frames left for the
// isolated relay" — resampler, ring buffer, the MediaStreamTrackProcessor
// frame source, and the silent-capture watchdog. No module state: each
// pipeline owns its instances, and the orchestration layer (audio-tap.ts)
// wires them together.

export const TARGET_SAMPLE_RATE = 16000;
// Bounded per-participant ring buffer. ~10 frames/s; 50 frames ≈ 5 s of slack
// before we drop the oldest frame (back-pressure toward the transport).
export const RING_CAPACITY = 50;

export const FRAME_SAMPLES = 1600; // 100 ms @ 16 kHz → ~10 frames/s

// WebCodecs AudioData surface we use (avoids ambient-declaration conflicts).
export interface AudioDataLike {
  readonly sampleRate: number;
  readonly numberOfFrames: number;
  readonly numberOfChannels: number;
  readonly format: string | null;
  copyTo(dest: Float32Array, options: { planeIndex: number; format?: string }): void;
  close(): void;
}

export interface FrameSource {
  /** Begin producing frames. Called at most once. */
  start(): void;
  /** Stop producing frames and release resources. Idempotent. */
  stop(): void;
}

export type FrameSourceFactory = (
  onFrame: (frame: AudioDataLike) => void,
  onFatalError: (reason: string) => void,
) => FrameSource;

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
  participantId: string,
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

// ── Standard path: MediaStreamTrackProcessor (Zoom, Teams) ─────────────────
//
// Read decoded audio frames straight off the MediaStreamTrack (WebCodecs
// breakout box). Unlike a WebAudio MediaStreamAudioSourceNode, this needs no
// AudioContext and no playing media element, so it doesn't hit the remote-track
// silence bug (verified: on real Meet the WebAudio tap read digital silence
// even with a playing mirror; the breakout box reads the true audio — though
// on Meet even this reads nothing at all, see MeetDecodeSource in
// meet-decode.ts).

type TrackProcessorCtor = new (init: { track: MediaStreamTrack }) => {
  readable: ReadableStream<AudioDataLike>;
};

export class TrackProcessorSource implements FrameSource {
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

export function trackProcessorSource(track: MediaStreamTrack): FrameSourceFactory {
  return (onFrame, onFatalError) => new TrackProcessorSource(track, onFrame, onFatalError);
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

/**
 * The orchestration-layer callbacks a TrackCapture needs (R7 injection seam).
 * Production wires these to the epoch's config, the seam arbiter, and
 * postToIsolated/recordAttribution (see audio-tap.ts); tests supply fakes.
 * Grouped as one object because they share one lifetime: the capture epoch.
 */
export interface CaptureHooks {
  /** Post a message to the isolated relay (postToIsolated in production). */
  post(msg: MainMessage): void;
  /** Record a flight-recorder event (recordAttribution in production). */
  record(event: AttributionEvent): void;
  /** ms clock (Date.now in production). */
  now(): number;
  /** The capture epoch's platform, for the silent report's hint. */
  platform(): Platform | undefined;
  /** Whether ANY track on this call has decoded a frame (see audio-tap.ts). */
  anyAudioDecoded(): boolean;
  /** First decoded frame on this track — proves the call and the active seam. */
  noteFirstFrame(seam: SeamId): void;
  /** The track unmuted — arms the call-level seam arbitration grace window. */
  noteUnmute(): void;
  /** Read the receiver's stats for a silent track (read-only). Optional so
   * fakes need not provide it. */
  diagnoseSilent?(track: MediaStreamTrack): Promise<SilentDiagnosis>;
  /** Edge-triggered speaking change, for the adapter's identity correlation. */
  onTrackSpeaking(track: MediaStreamTrack, speaking: boolean): void;
}

// ── Shared pipeline: frame source → 16 kHz mono pcm_s16le ───────────────────
// (frame-pipeline.ts holds the seam-agnostic pieces; TrackCapture composes them)

/** One track → its own frame source, resampler, ring buffer, and PCM emitter. */
export class TrackCapture {
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
  /** Monotonic per-participant frame counter stamped on every posted PCM frame
   * (wraps at 2^32 — ~2.7 years at this frame rate). Paired with a send
   * timestamp so earsd can distinguish silence from a stalled delivery path. */
  private seq = 0;

  constructor(
    private readonly participantId: string,
    private readonly currentGeneration: () => number,
    private readonly makeSource: FrameSourceFactory,
    private readonly onFatal: () => void,
    private readonly track: MediaStreamTrack,
    private readonly seam: SeamId,
    private readonly hooks: CaptureHooks,
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
    // The same unmute drives two things: the per-participant silent warning,
    // and the call-level seam arbitration (an unmute is the platform asserting
    // audio is flowing, so a frameless grace window means the SEAM is wrong,
    // not that this participant is quiet).
    this.unmuteHandler = () => {
      this.silentWatchdog.armOnUnmute();
      this.hooks.noteUnmute();
    };
    this.track.addEventListener("unmute", this.unmuteHandler);
    // A receiver-seam track admitted already-unmuted never fires that event
    // again — under defer-until-unmute admission (journal #173) the admitting
    // unmute preceded this listener — so arm now: an unmuted receiver track is
    // the platform making the same "audio is flowing" claim as the event
    // (journal #176: an inert-but-unmuted receiver track left the arbiter
    // unarmed and pinned the seam for a whole call). Non-receiver seams stay
    // event-armed: their tracks report muted=false even when inert (journal
    // #171), and arming those would fire spurious SILENT warnings for phantom
    // clones.
    if (seamUsesReceiverTracks(this.seam) && !this.track.muted) this.unmuteHandler();
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
    this.hooks.post({ kind: "capture-failed", participantId: this.participantId, generation: this.currentGeneration(), reason });
    this.stop();
    this.onFatal();
  }

  /** The silent-capture watchdog fired: this participant unmuted but no decoded
   * frame ever arrived. Loud console error plus a `status` line the isolated-
   * world relay logs (and can surface in the popup/daemon). See journal #72. */
  private reportSilent(graceMs: number): void {
    const report = silentReport(this.participantId, this.hooks.platform(), this.hooks.anyAudioDecoded(), graceMs);
    if (report.level === "warn") {
      console.error(`[ears][capture] ${report.text}`);
      this.hooks.post({ kind: "status", text: report.text });
      this.diagnoseSilent();
    } else {
      // Benign: the pipeline works, this participant is just quiet. Keep it low
      // so it never reads as a failure to a user scanning the console.
      console.debug(`[ears][capture] ${report.text}`);
    }
  }

  /** Record why the track is silent, into the session's attribution log. Best
   * effort: a failure here must never reach the capture path. */
  private diagnoseSilent(): void {
    const diagnose = this.hooks.diagnoseSilent;
    if (!diagnose) return;
    Promise.resolve()
      .then(() => diagnose(this.track))
      .then((diagnosis) => {
        console.error(`[ears][capture] ${this.participantId} silent: ${diagnosis.verdict}`, diagnosis);
        this.hooks.post({ kind: "status", text: `${this.participantId} silent: ${diagnosis.verdict}` });
        this.hooks.record({
          type: "silent-diagnosis",
          t: this.hooks.now(),
          trackId: this.trackId,
          participantId: this.participantId,
          diagnosis,
        });
      })
      .catch((err: unknown) => console.debug(`[ears][capture] silent diagnosis failed: ${String(err)}`));
  }

  private consume(frame: AudioDataLike): void {
    if (!this.firstFrameSeen) {
      this.firstFrameSeen = true;
      this.silentWatchdog.noteFrame();
      // Proves the seam for the whole call — from here it is never escalated
      // off, so a participant simply going quiet can't cause seam churn.
      this.hooks.noteFirstFrame(this.seam);
      console.debug(`[ears][capture] ✓ ${this.participantId} first audio frame — capture confirmed live`);
    }
    // Two boolean reads per frame. The `performance.now()` calls below are
    // detail-gated: at ~50 frames/s per active speaker they are cheap but not
    // free, and this runs on the thread Meet renders video on.
    const metrics = perfEnabled() ? captureMetrics() : null;
    const detail = metrics !== null && perfDetailEnabled();
    const t0 = detail ? performance.now() : 0;

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
    const tDownmix = detail ? performance.now() : 0;

    // Always tracked (not debug-gated): MeetAdapter's collections-datachannel
    // correlation needs a real speaking-edge signal, not just a debug log —
    // see lib/identity/meet.ts and PlatformAdapter.onTrackSpeaking.
    this.updateSpeaking(mono);
    const tSpeaking = detail ? performance.now() : 0;

    if (DEBUG_AUDIO_NOW()) this.debugLog(mono, inRate);
    const tDebugLog = detail ? performance.now() : 0;

    // Resample native → 16 kHz and slice into fixed frames.
    if (!this.resampler) this.resampler = new LinearResampler(inRate, TARGET_SAMPLE_RATE);
    const out = this.resampler.process(mono);
    const tResample = detail ? performance.now() : 0;

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
    const tAccumulate = detail ? performance.now() : 0;

    for (const f of this.ring.drain()) {
      // seq is per-participant and monotonic across the pipeline's life; the
      // daemon uses the pair to tell a silent speaker from a stalled extension.
      this.seq = (this.seq + 1) >>> 0;
      this.hooks.post({
        kind: "pcm",
        participantId: this.participantId,
        generation: this.currentGeneration(),
        samples: f,
        seq: this.seq,
        sentAt: this.hooks.now(),
      });
      metrics?.posted.add();
    }

    if (metrics) {
      metrics.frames.add();
      metrics.samples.add(nFrames);
      if (detail) {
        const tPost = performance.now();
        metrics.downmix.observe(tDownmix - t0);
        metrics.speaking.observe(tSpeaking - tDownmix);
        metrics.debugLog.observe(tDebugLog - tSpeaking);
        metrics.resample.observe(tResample - tDebugLog);
        metrics.accumulate.observe(tAccumulate - tResample);
        metrics.post.observe(tPost - tAccumulate);
        metrics.frame.observe(tPost - t0);
      }
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
    this.hooks.onTrackSpeaking(this.track, isSpeaking);
    // Always recorded (unlike the debug log below): these onsets are the audio
    // half of every speaking-onset correlation, so a recorded call can replay
    // the exact evidence the correlators saw.
    this.hooks.record({
      type: "audio-onset",
      t: this.hooks.now(),
      participantId: this.participantId,
      trackId: this.trackId,
      state: isSpeaking ? "start" : "stop",
      framePeak: Number(framePeak.toFixed(4)),
    });

    if (DEBUG_AUDIO_NOW()) {
      const t = this.hooks.now();
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


