/// Built-in defaults and declared schema for the config keys Phase 0 needs:
/// the shared paths (`data_root`, `output_root`, `socket_path`) and the `[log]`
/// table. Values match the reference config in `docs/configuration.md` exactly.
///
/// Every other top-level table in that reference config — `[earsd]`,
/// `[transcribe]`, `[llm]`, `[cleanup]`, `[[summarize.preset]]`, `[triggers]`,
/// `[vocab]`, `[[earsd.source]]` — plus the top-level `schema` version key, is
/// deliberately out of scope: later phases declare their own ``ConfigSchema``
/// slice when they implement that subsystem. Until then, ``validateConfig(_:against:)``
/// passes those keys through the merged tree untouched rather than rejecting
/// them as unknown.
public enum Phase0ConfigSchema {
  public static let defaults: ConfigValue = .table([
    "data_root": .string("~/Library/Application Support/ears"),
    "output_root": .string("~/Documents/Transcripts"),
    "socket_path": .string(""),
    "log": .table([
      "level": .string("info"),
      "file": .string(""),
      "format": .string("auto"),
      "oslog": .bool(true),
      "subsystem": .string("net.tomelliot.ears"),
      "rotate_max_bytes": .int(52_428_800),
      "rotate_max_files": .int(5),
    ]),
  ])

  public static let schema = ConfigSchema(
    fields: [
      "data_root": ConfigSchema.Field(type: .string),
      "output_root": ConfigSchema.Field(type: .string),
      "socket_path": ConfigSchema.Field(type: .string),
      "log": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "level": ConfigSchema.Field(type: .string),
            "file": ConfigSchema.Field(type: .string),
            "format": ConfigSchema.Field(type: .string),
            "oslog": ConfigSchema.Field(type: .bool),
            "subsystem": ConfigSchema.Field(type: .string),
            "rotate_max_bytes": ConfigSchema.Field(type: .int),
            "rotate_max_files": ConfigSchema.Field(type: .int),
          ]
        )
      ),
    ],
    passthroughKeys: [
      "schema",
      "earsd",
      "transcribe",
      "llm",
      "cleanup",
      "summarize",
      "triggers",
      "vocab",
    ]
  )
}
