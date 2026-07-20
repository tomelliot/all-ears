import EarsCore

/// Resolves `transcribe`'s range flags (`--last`, `--from`/`--to`,
/// `--session`, per `docs/specs/transcribe.md`'s CLI) into a wall-clock
/// ``TimeRange`` -- and, for `--session`, the session's own recorded sources,
/// vocab, and real session id.
///
/// Pure and clock-injected -- no wall-clock read here -- per
/// `docs/engineering-practices.md`'s "no wall-clock time in tests" rule;
/// ``TranscribeRuntime``/``TranscribePipeline`` supply the real `now` via
/// `NowProviding`, tests supply a fixed ``Instant`` directly. `--session`'s
/// session lookup is likewise injected (`sessionReader`) rather than reading
/// `EarsDataStore.SessionStore` here directly, so this stays a pure function;
/// ``TranscribePipeline`` wraps the real, on-disk `SessionStore.read` call.
enum TranscribeRangeResolution {
  enum RangeError: Error, Equatable, CustomStringConvertible {
    /// Neither `--last`, `--from`/`--to`, nor `--session` was given.
    case noRangeSpecified
    /// More than one of `--last` / `--from`+`--to` / `--session` was given.
    case multipleRangeSourcesSpecified
    /// Only one of `--from`/`--to` was given; both are required together.
    case incompleteFromTo
    /// `--from`/`--to`'s value didn't parse as an ISO-8601 UTC timestamp.
    case invalidTimestamp(field: String, value: String)
    /// `--last`'s value didn't parse as a duration.
    case invalidDuration(String)
    /// The resolved range has zero or negative length.
    case emptyRange
    /// `--session`'s id named a session `SessionStore` doesn't know.
    case unknownSession(String)

    var description: String {
      switch self {
      case .noRangeSpecified:
        return "no range specified: pass --last <duration>, --from/--to, or --session <id>"
      case .multipleRangeSourcesSpecified:
        return "specify only one of --last, --from/--to, or --session"
      case .incompleteFromTo:
        return "--from and --to must both be given together"
      case .invalidTimestamp(let field, let value):
        return "--\(field) is not a valid ISO-8601 UTC timestamp: '\(value)'"
      case .invalidDuration(let detail):
        return detail
      case .emptyRange:
        return "requested range is empty"
      case .unknownSession(let id):
        return "unknown session '\(id)'"
      }
    }
  }

  /// The resolved range, plus whatever else `--session` recovers from the
  /// session descriptor.
  struct Resolved: Equatable {
    var range: TimeRange
    /// Non-`nil` only when resolved via `--session`: overrides any
    /// `--source` flags with the session's own recorded sources.
    var sourceIDs: [SourceID]?
    /// Non-`nil` only when resolved via `--session` and the session
    /// recorded a vocab path.
    var vocab: String?
    /// Non-`nil` only when resolved via `--session`: the session's real id,
    /// for ``OutputPathResolution`` to use in place of a synthesized one.
    var sessionIdentifier: String?
    /// Non-`nil` only when resolved via `--session`: the session's `slug`,
    /// for ``OutputPathResolution``'s output filename.
    var sessionSlug: String?

    init(
      range: TimeRange, sourceIDs: [SourceID]? = nil, vocab: String? = nil,
      sessionIdentifier: String? = nil, sessionSlug: String? = nil
    ) {
      self.range = range
      self.sourceIDs = sourceIDs
      self.vocab = vocab
      self.sessionIdentifier = sessionIdentifier
      self.sessionSlug = sessionSlug
    }
  }

  static func resolve(
    last: String?,
    from: String?,
    to: String?,
    session: String?,
    now: Instant,
    sessionReader: (String) -> Result<SessionDescriptor, RangeError>
  ) -> Result<Resolved, RangeError> {
    let specifiedCount = [last != nil, from != nil || to != nil, session != nil]
      .filter { $0 }.count
    guard specifiedCount <= 1 else { return .failure(.multipleRangeSourcesSpecified) }

    if let session {
      return resolveSession(session, now: now, sessionReader: sessionReader)
    }
    if from != nil || to != nil {
      return resolveFromTo(from: from, to: to)
    }
    return resolveLast(last, now: now)
  }

  /// A still-open session (`end == nil`) resolves to `[start, now)` --
  /// `transcribe --session` on an in-progress session is a legitimate "give
  /// me what's there so far" use, matching `--last`'s own "ending now"
  /// semantics, rather than an error.
  ///
  /// The resolved range's start is widened backward by
  /// `descriptor.preRollSeconds` -- a read-time-only concern (see
  /// ``SessionDescriptor/preRollSeconds``'s doc comment); `descriptor.start`
  /// itself, and what gets persisted, are never touched. Widening can only
  /// lengthen the range (moving `start` earlier), so it never invalidates
  /// the `start < end` check below.
  private static func resolveSession(
    _ id: String, now: Instant, sessionReader: (String) -> Result<SessionDescriptor, RangeError>
  ) -> Result<Resolved, RangeError> {
    switch sessionReader(id) {
    case .failure(let error): return .failure(error)
    case .success(let descriptor):
      let end = descriptor.end ?? now
      guard descriptor.start < end else { return .failure(.emptyRange) }
      let widenedStart = descriptor.start.advanced(by: -Double(descriptor.preRollSeconds))
      return .success(
        Resolved(
          range: TimeRange(start: widenedStart, end: end),
          sourceIDs: descriptor.sources,
          vocab: descriptor.vocab,
          sessionIdentifier: descriptor.id,
          sessionSlug: descriptor.slug))
    }
  }

  private static func resolveFromTo(from: String?, to: String?) -> Result<Resolved, RangeError> {
    guard let from, let to else { return .failure(.incompleteFromTo) }
    guard let start = ISO8601InstantCodec.parse(from) else {
      return .failure(.invalidTimestamp(field: "from", value: from))
    }
    guard let end = ISO8601InstantCodec.parse(to) else {
      return .failure(.invalidTimestamp(field: "to", value: to))
    }
    guard start < end else { return .failure(.emptyRange) }
    return .success(Resolved(range: TimeRange(start: start, end: end)))
  }

  private static func resolveLast(_ last: String?, now: Instant) -> Result<Resolved, RangeError> {
    guard let last else { return .failure(.noRangeSpecified) }
    switch DurationParsing.seconds(from: last) {
    case .failure(let parseError):
      return .failure(.invalidDuration(parseError.description))
    case .success(let seconds):
      guard seconds > 0 else { return .failure(.emptyRange) }
      return .success(Resolved(range: TimeRange(start: now.advanced(by: -seconds), end: now)))
    }
  }
}
