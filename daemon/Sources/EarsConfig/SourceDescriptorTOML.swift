import EarsCore
import Foundation

/// Maps ``SourceDescriptor`` to and from the `ConfigValue` tree that mirrors
/// `meta.toml` (see `docs/data-formats.md`'s `meta.toml` schema). Reuses
/// `TOMLBridge`'s `ConfigValue` machinery for the actual TOML text; this file
/// only knows the field-by-field shape and the one field-specific detail
/// `meta.toml` needs beyond a plain scalar mapping: ``created`` renders with
/// hyphens instead of colons in its time portion (`2026-07-17T10-30-00Z`),
/// matching the filename-safe timestamp convention chunk files use, rather
/// than the standard colon-separated ISO-8601 `session.toml`'s `start`/`end`
/// use (see ``SessionDescriptorTOML``).
public enum SourceDescriptorTOML {
  /// Encodes a ``SourceDescriptor`` into the `ConfigValue` table `meta.toml`
  /// serializes to.
  public static func encode(_ descriptor: SourceDescriptor) -> ConfigValue {
    .table([
      "schema": .int(descriptor.schema),
      "id": .string(descriptor.id.rawValue),
      "class": .string(descriptor.sourceClass.rawValue),
      "label": .string(descriptor.label),
      "device_uid": .string(descriptor.deviceUID),
      "native_sample_rate": .int(descriptor.nativeSampleRate),
      "asr_sample_rate": .int(descriptor.asrSampleRate),
      "store_native": .bool(descriptor.storeNative),
      "channels": .int(descriptor.channels),
      "codec": .string(descriptor.codec),
      "bitrate": .int(descriptor.bitrate),
      "created": .string(formatCreated(descriptor.created)),
    ])
  }

  /// Decodes a ``SourceDescriptor`` from a `ConfigValue` table parsed from
  /// `meta.toml`. Throws ``DescriptorTOMLError`` when a key is missing, has
  /// the wrong kind, or doesn't parse into the target type.
  public static func decode(_ value: ConfigValue) throws(DescriptorTOMLError) -> SourceDescriptor {
    guard case .table(let table) = value else {
      throw .notATable
    }
    let fields = TOMLFieldReader(table: table)

    let classRaw = try fields.string("class")
    guard let sourceClass = SourceClass(rawValue: classRaw) else {
      throw .invalidField("class")
    }

    let createdRaw = try fields.string("created")
    guard let created = parseCreated(createdRaw) else {
      throw .invalidField("created")
    }

    return SourceDescriptor(
      schema: try fields.int("schema"),
      id: SourceID(try fields.string("id")),
      sourceClass: sourceClass,
      label: try fields.string("label"),
      deviceUID: try fields.string("device_uid"),
      nativeSampleRate: try fields.int("native_sample_rate"),
      asrSampleRate: try fields.int("asr_sample_rate"),
      storeNative: try fields.bool("store_native"),
      channels: try fields.int("channels"),
      codec: try fields.string("codec"),
      bitrate: try fields.int("bitrate"),
      created: created
    )
  }

  /// Renders `instant` as `meta.toml`'s `created` field: ISO-8601 UTC with
  /// the time portion's colons replaced by hyphens
  /// (`2026-07-17T10-30-00Z`) -- the date portion already uses hyphens, so a
  /// global replace is safe in this direction.
  private static func formatCreated(_ instant: Instant) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let iso = formatter.string(from: Date(timeIntervalSince1970: instant.secondsSinceEpoch))
    return iso.replacingOccurrences(of: ":", with: "-")
  }

  /// Parses `meta.toml`'s hyphenated `created` field back to an ``Instant``.
  /// Only the portion after `T` has its hyphens converted back to colons --
  /// the date portion's hyphens are part of standard ISO-8601 and must stay.
  private static func parseCreated(_ string: String) -> Instant? {
    guard let tIndex = string.firstIndex(of: "T") else { return nil }
    let datePart = string[string.startIndex..<tIndex]
    let timePart = string[string.index(after: tIndex)...].replacingOccurrences(of: "-", with: ":")
    let isoString = "\(datePart)T\(timePart)"

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: isoString) else { return nil }
    return Instant(secondsSinceEpoch: date.timeIntervalSince1970)
  }
}
