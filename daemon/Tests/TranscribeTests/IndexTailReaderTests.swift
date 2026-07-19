import EarsCore
import EarsDataStore
import Foundation
import Testing

@testable import transcribe

/// Covers ``IndexTailReader``'s byte-offset tailing: attach-at-EOF replay
/// semantics, incremental reads of only appended bytes, torn-line carry, and
/// malformed-line tolerance.
@Suite("IndexTailReader")
struct IndexTailReaderTests {
  private let base = Instant(secondsSinceEpoch: 1_784_284_200)

  private func makeIndexFile(_ label: String) -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "IndexTailReaderTests-\(label)-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("index.jsonl")
  }

  private func chunkEvent(startOffset: Double) -> IndexEvent {
    .chunk(
      start: base.advanced(by: startOffset), end: base.advanced(by: startOffset + 30),
      file: "asr/c\(Int(startOffset)).m4a", frames: 480_000)
  }

  @Test("attaching at end skips lines already on disk and reads only appended ones")
  func attachAtEndSkipsExisting() async throws {
    let fileURL = makeIndexFile("attach")
    let appender = IndexAppender(fileURL: fileURL)
    try await appender.append(chunkEvent(startOffset: 0))

    var tail = IndexTailReader(fileURL: fileURL, startAtEnd: true)
    #expect(tail.readNewEvents(onMalformed: { _ in }).isEmpty)

    try await appender.append(chunkEvent(startOffset: 30))
    let events = tail.readNewEvents(onMalformed: { _ in })
    #expect(events == [chunkEvent(startOffset: 30)])

    // Already consumed: a second read returns nothing new.
    #expect(tail.readNewEvents(onMalformed: { _ in }).isEmpty)
  }

  @Test("a missing index file reads as empty until it appears")
  func missingFileReadsEmpty() async throws {
    let fileURL = makeIndexFile("missing")
    var tail = IndexTailReader(fileURL: fileURL, startAtEnd: true)
    #expect(tail.readNewEvents(onMalformed: { _ in }).isEmpty)

    let appender = IndexAppender(fileURL: fileURL)
    try await appender.append(chunkEvent(startOffset: 0))
    #expect(tail.readNewEvents(onMalformed: { _ in }) == [chunkEvent(startOffset: 0)])
  }

  @Test("a torn trailing line is carried until its newline lands")
  func tornLineCarriedUntilComplete() throws {
    let fileURL = makeIndexFile("torn")
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    var tail = IndexTailReader(fileURL: fileURL, startAtEnd: true)

    let line = #"{"t":"evict","file":"asr/c0.m4a","start":"2026-07-17T10:30:00.000Z"}"#
    let handle = try FileHandle(forWritingTo: fileURL)
    defer { try? handle.close() }

    let splitIndex = line.count / 2
    try handle.write(contentsOf: Data(String(line.prefix(splitIndex)).utf8))
    #expect(tail.readNewEvents(onMalformed: { _ in }).isEmpty)

    try handle.write(contentsOf: Data((String(line.dropFirst(splitIndex)) + "\n").utf8))
    let events = tail.readNewEvents(onMalformed: { _ in })
    #expect(events.count == 1)
    guard case .evict(let file, _) = events.first else {
      Issue.record("expected the torn evict line to decode once completed")
      return
    }
    #expect(file == "asr/c0.m4a")
  }

  @Test("a malformed complete line is reported and skipped, not fatal")
  func malformedLineReportedAndSkipped() async throws {
    let fileURL = makeIndexFile("malformed")
    FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    var tail = IndexTailReader(fileURL: fileURL, startAtEnd: true)

    let handle = try FileHandle(forWritingTo: fileURL)
    try handle.write(contentsOf: Data("not json\n".utf8))
    try handle.close()
    let appender = IndexAppender(fileURL: fileURL)
    try await appender.append(chunkEvent(startOffset: 0))

    var malformed: [String] = []
    let events = tail.readNewEvents(onMalformed: { malformed.append($0) })
    #expect(events == [chunkEvent(startOffset: 0)])
    #expect(malformed == ["not json"])
  }
}
