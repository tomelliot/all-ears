import EarsCore
import Foundation

/// Maps ``MeetingDescriptor`` to and from the `ConfigValue` tree that mirrors
/// `meeting.toml` (`<data-root>/meetings/<uuid>/meeting.toml`). Mirrors
/// ``SessionDescriptorTOML``'s shape exactly: `TOMLBridge`'s `ConfigValue`
/// machinery does the actual TOML text, this file only knows the fields.
///
/// `created` renders as standard colon-separated ISO-8601
/// (`2026-07-17T10:30:00Z`) — it isn't a filename, so no hyphenation, same as
/// `session.toml`'s timestamps.
public enum MeetingDescriptorTOML {
  /// Encodes a ``MeetingDescriptor`` into the `ConfigValue` table
  /// `meeting.toml` serializes to.
  public static func encode(_ descriptor: MeetingDescriptor) -> ConfigValue {
    .table([
      "schema": .int(descriptor.schema),
      "id": .string(descriptor.id),
      "platform": .string(descriptor.platform),
      "external_id": .string(descriptor.externalID),
      "created": .string(formatInstant(descriptor.created)),
    ])
  }

  /// Decodes a ``MeetingDescriptor`` from a `ConfigValue` table parsed from
  /// `meeting.toml`. Throws ``DescriptorTOMLError`` when a key is missing,
  /// has the wrong kind, or doesn't parse into the target type.
  public static func decode(
    _ value: ConfigValue
  ) throws(DescriptorTOMLError) -> MeetingDescriptor {
    guard case .table(let table) = value else {
      throw .notATable
    }
    let fields = TOMLFieldReader(table: table)

    guard let created = parseInstant(try fields.string("created")) else {
      throw .invalidField("created")
    }

    return MeetingDescriptor(
      schema: try fields.int("schema"),
      id: try fields.string("id"),
      platform: try fields.string("platform"),
      externalID: try fields.string("external_id"),
      created: created
    )
  }

  /// Standard colon-separated ISO-8601 UTC, whole seconds.
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
