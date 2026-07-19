/// Built-in defaults and declared schema for the LLM-stage config slices
/// `docs/configuration.md` documents: `[llm]` (the shared backend `cleanup`/
/// `summarize` both use), `[cleanup]`, `[[summarize.preset]]`, and `[vocab]`
/// (the global vocabulary list `cleanup` merges in as a correction backstop).
/// Values match the reference config exactly.
///
/// Like ``EarsdConfigSchema``, this schema only declares its own slices; the
/// shared keys every tool needs (`data_root`, `output_root`, `[log]`, ...)
/// are ``Phase0ConfigSchema``'s concern. ``effectiveSchema``/
/// ``effectiveDefaults`` compose the two via ``ConfigSchema/union(_:)`` into
/// what `cleanup`/`summarize` actually validate against.
public enum LLMStagesConfigSchema {
  public static let defaults: ConfigValue = .table([
    "llm": .table([
      // "llm-cli" | "command"; see docs/configuration.md's [llm] table.
      "backend": .string("llm-cli"),
      "model": .string(""),
      // Only consulted when backend == "command": a full shell command
      // template taking the prompt on stdin, completion on stdout.
      "command": .string(""),
    ]),
    "cleanup": .table([
      // Empty => the built-in cleanup prompt (CleanupPromptBuilder's default).
      "prompt_file": .string(""),
      "use_vocab": .bool(true),
    ]),
    "summarize": .table([
      "preset": .array([])
    ]),
    "vocab": .table([
      // Relative to data_root; empty => no global vocabulary list.
      "global": .string("")
    ]),
  ])

  /// Schema for a single `[[summarize.preset]]` element.
  private static let presetElementSchema = ConfigSchema(
    fields: [
      "name": ConfigSchema.Field(type: .string),
      "prompt_file": ConfigSchema.Field(type: .string),
    ]
  )

  public static let schema = ConfigSchema(
    fields: [
      "llm": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "backend": ConfigSchema.Field(type: .string),
            "model": ConfigSchema.Field(type: .string),
            "command": ConfigSchema.Field(type: .string),
          ]
        )
      ),
      "cleanup": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "prompt_file": ConfigSchema.Field(type: .string),
            "use_vocab": ConfigSchema.Field(type: .bool),
          ]
        )
      ),
      "summarize": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "preset": ConfigSchema.Field(type: .array, elementSchema: presetElementSchema)
          ]
        )
      ),
      "vocab": ConfigSchema.Field(
        type: .table,
        children: ConfigSchema(
          fields: [
            "global": ConfigSchema.Field(type: .string)
          ]
        )
      ),
    ]
  )

  /// ``defaults`` merged with ``Phase0ConfigSchema/defaults``: the full set of
  /// built-in defaults a `cleanup`/`summarize` caller needs.
  public static let effectiveDefaults: ConfigValue = mergeConfigValues(
    base: Phase0ConfigSchema.defaults,
    overlay: defaults
  )

  /// ``schema`` composed with ``Phase0ConfigSchema/schema`` via
  /// ``ConfigSchema/union(_:)``: what `cleanup`/`summarize` actually validate
  /// their merged config against.
  public static let effectiveSchema = Phase0ConfigSchema.schema.union(schema)
}
