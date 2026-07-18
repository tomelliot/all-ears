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
      "default_time_cap_seconds": .int(7200),
      "hard_total_cap_bytes": .int(0),
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
      "id": ConfigSchema.Field(type: .string),
      "class": ConfigSchema.Field(type: .string),
      "device_uid": ConfigSchema.Field(type: .string),
      "label": ConfigSchema.Field(type: .string),
      "time_cap_seconds": ConfigSchema.Field(type: .int),
      "enabled": ConfigSchema.Field(type: .bool),
    ]
  )

  public static let schema = ConfigSchema(
    fields: [
      "earsd": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "default_time_cap_seconds": ConfigSchema.Field(type: .int),
            "hard_total_cap_bytes": ConfigSchema.Field(type: .int),
            "chunk_seconds": ConfigSchema.Field(type: .int),
            "codec": ConfigSchema.Field(type: .string),
            "bitrate": ConfigSchema.Field(type: .int),
            "native_sample_rate": ConfigSchema.Field(type: .int),
            "asr_sample_rate": ConfigSchema.Field(type: .int),
            "store_native": ConfigSchema.Field(type: .bool),
            "channels": ConfigSchema.Field(type: .int),
            "vad": ConfigSchema.Field(
              type: .table,
              children: ConfigSchema(
                fields: [
                  "backend": ConfigSchema.Field(type: .string),
                  "speech_pad_ms": ConfigSchema.Field(type: .int),
                  "min_silence_ms": ConfigSchema.Field(type: .int),
                ]
              )
            ),
            "source": ConfigSchema.Field(type: .array, elementSchema: sourceElementSchema),
          ]
        )
      )
    ],
    passthroughKeys: [
      "schema",
      "transcribe",
      "llm",
      "cleanup",
      "summarize",
      "triggers",
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
