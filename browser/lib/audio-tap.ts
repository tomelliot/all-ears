import { isCurrentEpoch } from "./epoch";
import { livePeerConnections, liveTracks, setTrackSink, type TrackRecord, type TrackSink } from "./rtc-hook";
import { diagnoseSilentTrack } from "./silent-diagnosis";
import {
  trackProvenance,
  webAudioTracks,
  type TrackProvenanceRecord,
} from "./track-provenance";
import { meetDecodeSource } from "./meet-decode";
import {
  SeamArbiter,
  seamUsesReceiverTracks,
  seamOrderFor,
  seamTracksToAdopt,
  seamTracksToRetire,
  admitReceiverTrack,
  type SeamId,
} from "./capture-seams";
import type { PlatformAdapter } from "./identity/adapter";
import { flushAttribution, recordAttribution } from "./attribution-recorder";
import type { AttributionEvent } from "./attribution-log";
import {
  postToIsolated,
  syntheticParticipant,
  type MainMessage,
  type ParticipantOrigin,
  type ParticipantRef,
  type Platform,
} from "./protocol";
import type { PlatformParticipantId } from "./identity/adapter";
import { perfEnabled } from "./perf-main";
import { captureMetrics } from "./capture-instrumentation";
import {
  TrackCapture,
  trackProcessorSource,
  type CaptureHooks,
  type FrameSourceFactory,
} from "./frame-pipeline";

// The per-epoch capture sink. Owns the N→N map: one live MediaStreamTrack →
// one isolated pipeline. Every pipeline records under a stable per-track
// handle (`t<n>`); identity never rides the source id — a resolved platform
// id flows to the daemon as an attendee upsert linking the handle's source
// (see handleIdentity), so identity can never block or restart audio.
//
// Each pipeline: a platform-dependent frame source → downmix → resample to
// 16 kHz mono → Int16 frames → a bounded ring buffer → postToIsolated. Two
// frame sources feed the same downstream logic (frame-pipeline.ts /
// meet-decode.ts): MediaStreamTrackProcessor for Zoom/Teams, and an
// AudioDecoder fed by rtc-hook.ts's Meet encoded-audio tee for Meet. Neither
// is ever connected to an AudioContext destination: no playback, no feedback
// into the user's mic.
//
// The admission/orchestration layer lives in the CaptureOrchestrator class
// (R7): every effect it needs — the hook registries, the message poster, the
// flight recorder, the clock, the seam arbiter, the frame-source factories —
// is injected through CaptureDeps, so the layer that composes the tested leaf
// policies is itself constructible in a test with fakes (finding F1). One
// production instance per module instance (i.e. per injected epoch's realm
// module), holding exactly the state the old module-level `let`s held.

/**
 * Where a pipeline's frames come from. Receiver-based seams carry the RTC
 * context the adapter's `identify()` needs; the others have none, so their
 * sources stay anonymous until speaking correlation names their owner.
 */
interface PipelineOrigin {
  seam: SeamId;
  rtc?: { stream: MediaStream };
  /** Source track id when the captured track is a clone (non-receiver seams). */
  sourceTrackId?: string;
}

interface Pipeline {
  participant: ParticipantRef;
  generation: number;
  origin: PipelineOrigin;
  stop(): void;
  /** Whether this pipeline has decoded at least one audio frame (debug report). */
  receiving(): boolean;
}

export interface CaptureConfig {
  epoch: number;
  platform: Platform;
  adapter: PlatformAdapter | null;
}

interface TeardownWindow extends Window {
  __earsTeardown?: () => void;
}

// Low-frequency safety net: sweep liveTracks() for any track this epoch owns
// but has no pipeline for, and (re)adopt it. Covers a new-attendee track whose
// dispatchTrack landed between epoch handoff replays, and any pipeline that
// died without the track ending (belt-and-braces alongside decoder restart).
const RECONCILE_INTERVAL_MS = 3000;

/**
 * Everything the orchestration layer touches outside itself (R7 injection
 * seam). Production wiring is `productionDeps()` below; tests supply fakes
 * for all of it — which is the whole point of the class.
 */
export interface CaptureDeps {
  /** Post a message to the isolated relay (postToIsolated in production). */
  post(msg: MainMessage): void;
  /** Record a flight-recorder event (recordAttribution in production). */
  record(event: AttributionEvent): void;
  /** Flush the flight recorder's pending batch (flushAttribution). */
  flush(): void;
  /** ms clock (Date.now in production). */
  now(): number;
  /** Whether `epoch` is still the newest claimed (epoch.ts). */
  isCurrentEpoch(epoch: number): boolean;
  /** Point the realm's constructor hook at this epoch's sink (rtc-hook.ts). */
  setTrackSink(sink: TrackSink): void;
  /** The hook's live receiver-track registry (rtc-hook.ts). */
  liveTracks(): Map<MediaStreamTrack, TrackRecord>;
  /** Tracks Meet routed into WebAudio — the webaudio seam's supply (rtc-hook.ts). */
  webAudioTracks(): MediaStreamTrack[];
  /** Local/remote lineage for a track id (rtc-hook.ts). */
  trackProvenance(id: string): TrackProvenanceRecord | undefined;
  /** The escalation state machine for a platform's seam order (capture-seams.ts). */
  makeArbiter(platform: Platform): SeamArbiter;
  /** Frame source for the meet-encoded-tee seam (meet-decode.ts). */
  meetDecodeSource(track: MediaStreamTrack): FrameSourceFactory;
  /** Frame source for every track-shaped seam (frame-pipeline.ts). */
  trackProcessorSource(track: MediaStreamTrack): FrameSourceFactory;
}

function productionDeps(): CaptureDeps {
  return {
    post: postToIsolated,
    record: recordAttribution,
    flush: flushAttribution,
    now: () => Date.now(),
    isCurrentEpoch,
    setTrackSink,
    liveTracks,
    webAudioTracks,
    trackProvenance,
    makeArbiter: (platform) => new SeamArbiter(seamOrderFor(platform)),
    meetDecodeSource,
    trackProcessorSource,
  };
}

/** The admission/orchestration layer — see the module header. */
export class CaptureOrchestrator {
  private readonly pipelines = new Map<MediaStreamTrack, Pipeline>();
  // Which seam this call is capturing through, and the escalation state machine
  // that moves off a seam producing no audio. Rebuilt per epoch in initCapture.
  private arbiter: SeamArbiter | undefined;
  // Registry track id → the clone we captured it under, for seams whose tracks
  // come from somewhere other than the `ontrack` hook. Keyed by the ORIGINAL id
  // so a re-adoption sweep doesn't capture the same source track twice; the
  // clone's own id differs and is what reaches `pipelines`.
  private readonly adoptedSeamTracks = new Map<string, MediaStreamTrack>();
  private readonly generations = new Map<string, number>(); // capture handle → segment counter
  // Source handles: one short opaque slug (`t<n>`) per admitted track, minted at
  // first admission and NEVER changed for the track's life (R3). The earsd
  // source id is `browser:<platform>:<slug>` — a handle on a captured track,
  // carrying no identity guess. Whose voice a source carries lives exclusively
  // in the attendee/speaker layer (participant-identified upserts, and the
  // daemon's reconciled `[[speaker]]` map). Keyed by the SOURCE track id
  // (`origin.sourceTrackId` for clone-captured seams) so a re-adoption — epoch
  // handoff, reconcile sweep, fresh clone of the same page track — keeps the
  // handle. Bounded by the tracks seen in the page's life; never cleared.
  private trackHandleCounter = 0;
  private readonly trackHandles = new Map<string, ParticipantRef>();
  // track.id → the handle its pipeline captured under, so an identity that
  // confirms by track id (adapter onIdentity) — even after the track died —
  // can be translated back to the source whose audio is on disk.
  private readonly participantsByTrackId = new Map<string, ParticipantRef>();
  private cfg: CaptureConfig | undefined;

  // True once ANY participant on this call has produced a decoded frame. Gates the
  // per-track silent warning: Meet legitimately delivers no audio for an unmuted
  // but silent participant (DTX / noise suppression), so "unmuted + no frames" is
  // not on its own proof of breakage. Only escalate to a loud "SILENT" warning
  // when nothing has decoded anywhere on the call (see silentReport). Not reset
  // by initCapture, so it survives same-module epoch handoffs (a capture toggle
  // off/on mid-call must not forget that audio once flowed). It does NOT survive
  // a genuine re-injection: each injected epoch loads a fresh module instance
  // (see rtc-hook.ts's header) and with it a fresh orchestrator, so the flag
  // starts false there and the silent warning is merely re-armed — a false
  // negative it may repeat, never suppress.
  private anyAudioDecodedThisCall = false;

  private reconcileTimer: ReturnType<typeof setInterval> | undefined;

  /**
   * Receiver tracks deferred because they were muted when dispatched, keyed to
   * their listener cleanup.
   *
   * Meet pre-allocates remote audio transceivers before there is anyone to fill
   * them — journal #142 saw three in a SOLO call, and #165 confirmed the same
   * three on a two-person call with only the carrying one ever unmuting. Every
   * one that reaches ``startPipeline`` becomes a phantom track-handle attendee
   * in session.toml and an `attendee_joined` in events.jsonl, for a participant
   * who does not exist; that noise has been in every session file since July.
   *
   * `muted` is the discriminator, and it costs nothing to wait on: a muted track
   * carries no audio by definition, and ``AudioFrameSource`` already could not
   * build its processor until the same edge (a MediaStreamTrackProcessor
   * constructed on a muted track never delivers frames, even after it unmutes).
   * So the pipeline was always going to start at first unmute — this only stops
   * us announcing a participant before then.
   *
   * NOTE this covers receiver/`ontrack` tracks only. The webaudio seam's tracks
   * all report `muted=false` even when inert: on the 2026-08-12 call all three
   * were unmuted, yet `webaudio-track-2` and `-3` transcribed to zero segments
   * (#171). Suppressing those needs a different signal — they carry frames, the
   * frames are just silent — and silence alone must not retire a source, because
   * a genuinely quiet participant looks identical (DTX / noise suppression).
   */
  private readonly deferredMutedTracks = new Map<MediaStreamTrack, () => void>();

  /** Track ids already recorded as `track-appeared` (flight recorder) — the
   * reconcile sweep re-runs sink/adoption every 3s, and appearance is news once. */
  private readonly appearedTracks = new Set<string>();

  /** Skip decisions already logged, so the 3s reconcile sweep states each one
   * once instead of repeating it for the rest of the call. */
  private readonly loggedSeamSkips = new Set<string>();

  // The orchestration-side callbacks every TrackCapture gets (frame-pipeline.ts
  // owns the interface). One shared object: they all read the same epoch state.
  private readonly captureHooks: CaptureHooks = {
    post: (msg) => this.deps.post(msg),
    record: (event) => this.deps.record(event),
    now: () => this.deps.now(),
    platform: () => this.cfg?.platform,
    anyAudioDecoded: () => this.anyAudioDecodedThisCall,
    noteFirstFrame: (seam) => {
      this.anyAudioDecodedThisCall = true;
      // Proves the seam for the whole call — from here it is never escalated
      // off, so a participant simply going quiet can't cause seam churn.
      this.arbiter?.noteFrame(this.deps.now(), seam);
    },
    noteUnmute: () => this.arbiter?.noteUnmute(this.deps.now()),
    diagnoseSilent: (track) =>
      diagnoseSilentTrack(track, livePeerConnections(), document.querySelectorAll<HTMLMediaElement>("audio,video")),
    onTrackSpeaking: (track, speaking) => this.cfg?.adapter?.onTrackSpeaking?.(track, speaking),
  };

  constructor(private readonly deps: CaptureDeps) {}

  /**
   * Take over capture for `config.epoch`. Tears down the previous epoch's
   * pipelines (no doubling), points the hook's sink here, and replays the live
   * track registry (no dropped streams) so a re-inject is seamless.
   */
  initCapture(config: CaptureConfig): void {
    this.cfg = config;

    const g = window as unknown as TeardownWindow;
    const prevTeardown = g.__earsTeardown;
    const epochAdapter = config.adapter;
    g.__earsTeardown = (): void => {
      this.teardownAll();
      // The epoch owns its adapter: hook.content.ts mints a fresh one per epoch,
      // and tearing the epoch down disposes it, so identity state (the Meet
      // engine's bindings, roster, correlators) never outlives the capture it
      // served (refactor plan R2; bug B10). Captured in this closure, not read
      // from `cfg` — by the time a superseding initCapture runs this teardown,
      // `cfg` already names the NEW epoch's adapter. After teardownAll so the
      // final attribution flush precedes disposal.
      try {
        epochAdapter?.dispose?.();
      } catch {
        // best-effort — identity teardown must never affect capture teardown
      }
    };
    prevTeardown?.(); // stop the superseded epoch before we start emitting

    this.arbiter = this.deps.makeArbiter(config.platform);
    this.adoptedSeamTracks.clear();

    this.deps.setTrackSink(this.sink);
    config.adapter?.onIdentity?.((trackId, id) => this.handleIdentity(trackId, id));
    // Forward roster names (id → display name) the adapter resolves to the daemon,
    // decoupled from track capture, so a participant's name reaches session.toml
    // even when the speaking-onset correlation never tied them to a track (#23).
    config.adapter?.onRoster?.((entries) => {
      // Reads the CURRENT cfg, not the registering epoch's: same-module epoch
      // handoffs keep the newest epoch authoritative (as the module-level `cfg`
      // read always did), and a superseded adapter is disposed anyway.
      if (!this.cfg || !this.deps.isCurrentEpoch(this.cfg.epoch) || entries.length === 0) return;
      this.deps.post({ kind: "participant-roster", platform: this.cfg.platform, entries });
    });

    // Catch-up: adopt tracks that were already live when this epoch loaded.
    for (const [track, rec] of this.deps.liveTracks()) {
      this.sink(track, rec.stream);
    }

    // Arm the reconciler for this epoch (prevTeardown cleared any prior timer).
    if (this.reconcileTimer !== undefined) clearInterval(this.reconcileTimer);
    this.reconcileTimer = setInterval(() => this.reconcile(), RECONCILE_INTERVAL_MS);

    this.deps.post({ kind: "status", text: `capture epoch ${config.epoch} active (${config.platform})` });
    console.debug(`[ears][capture] capture active — epoch ${config.epoch}, platform ${config.platform}`);
  }

  /** Capture-side state for the popup's debug report (see hook.content.ts). */
  debugState(): {
    platform: Platform | undefined;
    epoch: number | undefined;
    pipelineCount: number;
    anyAudioDecodedThisCall: boolean;
    /** Active seam and whether a frame has proved it — the first thing to read
     * when a call records silence (journal #100-#106). */
    seam: { active: string; proven: boolean; exhausted: boolean } | undefined;
    participants: Array<{
      id: string;
      origin: ParticipantOrigin;
      generation: number;
      receiving: boolean;
      seam: SeamId;
      sourceTrackId?: string;
    }>;
  } {
    return {
      platform: this.cfg?.platform,
      epoch: this.cfg?.epoch,
      pipelineCount: this.pipelines.size,
      anyAudioDecodedThisCall: this.anyAudioDecodedThisCall,
      seam: this.arbiter
        ? { active: this.arbiter.active, proven: this.arbiter.proven, exhausted: this.arbiter.exhausted }
        : undefined,
      participants: [...this.pipelines.values()].map((p) => ({
        id: p.participant.id,
        origin: p.participant.kind,
        generation: p.generation,
        receiving: p.receiving(),
        seam: p.origin.seam,
        sourceTrackId: p.origin.sourceTrackId,
      })),
    };
  }

  /**
   * A confirmed platform identity for a captured track — pushed by an adapter
   * (Meet's speaking-onset correlation, see lib/identity/meet.ts) at any point
   * in the track's life, including after it ended. The pipeline is untouched:
   * the source keeps its handle, no frames are lost, and no spurious
   * `participant-left` is stamped (R3; the restart this replaced was bug B11).
   * The identity is forwarded as an attendee upsert linking this source.
   */
  private handleIdentity(trackId: string, id: PlatformParticipantId): void {
    if (!this.cfg || !this.deps.isCurrentEpoch(this.cfg.epoch)) return;
    const captured = this.participantsByTrackId.get(trackId);
    if (!captured) return;
    this.postIdentity(trackId, captured.id, id);
  }

  /** Forward a confirmed identity: an attendee upsert joining the platform id
   * (and display name, when the adapter has one) to the source handle whose
   * audio is on disk. Recorded in the flight log with the track id so a replay
   * can join it to the engine's `provisional-binding` events (the cause). */
  private postIdentity(trackId: string, captureId: string, id: PlatformParticipantId): void {
    const displayName = this.cfg?.adapter?.displayName?.(id);
    this.deps.record({
      type: "identity-link",
      t: this.deps.now(),
      trackId,
      captureId,
      participantId: id,
    });
    this.deps.post({
      kind: "participant-identified",
      platform: this.cfg!.platform,
      participantId: id,
      captureId,
      ...(displayName ? { displayName } : {}),
    });
    console.debug(
      `[ears][capture] identity: source ${captureId} → ${id}${displayName ? ` "${displayName}"` : ""}`,
    );
  }

  /** Start once `track` unmutes, so a never-filled transceiver never becomes an
   * attendee. Idempotent per track; self-cleaning on unmute, end, or teardown.
   * (See the `deferredMutedTracks` field comment for why this path exists.) */
  private deferUntilUnmuted(track: MediaStreamTrack, stream: MediaStream): void {
    if (this.deferredMutedTracks.has(track)) return;
    const epoch = this.cfg!.epoch;
    const cleanup = (): void => {
      track.removeEventListener("unmute", onUnmute);
      track.removeEventListener("ended", onEnded);
      this.deferredMutedTracks.delete(track);
    };
    const onUnmute = (): void => {
      cleanup();
      this.deps.record({ type: "track-unmuted", t: this.deps.now(), trackId: track.id });
      // Re-run the same admission check sink ran: an epoch handoff, a seam
      // escalation, or another path adopting this track may all have happened
      // while we waited. `muted` is false by definition on this edge.
      if (!this.deps.isCurrentEpoch(epoch)) return;
      const seam = this.activeSeam();
      if (
        admitReceiverTrack(seam, {
          muted: false,
          alreadyCapturing: this.pipelines.has(track),
          ended: track.readyState === "ended",
        }) !== "start"
      )
        return;
      this.startPipeline(track, { seam, rtc: { stream } });
    };
    const onEnded = (): void => {
      cleanup();
      this.deps.record({ type: "track-ended", t: this.deps.now(), trackId: track.id });
      console.debug(
        `[ears][capture] muted receiver track ${track.id} ended without ever unmuting` +
          ` — no attendee was created (pre-allocated transceiver, journal #165)`,
      );
    };
    track.addEventListener("unmute", onUnmute);
    track.addEventListener("ended", onEnded);
    this.deferredMutedTracks.set(track, cleanup);
    this.deps.record({
      type: "deferred",
      t: this.deps.now(),
      trackId: track.id,
      seam: this.activeSeam(),
      reason: "muted at dispatch — waiting for first unmute (journal #165)",
    });
    console.debug(`[ears][capture] deferring muted receiver track ${track.id} until it unmutes`);
  }

  readonly sink: TrackSink = (track, stream) => {
    if (!this.cfg || !this.deps.isCurrentEpoch(this.cfg.epoch)) return; // a newer epoch owns capture
    const seam = this.activeSeam();
    this.noteTrackAppeared(track, seam);
    switch (
      admitReceiverTrack(seam, {
        muted: track.muted,
        alreadyCapturing: this.pipelines.has(track),
        ended: track.readyState === "ended",
      })
    ) {
      case "skip":
        return;
      case "defer-until-unmute":
        return this.deferUntilUnmuted(track, stream);
      case "start":
        return this.startPipeline(track, { seam, rtc: { stream } });
    }
  };

  private noteTrackAppeared(track: MediaStreamTrack, seam: SeamId): void {
    if (this.appearedTracks.has(track.id)) return;
    this.appearedTracks.add(track.id);
    const prov = this.deps.trackProvenance(track.id);
    this.deps.record({
      type: "track-appeared",
      t: this.deps.now(),
      trackId: track.id,
      seam,
      muted: track.muted,
      ...(prov ? { origin: prov.origin, rootId: prov.rootId } : {}),
    });
  }

  private activeSeam(): SeamId {
    return (this.arbiter?.active ?? "receiver-track") as SeamId;
  }

  /**
   * Adopt every track the active seam offers that isn't already captured.
   *
   * Non-receiver seams capture a CLONE: the source track is one the page is
   * actively playing, and a MediaStreamTrackProcessor consumes the track it is
   * given. Cloning keeps Meet's own playback whole — verified read-only during
   * the live investigation before this path existed (journal #105).
   */
  private adoptSeamTracks(): void {
    const seam = this.activeSeam();
    if (seam !== "webaudio-track") return; // no other seam self-discovers tracks
    const available = this.deps.webAudioTracks();
    const adopted = new Set(this.adoptedSeamTracks.keys());
    // Provenance for available AND adopted ids: an already-adopted clone must
    // settle its whole lineage root, or the sweep adopts its siblings later.
    const provenance = new Map<string, TrackProvenanceRecord>();
    for (const id of [...available.map((t) => t.id), ...adopted]) {
      const record = this.deps.trackProvenance(id);
      if (record) provenance.set(id, record);
    }
    // Retire before adopting: a track named `local` since it was adopted is the
    // user's own audio arriving over a second road, and the sweep is the first
    // moment that verdict can be acted on. Freeing its lineage root first also
    // lets a genuine sibling be adopted in the same pass.
    for (const id of seamTracksToRetire(adopted, provenance)) {
      this.retireSeamTrack(id, provenance.get(id));
      adopted.delete(id);
    }

    const wanted = new Set(seamTracksToAdopt(seam, available.map((t) => t.id), adopted, provenance));
    for (const source of available) {
      if (!wanted.has(source.id)) {
        if (!adopted.has(source.id) && !this.loggedSeamSkips.has(source.id)) {
          this.loggedSeamSkips.add(source.id);
          const record = provenance.get(source.id);
          const reason =
            record?.origin === "local"
              ? `local via=${record.via} root=${record.rootId}`
              : `duplicate of root ${record?.rootId ?? source.id}`;
          console.debug(`[ears][capture] skip webaudio track ${source.id}: ${reason}`);
        }
        continue;
      }
      let clone: MediaStreamTrack;
      try {
        clone = source.clone();
      } catch (err) {
        console.debug(`[ears][capture] could not clone webaudio track ${source.id}: ${String(err)}`);
        continue;
      }
      const record = provenance.get(source.id);
      const provDesc = record ? `${record.origin} via=${record.via}` : "unknown provenance";
      console.debug(`[ears][capture] adopt webaudio track ${source.id} (${provDesc})`);
      this.noteTrackAppeared(source, seam);
      this.deps.record({ type: "adopted", t: this.deps.now(), trackId: source.id, seam, reason: provDesc });
      this.adoptedSeamTracks.set(source.id, clone);
      this.startPipeline(clone, { seam, sourceTrackId: source.id });
    }
  }

  /**
   * Stop capturing a track that proved to be the user's own audio.
   *
   * Deliberately the same teardown a seam escalation performs — stop the
   * pipeline, stop our clone, forget the adoption — so the daemon sees the
   * ordinary `participant-left` shape it already handles, not a new one. The
   * source keeps whatever it captured before the verdict landed: a few seconds
   * of duplicate audio is the price of "unknown adopts", and far cheaper than
   * the whole call.
   */
  private retireSeamTrack(id: string, record?: TrackProvenanceRecord): void {
    const clone = this.adoptedSeamTracks.get(id);
    this.adoptedSeamTracks.delete(id);
    this.deps.record({
      type: "retired",
      t: this.deps.now(),
      trackId: id,
      reason: `local via=${record?.via ?? "?"} root=${record?.rootId ?? id}`,
    });
    console.debug(
      `[ears][capture] retire webaudio track ${id}: ` +
        `local via=${record?.via ?? "?"} root=${record?.rootId ?? id} ` +
        "(the daemon's mic source already records this audio)",
    );
    // The track stays in the WebAudio registry, so this sweep will offer it
    // again and the adopt policy will decline it. Mark the skip as already
    // stated: the retire line above is the explanation, and a "skip" line
    // immediately under it would say the same thing twice.
    this.loggedSeamSkips.add(id);
    if (!clone) return;
    this.stopPipeline(clone);
    clone.stop();
  }

  /**
   * The active seam produced no audio in its grace window: tear its pipelines
   * down and adopt the next seam's tracks.
   *
   * Everything downstream of the frame source is seam-agnostic, so this is a
   * source swap rather than a capture restart — the daemon sees the same
   * participant-left / participant-joined shape it already handles for a
   * reconnect.
   */
  private escalateSeam(from: SeamId, to: SeamId): void {
    this.deps.record({
      type: "escalated",
      t: this.deps.now(),
      from,
      to,
      reason: "no frame decoded within the unmute grace window",
    });
    console.warn(
      `[ears][capture] no audio decoded on seam "${from}" — escalating to "${to}". ` +
        "See capture-seams.ts / journal #103-#105.",
    );
    this.deps.post({ kind: "status", text: `capture seam → ${to} (previous seam produced no audio)` });
    for (const track of [...this.pipelines.keys()]) this.stopPipeline(track);
    for (const clone of this.adoptedSeamTracks.values()) clone.stop();
    this.adoptedSeamTracks.clear();
    this.loggedSeamSkips.clear(); // the new seam re-decides every track — re-log
    // Re-adopt under the new seam. A seam with nothing to adopt right now still
    // gets its full grace — tracks can appear later when a participant joins,
    // and the arbiter re-arms on the next unmute either way.
    if (seamUsesReceiverTracks(to)) {
      for (const [track, rec] of this.deps.liveTracks()) this.sink(track, rec.stream);
    } else {
      this.adoptSeamTracks();
    }
  }

  private startPipeline(track: MediaStreamTrack, origin: PipelineOrigin): void {
    const participant = this.handleFor(track, origin);
    this.participantsByTrackId.set(track.id, participant);
    const generation = (this.generations.get(participant.id) ?? 0) + 1;
    this.generations.set(participant.id, generation);

    // Identity harvest — the handle stays what it is either way. Receiver-seam
    // tracks carry the RTC context the adapter can match on (Zoom's MSID parse,
    // Meet's tile correlation); a hit becomes an attendee upsert linking this
    // source, never a different source id. Other seams' tracks have ids that
    // never match a hooked receiver (rtc-hook.ts, ids-never-match finding), so
    // there is nothing to match on and their owner is named later — by the same
    // upsert — once speaking correlation resolves them.
    const platformId =
      origin.rtc && seamUsesReceiverTracks(origin.seam)
        ? (this.cfg?.adapter?.identify(track, origin.rtc.stream) ?? null)
        : null;

    // The active seam selects the frame source. Every track-shaped seam shares
    // the one MediaStreamTrackProcessor implementation — only Meet's encoded tee
    // needs a decoder of its own, because it carries encoded frames rather than
    // a track. See capture-seams.ts for why the seam is chosen at runtime.
    const makeSource =
      origin.seam === "meet-encoded-tee"
        ? this.deps.meetDecodeSource(track)
        : this.deps.trackProcessorSource(track);
    const capture = new TrackCapture(
      participant.id,
      () => pipeline.generation,
      makeSource,
      () => this.stopPipeline(track),
      track,
      origin.seam,
      this.captureHooks,
    );
    const pipeline: Pipeline = {
      participant,
      generation,
      origin,
      stop() {
        capture.stop();
      },
      receiving: () => capture.receiving,
    };
    this.pipelines.set(track, pipeline);
    capture.start();

    this.deps.record({
      type: "admitted",
      t: this.deps.now(),
      trackId: track.id,
      seam: origin.seam,
      participantId: participant.id,
      participantOrigin: participant.kind,
      generation,
    });
    this.deps.post({ kind: "participant-joined", platform: this.cfg!.platform, participant, generation });
    console.debug(
      `[ears][capture] +track → ${participant.id} (gen ${generation}) — ${this.pipelines.size} live`,
    );
    if (platformId) this.postIdentity(track.id, participant.id, platformId);

    // Lifecycle. Delete from the map *before* stop() so a late frame can't
    // resurrect a dead entry.
    const end = () => {
      this.deps.record({ type: "track-ended", t: this.deps.now(), trackId: track.id });
      this.stopPipeline(track);
    };
    track.addEventListener("ended", end);
    track.addEventListener("mute", () => {
      this.deps.record({ type: "track-muted", t: this.deps.now(), trackId: track.id });
      console.debug(`[ears][capture] mute → ${participant.id}`);
    });
    track.addEventListener("unmute", () => {
      this.deps.record({ type: "track-unmuted", t: this.deps.now(), trackId: track.id });
      console.debug(`[ears][capture] unmute → ${participant.id}`);
      // Meet identity: an unmute pairs with the collections channel's per-device
      // mic-open edge (the only per-device event that channel still carries).
      try {
        this.cfg?.adapter?.onTrackUnmute?.(track);
      } catch {
        // best-effort — identity must never affect capture
      }
    });
  }

  private stopPipeline(track: MediaStreamTrack): void {
    const pipeline = this.pipelines.get(track);
    if (!pipeline) return;
    this.pipelines.delete(track);
    pipeline.stop();
    this.deps.post({ kind: "participant-left", participantId: pipeline.participant.id, generation: pipeline.generation });
    console.debug(`[ears][capture] -track → ${pipeline.participant.id} (gen ${pipeline.generation}) — ${this.pipelines.size} live`);
  }

  private teardownAll(): void {
    if (this.reconcileTimer !== undefined) {
      clearInterval(this.reconcileTimer);
      this.reconcileTimer = undefined;
    }
    for (const track of [...this.pipelines.keys()]) this.stopPipeline(track);
    // Clones exist only for this epoch's capture; the page's own tracks are
    // untouched. Stopping them releases the processors holding them open.
    for (const clone of this.adoptedSeamTracks.values()) clone.stop();
    this.adoptedSeamTracks.clear();
    // Drop unmute listeners for tracks this epoch was waiting on; the next epoch
    // replays the live registry and re-defers whatever is still muted.
    for (const cleanup of [...this.deferredMutedTracks.values()]) cleanup();
    this.loggedSeamSkips.clear();
    // A superseded epoch's queued evidence still belongs to this call.
    this.deps.flush();
  }

  /** Adopt any epoch-owned live track that lost (or never got) a pipeline, and
   * re-harvest the participant roster so names for silent (never-speaking)
   * participants still reach the daemon (#23). Public: the 3s timer drives it
   * in production, tests drive it directly. */
  reconcile(): void {
    if (!this.cfg || !this.deps.isCurrentEpoch(this.cfg.epoch)) return;
    // Seam arbitration rides the existing sweep rather than adding a timer: the
    // grace window is seconds, so 3s resolution is ample and it keeps the whole
    // escalation on one cadence.
    const before = this.activeSeam();
    const next = this.arbiter?.tick(this.deps.now());
    if (next) this.escalateSeam(before, next as SeamId);
    for (const [track, rec] of this.deps.liveTracks()) {
      if (!this.pipelines.has(track)) this.sink(track, rec.stream);
    }
    this.adoptSeamTracks();
    this.cfg.adapter?.pollIdentities?.();
    // The attribution flight recorder's batch cadence rides this sweep too —
    // one 3s clock for everything low-frequency in the capture path.
    this.deps.flush();
    // Piggy-backed on the existing 3s sweep rather than adding a timer: the
    // pipeline count is what per-frame cost scales with, so it's the denominator
    // for every capture-stage number.
    if (perfEnabled()) captureMetrics().tracks.set(this.pipelines.size);
  }

  /**
   * The stable per-track handle for a pipeline: minted at first admission,
   * identical on every re-adoption of the same source track (see the
   * `trackHandles` comment). Deliberately opaque — the handle names a captured
   * track, never a person, so no binding mistake can ever be a recording
   * mistake (R3, finding F2).
   */
  private handleFor(track: MediaStreamTrack, origin: PipelineOrigin): ParticipantRef {
    const key = origin.sourceTrackId ?? track.id;
    const existing = this.trackHandles.get(key);
    if (existing) return existing;
    this.trackHandleCounter += 1;
    const handle = syntheticParticipant(`t${this.trackHandleCounter}`);
    this.trackHandles.set(key, handle);
    return handle;
  }

  /**
   * Dev-only: run a LOCAL MediaStream through the real capture path, bypassing
   * the RTC hook (the sandboxed test harness can't establish a WebRTC loopback).
   */
  devCaptureStream(stream: MediaStream, participantId: string, seam: SeamId): void {
    const track = stream.getAudioTracks()[0];
    if (!track) return;
    // Dev/graph-bridge ids (`graphtap-<n>`, harness labels) are ours, never the
    // platform's — declare them synthetic.
    this.deps.post({ kind: "participant-joined", platform: this.cfg?.platform ?? "meet", participant: syntheticParticipant(participantId), generation: 1 });
    new TrackCapture(participantId, () => 1, this.deps.trackProcessorSource(track), () => {}, track, seam, this.captureHooks).start();
  }
}

// The production instance: one per module instance, i.e. one per injected
// epoch's realm module — exactly the lifetime the old module-level state had.
// Constructing it has no side effects; nothing runs until initCapture.
const orchestrator = new CaptureOrchestrator(productionDeps());

/** See {@link CaptureOrchestrator.initCapture}. */
export function initCapture(config: CaptureConfig): void {
  orchestrator.initCapture(config);
}

/** See {@link CaptureOrchestrator.debugState}. */
export function captureDebugState(): ReturnType<CaptureOrchestrator["debugState"]> {
  return orchestrator.debugState();
}

/** See {@link CaptureOrchestrator.devCaptureStream}. */
export function __devCaptureStream(
  stream: MediaStream,
  participantId: string,
  seam: SeamId = "receiver-track",
): void {
  orchestrator.devCaptureStream(stream, participantId, seam);
}
