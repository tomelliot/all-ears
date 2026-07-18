import EarsCore
import Foundation

/// Maps ``SessionDescriptor`` to and from the `ConfigValue` tree that mirrors
/// `session.toml` (see `docs/data-formats.md`'s `session.toml` schema). Reuses
/// `TOMLBridge`'s `ConfigValue` machinery for the actual TOML text; this file
/// only knows the field-by-field shape.
///
/// ``SessionDescriptor/start``/``SessionDescriptor/end`` render as standard
/// colon-separated ISO-8601 (`2026-07-17T10:30:00Z`) -- unlike
/// ``SourceDescriptor``'s `created`, `session.toml`'s timestamps aren't
/// filenames, so there's no reason to hyphenate them (see
/// ``SourceDescriptorTOML``).
///
/// `end`, `trigger_detail`, and `vocab` are optional in the model. They're
/// still always written as a key -- an empty string when `nil` -- so the file
/// always has the same shape; decoding treats an empty string the same as an
/// absent key, both becoming `nil` (the "empty => absent" sentinel convention
/// this codebase already uses for `socket_path`/`log.file`).
public enum SessionDescriptorTOML {
  /// Encodes a ``SessionDescriptor`` into the `ConfigValue` table
  /// `session.toml` serializes to.
  public static func encode(_ descriptor: SessionDescriptor) -> ConfigValue {
    .table([
      "schema": .int(descriptor.schema),
      "id": .string(descriptor.id),
      "slug": .string(descriptor.slug),
      "sources": .array(descriptor.sources.map { .string($0.rawValue) }),
      "start": .string(formatInstant(descriptor.start)),
      "end": .string(descriptor.end.map(formatInstant) ?? ""),
      "state": .string(descriptor.state.rawValue),
      "trigger": .string(descriptor.trigger.rawValue),
      "trigger_detail": .string(descriptor.triggerDetail ?? ""),
      "vocab": .string(descriptor.vocab ?? ""),
    ])
  }

  /// Decodes a ``SessionDescriptor`` from a `ConfigValue` table parsed from
  /// `session.toml`. Throws ``DescriptorTOMLError`` when a key is missing,
  /// has the wrong kind, or doesn't parse into the target type.
  public static func decode(
    _ value: ConfigValue
  ) throws(DescriptorTOMLError) -> SessionDescriptor {
    guard case .table(let table) = value else {
      throw .notATable
    }
    let fields = TOMLFieldReader(table: table)

    let sourcesArray = try fields.array("sources")
    var sources: [SourceID] = []
    for element in sourcesArray {
      guard case .string(let raw) = element else {
        throw .invalidField("sources")
      }
      sources.append(SourceID(raw))
    }

    guard let start = parseInstant(try fields.string("start")) else {
      throw .invalidField("start")
    }

    let endRaw = fields.optionalString("end")
    let end: Instant?
    if let endRaw {
      guard let parsedEnd = parseInstant(endRaw) else {
        throw .invalidField("end")
      }
      end = parsedEnd
    } else {
      end = nil
    }

    guard let state = SessionState(rawValue: try fields.string("state")) else {
      throw .invalidField("state")
    }
    guard let trigger = TriggerKind(rawValue: try fields.string("trigger")) else {
      throw .invalidField("trigger")
    }

    return SessionDescriptor(
      schema: try fields.int("schema"),
      id: try fields.string("id"),
      slug: try fields.string("slug"),
      sources: sources,
      start: start,
      end: end,
      state: state,
      trigger: trigger,
      triggerDetail: fields.optionalString("trigger_detail"),
      vocab: fields.optionalString("vocab")
    )
  }

  /// Standard colon-separated ISO-8601 UTC, whole seconds, e.g.
  /// `2026-07-17T10:30:00Z`.
  private static func formatInstant(_ instant: Instant) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date(timeIntervalSince1970: instant.secondsSinceEpoch))
  }

  private static func parseInstant(_ string: String) -> Instant? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: string) else { return nil }
    return Instant(secondsSinceEpoch: date.timeIntervalSince1970)
  }
}
