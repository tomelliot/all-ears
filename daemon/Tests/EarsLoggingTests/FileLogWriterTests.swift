import EarsCore
import Foundation
import Testing

@testable import EarsLogging

private struct FixedClock: NowProviding {
  let instant: Instant
  func now() -> Instant { instant }
}

@Suite("FileLogWriter")
struct FileLogWriterTests {
  private func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("FileLogWriterTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func record(_ event: String, fields: [LogField] = []) -> LogRecord {
    LogRecord(
      ts: Instant(secondsSinceEpoch: 0),
      level: .info,
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 4120,
      event: event,
      fields: fields
    )
  }

  private func lines(of url: URL) throws -> [String] {
    let contents = try String(contentsOf: url, encoding: .utf8)
    return contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
  }

  @Test("creates the file and appends one JSON line per record")
  func createsAndAppends() async throws {
    let dir = try tempDirectory()
    let url = dir.appendingPathComponent("earsd.jsonl")
    let writer = try FileLogWriter(
      url: url,
      rotation: .init(rotateMaxBytes: 1_000_000, rotateMaxFiles: 3),
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 4120,
      clock: FixedClock(instant: Instant(secondsSinceEpoch: 0))
    )
    try await writer.append(record("source.opened"))
    try await writer.append(record("chunk.written"))

    let written = try lines(of: url)
    #expect(written.count == 2)
    #expect(written[0].contains("\"event\":\"source.opened\""))
    #expect(written[1].contains("\"event\":\"chunk.written\""))
  }

  @Test("rotates before a record would push the file past rotateMaxBytes")
  func rotatesBySize() async throws {
    let dir = try tempDirectory()
    let url = dir.appendingPathComponent("earsd.jsonl")
    let first = record("source.opened")
    let firstLineBytes = (LogRecordJSONEncoder.encode(first) + "\n").utf8.count

    let writer = try FileLogWriter(
      url: url,
      // Big enough for one record, too small for two.
      rotation: .init(rotateMaxBytes: firstLineBytes + 1, rotateMaxFiles: 3),
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 4120,
      clock: FixedClock(instant: Instant(secondsSinceEpoch: 1_000))
    )
    try await writer.append(first)
    try await writer.append(record("chunk.written"))

    let rotatedPath = url.path + ".1"
    #expect(FileManager.default.fileExists(atPath: rotatedPath))
    let rotatedLines = try lines(of: URL(fileURLWithPath: rotatedPath))
    #expect(rotatedLines == [LogRecordJSONEncoder.encode(first)])

    let currentLines = try lines(of: url)
    #expect(currentLines.count == 2)
    #expect(currentLines[0].contains("\"event\":\"log.rotated\""))
    #expect(currentLines[1].contains("\"event\":\"chunk.written\""))
  }

  @Test("the log.rotated record carries the writer's identity and the clock's time")
  func rotatedRecordShape() async throws {
    let dir = try tempDirectory()
    let url = dir.appendingPathComponent("earsd.jsonl")
    let first = record("source.opened")
    let firstLineBytes = (LogRecordJSONEncoder.encode(first) + "\n").utf8.count

    let writer = try FileLogWriter(
      url: url,
      rotation: .init(rotateMaxBytes: firstLineBytes + 1, rotateMaxFiles: 3),
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 4120,
      clock: FixedClock(instant: Instant(secondsSinceEpoch: 555))
    )
    try await writer.append(first)
    try await writer.append(record("chunk.written"))

    let currentLines = try lines(of: url)
    let rotatedLine = currentLines[0]
    #expect(rotatedLine.contains("\"tool\":\"earsd\""))
    #expect(rotatedLine.contains("\"category\":\"earsd\""))
    #expect(rotatedLine.contains("\"pid\":4120"))
    #expect(rotatedLine.contains("\"ts\":\"1970-01-01T00:09:15.000Z\""))
  }

  @Test("prunes the oldest rotation once rotateMaxFiles is exceeded")
  func prunesOldest() async throws {
    let dir = try tempDirectory()
    let url = dir.appendingPathComponent("earsd.jsonl")
    let sample = record("chunk.written")
    let lineBytes = (LogRecordJSONEncoder.encode(sample) + "\n").utf8.count

    let writer = try FileLogWriter(
      url: url,
      // Rotate on every single append; keep at most 3 files total (current + 2 backups).
      rotation: .init(rotateMaxBytes: lineBytes, rotateMaxFiles: 3),
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      clock: FixedClock(instant: Instant(secondsSinceEpoch: 0))
    )
    for _ in 0..<5 {
      try await writer.append(sample)
    }

    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(FileManager.default.fileExists(atPath: url.path + ".1"))
    #expect(FileManager.default.fileExists(atPath: url.path + ".2"))
    #expect(!FileManager.default.fileExists(atPath: url.path + ".3"))
  }

  @Test("rotateMaxFiles of 1 truncates in place without a .1 backup")
  func noBackupsWhenMaxFilesIsOne() async throws {
    let dir = try tempDirectory()
    let url = dir.appendingPathComponent("earsd.jsonl")
    let first = record("source.opened")
    let firstLineBytes = (LogRecordJSONEncoder.encode(first) + "\n").utf8.count

    let writer = try FileLogWriter(
      url: url,
      rotation: .init(rotateMaxBytes: firstLineBytes + 1, rotateMaxFiles: 1),
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      clock: FixedClock(instant: Instant(secondsSinceEpoch: 0))
    )
    try await writer.append(first)
    try await writer.append(record("chunk.written"))

    #expect(!FileManager.default.fileExists(atPath: url.path + ".1"))
    let currentLines = try lines(of: url)
    #expect(currentLines.count == 2)
    #expect(currentLines[0].contains("\"event\":\"log.rotated\""))
  }

  @Test("resumes size accounting from an existing file on disk")
  func resumesFromExistingFile() async throws {
    let dir = try tempDirectory()
    let url = dir.appendingPathComponent("earsd.jsonl")
    let existingLine = LogRecordJSONEncoder.encode(record("earlier.event")) + "\n"
    try existingLine.write(to: url, atomically: true, encoding: .utf8)

    let next = record("chunk.written")
    let nextLineBytes = (LogRecordJSONEncoder.encode(next) + "\n").utf8.count
    let existingBytes = existingLine.utf8.count

    let writer = try FileLogWriter(
      url: url,
      // Room for the existing content but not for the existing content plus next.
      rotation: .init(rotateMaxBytes: existingBytes + nextLineBytes - 1, rotateMaxFiles: 3),
      tool: "earsd",
      subsystem: "net.tomelliot.ears",
      category: "earsd",
      pid: 1,
      clock: FixedClock(instant: Instant(secondsSinceEpoch: 0))
    )
    try await writer.append(next)

    #expect(FileManager.default.fileExists(atPath: url.path + ".1"))
    let rotatedLines = try lines(of: URL(fileURLWithPath: url.path + ".1"))
    #expect(rotatedLines == [String(existingLine.dropLast())])
  }
}
