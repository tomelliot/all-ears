import Foundation

/// Abstracts writing one line to stderr, so the TTY-vs-pipe branching logic
/// in ``LogSink`` is unit-testable against a fake and only the real write
/// syscall (``RealStderrWriter``) is untested glue.
public protocol StderrWriting: Sendable {
  /// Writes `line` followed by a newline.
  func writeLine(_ line: String)
}

/// The production ``StderrWriting`` conformance: writes to the process's
/// real standard error.
public struct RealStderrWriter: StderrWriting {
  public init() {}

  public func writeLine(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }
}
