#if canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

/// Abstracts "is stderr attached to a terminal" so ``LogSink``'s sink-format
/// selection logic is unit-testable against a fixed answer, leaving only the
/// real `isatty` syscall (``RealTTYDetector``) as untested environment glue.
public protocol TTYDetecting: Sendable {
  var isStderrATTY: Bool { get }
}

/// The production ``TTYDetecting`` conformance: asks the real process
/// environment via `isatty(STDERR_FILENO)`.
public struct RealTTYDetector: TTYDetecting {
  public init() {}

  public var isStderrATTY: Bool {
    isatty(STDERR_FILENO) != 0
  }
}
