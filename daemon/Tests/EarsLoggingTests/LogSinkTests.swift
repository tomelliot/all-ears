import EarsCore
import Foundation
import Testing

@testable import EarsLogging

private struct FixedClock: NowProviding {
  let instant: Instant
  func now() -> Instant { instant }
}

private struct FixedTTYDetector: TTYDetecting {
  let isStderrATTY: Bool
}

private final class RecordingStderrWriter: StderrWriting, @unchecked Sendable {
  private(set) var lines: [String] = []
  func writeLine(_ line: String) {
    lines.append(line)
  }
}

@Suite("LogSink")
struct LogSinkTests {
  private func tempFileWriter(
    rotateMaxBytes: Int = 1_000_000,
    rotateMaxFiles: Int = 3
  ) throws -> (FileLogWriter, URL) {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("LogSinkTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("earsd.jsonl")
    let writer = try FileLogWriter(
      url: url,
      rotation: .init(rotateMaxBytes: rotateMaxBytes, rotateMaxFiles: rotateMaxFiles),
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 4120,
      clock: FixedClock(instant: Instant(secondsSinceEpoch: 0))
    )
    return (writer, url)
  }

  private func record(_ event: String) -> LogRecord {
    LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .info,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 4120,
      event: event
    )
  }

  @Test("on a TTY, stderr gets the pretty rendering and the file gets JSON")
  func ttyWritesPretty() async throws {
    let (writer, url) = try tempFileWriter()
    let stderr = RecordingStderrWriter()
    let unified = RecordingUnifiedLogging()
    let sink = LogSink(
      file: writer,
      stderr: stderr,
      unified: unified,
      tty: FixedTTYDetector(isStderrATTY: true)
    )
    let event = record("source.opened")
    try await sink.log(event)

    #expect(stderr.lines == [LogRecordPrettyRenderer.render(event)])
    let fileContents = try String(contentsOf: url, encoding: .utf8)
    #expect(fileContents == LogRecordJSONEncoder.encode(event) + "\n")
  }

  @Test("off a TTY, stderr and the file both get full JSON")
  func nonTTYWritesJSONToBoth() async throws {
    let (writer, url) = try tempFileWriter()
    let stderr = RecordingStderrWriter()
    let unified = RecordingUnifiedLogging()
    let sink = LogSink(
      file: writer,
      stderr: stderr,
      unified: unified,
      tty: FixedTTYDetector(isStderrATTY: false)
    )
    let event = record("chunk.written")
    try await sink.log(event)

    #expect(stderr.lines == [LogRecordJSONEncoder.encode(event)])
    let fileContents = try String(contentsOf: url, encoding: .utf8)
    #expect(fileContents == LogRecordJSONEncoder.encode(event) + "\n")
  }

  @Test("always forwards to the unified-logging mirror")
  func alwaysMirrorsToUnifiedLogging() async throws {
    let (writer, _) = try tempFileWriter()
    let stderr = RecordingStderrWriter()
    let unified = RecordingUnifiedLogging()
    let sink = LogSink(
      file: writer,
      stderr: stderr,
      unified: unified,
      tty: FixedTTYDetector(isStderrATTY: true)
    )
    let event = record("session.closed")
    try await sink.log(event)

    #expect(unified.recorded == [event])
  }

  @Test("propagates file write failures instead of swallowing them")
  func propagatesFileErrors() async throws {
    let (writer, url) = try tempFileWriter()
    // Knock out the file after a successful init, so append()'s
    // FileHandle(forWritingTo:) fails on the next call: replace it with a
    // directory of the same name.
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

    let sink = LogSink(
      file: writer,
      stderr: RecordingStderrWriter(),
      unified: RecordingUnifiedLogging(),
      tty: FixedTTYDetector(isStderrATTY: true)
    )

    await #expect(throws: (any Error).self) {
      try await sink.log(record("chunk.written"))
    }
  }
}
