/// The stable identifier of an audio source, e.g. `mic`, `system`,
/// `app:us.zoom.xos`, `browser:meet`, `device:<uid>`.
///
/// The identifier has two forms (see `docs/data-formats.md`):
/// - ``rawValue`` — the natural form, used on the control socket and in metadata.
/// - ``pathSafe`` — the same id with path-unsafe characters replaced by `_`,
///   used as the on-disk directory name under `sources/`.
///
/// `SourceID` wraps a string rather than modelling the class inline so that new
/// source shapes need no code change; ``sourceClass`` derives the class from the
/// id's prefix as a convenience.
public struct SourceID: RawRepresentable, Sendable, Hashable, Comparable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  /// The id with characters unsafe in a path component replaced by `_`.
  ///
  /// Safe characters are ASCII alphanumerics plus `.`, `-`, and `_`; everything
  /// else (notably the `:` separating a class from its detail, and any path
  /// separator) becomes `_`. So `app:us.zoom.xos` → `app_us.zoom.xos`.
  public var pathSafe: String {
    String(
      rawValue.map { character in
        switch character {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "-", "_": character
        default: "_"
        }
      }
    )
  }

  /// The source class inferred from the id's prefix, or `nil` if the prefix is
  /// not a recognised class. `mic` and `system` have no `:` detail; the rest
  /// are `<class>:<detail>`.
  public var sourceClass: SourceClass? {
    let prefix = rawValue.prefix { $0 != ":" }
    return SourceClass(rawValue: String(prefix))
  }

  /// The part after the first `:`, e.g. `"app:us.zoom.xos".detail ==
  /// "us.zoom.xos"` — the bundle id for an `.app` source, the label for a
  /// `.browser` source, the UID for a `.device` source. `nil` for an id with
  /// no `:` (`mic`, `system`) or an empty detail (`"app:"`).
  public var detail: String? {
    guard let colonIndex = rawValue.firstIndex(of: ":") else { return nil }
    let value = rawValue[rawValue.index(after: colonIndex)...]
    return value.isEmpty ? nil : String(value)
  }

  public static func < (lhs: SourceID, rhs: SourceID) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

extension SourceID: ExpressibleByStringLiteral {
  public init(stringLiteral value: String) {
    self.init(value)
  }
}

extension SourceID: Codable {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(try container.decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}
