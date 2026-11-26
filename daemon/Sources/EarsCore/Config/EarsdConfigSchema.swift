/// Built-in defaults and declared schema for `earsd`'s own config slice: the
/// `[earsd]` table, its nested `[earsd.vad]` table, and its `[[earsd.source]]`
/// array of tables. Values match the reference config in
/// `docs/configuration.md` exactly, except `[[earsd.source]]`'s default list:
/// the doc's `mic`/`system`/`app:us.zoom.xos` trio there is an *example*
/// config, not the zero-config default — per the "Conventions" section, "with
/// no file present, the daemon captures `mic` with the defaults", so the
/// built-in default source list is just that one enabled `mic` entry.
///
/// Like ``Phase0ConfigSchema``, this schema only declares its own slice
/// (`earsd`); the shared keys every tool needs (`data_root`, `output_root`,
/// `[log]`, ...) are Phase 0's concern. ``effectiveSchema``/``effectiveDefaults``
/// compose the two via ``ConfigSchema/union(_:)`` into what `earsd` actually
/// validates against, so a caller doesn't have to know how to combine them.
public enum EarsdConfigSchema {
  public static let defaults: ConfigValue = .table([
    "earsd": .table([
      "chunk_seconds": .int(30),
      "codec": .string("aac"),
      "bitrate": .int(64000),
      "native_sample_rate": .int(48000),
      "asr_sample_rate": .int(16000),
      "store_native": .bool(true),
      "channels": .int(1),
      "vad": .table([
        "backend": .string("silero"),
        "speech_pad_ms": .int(300),
        "min_silence_ms": .int(700),
      ]),
      "ingest_ws": .table([
        "enabled": .bool(false),
        "port": .int(47811),
        "allowed_origins": .array([]),
      ]),
      "control_ws": .table([
        "enabled": .bool(false),
        "port": .int(47812),
        "allowed_origins": .array([]),
      ]),
      "sessions": .table([
        "ingest_close_grace_s": .int(120),
        "rejoin_hold_s": .int(60),
        "local_sources": .array([.string("mic")]),
        "on_end_stages": .array([
          .string("transcribe"), .string("cleanup"), .string("summarize"),
        ]),
      ]),
      "retention": .table([
        "evict_after_transcript_seconds": .int(7200),
        "max_audio_age_seconds": .int(604800),
      ]),
      "source": .array([
        .table([
          "id": .string("mic"),
          "class": .string("mic"),
          "device_uid": .string(""),
        ])
      ]),
    ])
  ])

  /// Schema for a single `[[earsd.source]]` element. Every field is optional
  /// per-element (a source may override only some of the capture defaults);
  /// this schema engine has no "required field" concept, so an element
  /// omitting a key is simply not checked for it, matching the doc's examples
  /// (e.g. the `mic` source sets no `label`, the `system` source sets no
  /// `device_uid`).
  private static let sourceElementSchema = ConfigSchema(
    fields: [
      "id": ConfigSchema.Field(type: .string, description: "Unique source id."),
      "class": ConfigSchema.Field(
        type: .string, description: "Source class: mic, system, app, or device."),
      "device_uid": ConfigSchema.Field(
        type: .string, description: "Core Audio device UID (device-class sources)."),
      "label": ConfigSchema.Field(type: .string, description: "Human-readable label."),
      "enabled": ConfigSchema.Field(type: .bool, description: "Whether this source is captured."),
    ]
  )

  public static let schema = ConfigSchema(
    fields: [
      "earsd": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "chunk_seconds": ConfigSchema.Field(
              type: .int, description: "Length of each captured audio chunk, in seconds."),
            "codec": ConfigSchema.Field(
              type: .string, description: "Audio codec for stored chunks (e.g. \"aac\")."),
            "bitrate": ConfigSchema.Field(
              type: .int, description: "Encoder bitrate in bits per second."),
            "native_sample_rate": ConfigSchema.Field(
              type: .int, description: "Sample rate of the stored native-quality audio, in Hz."),
            "asr_sample_rate": ConfigSchema.Field(
              type: .int, description: "Sample rate of the ASR-facing downmix, in Hz."),
            "store_native": ConfigSchema.Field(
              type: .bool, description: "Keep the native-quality audio alongside the ASR downmix."),
            "channels": ConfigSchema.Field(
              type: .int, description: "Number of captured audio channels."),
            "vad": ConfigSchema.Field(
              type: .table,
              children: ConfigSchema(
                fields: [
                  "backend": ConfigSchema.Field(
                    type: .string, description: "Voice-activity-detection backend."),
                  "speech_pad_ms": ConfigSchema.Field(
                    type: .int, description: "Padding kept around detected speech, in milliseconds."
                  ),
                  "min_silence_ms": ConfigSchema.Field(
                    type: .int,
                    description: "Minimum silence to split speech segments, in milliseconds."),
                ]
              ),
              description: "Voice-activity detection (silence skipping)."),
            "ingest_ws": ConfigSchema.Field(
              type: .table,
              children: ConfigSchema(
                fields: [
                  "enabled": ConfigSchema.Field(
                    type: .bool, description: "Enable the browser-extension audio-ingest WebSocket."
                  ),
                  "port": ConfigSchema.Field(
                    type: .int, description: "Loopback port the ingest WebSocket listens on."),
                  // Array of scalars (origin strings) — left unvalidated
                  // element-wise per ConfigSchema.Field's documented
                  // elementSchema-nil convention.
                  "allowed_origins": ConfigSchema.Field(
                    type: .array,
                    description: "Fail-closed Origin allowlist for the ingest WebSocket."),
                ]
              ),
              description: "Browser-extension audio-ingest WebSocket."),
            // The loopback control-plane WebSocket — same shape and
            // fail-closed Origin allowlist as `ingest_ws`, distinct default
            // port. See `EarsIPC.ControlWebSocketServer`.
            "control_ws": ConfigSchema.Field(
              type: .table,
              children: ConfigSchema(
                fields: [
                  "enabled": ConfigSchema.Field(
                    type: .bool, description: "Enable the loopback control-plane WebSocket."),
                  "port": ConfigSchema.Field(
                    type: .int, description: "Loopback port the control WebSocket listens on."),
                  "allowed_origins": ConfigSchema.Field(
                    type: .array,
                    description: "Fail-closed Origin allowlist for the control WebSocket."),
                ]
              ),
              description: "Loopback control-plane WebSocket."),
            // Session lifecycle knobs: how long a browser session's last
            // ingest stream may stay closed before the daemon auto-ends the
            // session (`reason = "ingest-idle"`), and which locally-captured
            // sources (your own mic, system audio) the daemon folds into every
            // browser session so your side is transcribed alongside the
            // extension's per-participant streams. See `SessionRegistry`.
            // `local_sources` is a plain string array (elementSchema-nil
            // convention, like `ingest_ws.allowed_origins`).
            "sessions": ConfigSchema.Field(
              type: .table,
              children: ConfigSchema(
                fields: [
                  "ingest_close_grace_s": ConfigSchema.Field(
                    type: .int,
                    description:
                      "Grace period before a browser session's idle ingest stream auto-ends it, in seconds."
                  ),
                  "rejoin_hold_s": ConfigSchema.Field(
                    type: .int,
                    description:
                      "How long a browser-ended session waits before its pipeline runs, in seconds. "
                      + "A rejoin of the same meeting within it continues the session; 0 disables."
                  ),
                  "local_sources": ConfigSchema.Field(
                    type: .array,
                    description: "Local sources folded into every browser session (e.g. your mic)."),
                  "on_end_stages": ConfigSchema.Field(
                    type: .array,
                    description:
                      "Pipeline stages auto-run when a session ends, from transcribe|cleanup|summarize. "
                      + "cleanup/summarize require transcribe; [] disables the chain."),
                  "min_words": ConfigSchema.Field(
                    type: .int,
                    description:
                      "Word count below which a session's transcript is empty and the LLM stages are skipped; 0 disables."
                  ),
                  "min_speech_seconds": ConfigSchema.Field(
                    type: .double,
                    description:
                      "Detected speech below which a session's transcript is empty and the LLM stages are skipped; 0 disables."
                  ),
                ]
              ),
              description: "Session lifecycle knobs."),
            // Transcript-driven retention: evict a session's audio this many
            // seconds after its transcript completes successfully, or — for a
            // session whose transcript never completed — this many seconds
            // after it ended, whichever deadline comes first. Transcripts are
            // never evicted. See `EvictionSweeper`.
            "retention": ConfigSchema.Field(
              type: .table,
              children: ConfigSchema(
                fields: [
                  "evict_after_transcript_seconds": ConfigSchema.Field(
                    type: .int,
                    description:
                      "Evict a session's audio this many seconds after its transcript completes."
                  ),
                  "max_audio_age_seconds": ConfigSchema.Field(
                    type: .int,
                    description: "Hard cap on audio age before eviction, in seconds."),
                ]
              ),
              description: "Transcript-driven audio retention."),
            "source": ConfigSchema.Field(
              type: .array, elementSchema: sourceElementSchema,
              description: "Audio sources to capture (mic, system, app:*, device:*)."),
          ]
        ),
        description: "Capture daemon settings: audio format, VAD, sources, and networking.")
    ],
    passthroughKeys: [
      "schema",
      "transcribe",
      "diarize",
      "llm",
      "cleanup",
      "summarize",
      "vocab",
    ]
  )

  /// ``defaults`` merged with ``Phase0ConfigSchema/defaults``: the full set of
  /// built-in defaults an `earsd` caller needs, since `earsd` still reads
  /// `data_root`/`output_root`/`[log]` alongside its own `[earsd]` slice.
  public static let effectiveDefaults: ConfigValue = mergeConfigValues(
    base: Phase0ConfigSchema.defaults,
    overlay: defaults
  )

  /// ``schema`` composed with ``Phase0ConfigSchema/schema`` via
  /// ``ConfigSchema/union(_:)``: what `earsd` actually validates its merged
  /// config against.
  public static let effectiveSchema = Phase0ConfigSchema.schema.union(schema)
}
