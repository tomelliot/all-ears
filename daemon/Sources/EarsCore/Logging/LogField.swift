/// One ordered key/value pair in a ``LogRecord``'s context bag.
///
/// A named struct rather than a bare `(String, LogValue)` tuple so it can
/// conform to `Equatable`/`Hashable` (Swift tuples cannot conform to
/// protocols), which in turn lets ``LogRecord`` synthesize its own
/// `Equatable` conformance for tests.
public struct LogField: Sendable, Hashable {
  public var key: String
  public var value: LogValue

  public init(_ key: String, _ value: LogValue) {
    self.key = key
    self.value = value
  }
}
