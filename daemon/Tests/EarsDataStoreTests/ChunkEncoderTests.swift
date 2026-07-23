import EarsCore
import EarsCoreTestSupport
import EarsLogging
import Foundation
import Synchronization
import Testing

@testable import EarsDataStore

/// A ``ChunkFileWriting`` fake that writes raw `Float32` bytes directly
/// (no real codec), optionally throwing on a specific call number. Used to
/// exercise ``ChunkEncoder``'s keep-partial-on-encode-failure path
/// deterministically, without needing to force a real `AVAudioFile` codec
/// failure -- the protocol seam this module builds specifically for that
/// purpose.
private final class RecordingOrFailingWriter: ChunkFileWriting, @unchecked Sendable {
  private let url: URL
  private let failOnCall: Int?
  private var callCount = 0
  private(set) var writtenSampleCounts: [Int] = []

  init(url: URL, failOnCall: Int?) {
    self.url = url
    self.failOnCall = failOnCall
    FileManager.default.createFile(atPath: url.path, contents: Data())
  }

  enum InjectedError: Error {
    case encodeFailed
  }

  func write(samples: [Float]) throws {
    callCount += 1
    if let failOnCall, callCount == failOnCall {
      throw InjectedError.encodeFailed
    }
    writtenSampleCounts.append(samples.count)
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  func finish() throws {}
}

/// Real-temp-directory tests for ``ChunkEncoder`` -- tier-1/2 per
/// `docs/engineering-practices.md`: real filesystem I/O throughout, with
/// the encode-failure path exercised via the injected
/// ``RecordingOrFailingWriter`` fake rather than a real codec fault.
@Suite("ChunkEncoder")
struct ChunkEncoderTests {
  private let nativeRate = 48000
  private let asrRate = 16000

  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ChunkEncoderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeBuffer(seconds: Double, sampleRate: Int) -> AudioBuffer {
    AudioBuffer(
      samples: [Float](repeating: 0.1, count: Int(seconds * Double(sampleRate))),
      sampleRate: sampleRate)
  }

  private func makeEncoder(
    dataRoot: URL,
    storeNative: Bool = true,
    chunkSeconds: Double = 1.0,
    startInstant: Instant = Instant(secondsSinceEpoch: 1_000),
    chunkFileWriterFactory: ChunkFileWriterFactory? = nil,
    chunkFileReaderFactory: ChunkFileReaderFactory? = nil,
    logSink: any LogRecordSink = NoOpLogRecordSink()
  ) throws -> (ChunkEncoder, IndexAppender) {
    let indexAppender = IndexAppender(
      fileURL: DataStoreLayout.structuralIndexFile(dataRoot: dataRoot, sourceID: "mic"))
    let encoder = try ChunkEncoder(
      sourceID: "mic",
      dataRoot: dataRoot,
      codec: "aac",
      bitrate: 64000,
      nativeSampleRate: nativeRate,
      asrSampleRate: asrRate,
      storeNative: storeNative,
      chunkSeconds: chunkSeconds,
      startInstant: startInstant,
      indexAppender: indexAppender,
      chunkFileWriterFactory: chunkFileWriterFactory ?? AVFoundationChunkFileWriter.make,
      chunkFileReaderFactory: chunkFileReaderFactory ?? AVFoundationChunkFileReader.make,
      clock: ManualClock(startInstant),
      logSink: logSink
    )
    return (encoder, indexAppender)
  }

  @Test("appending less than chunkSeconds does not roll over")
  func appendingLessThanChunkSecondsDoesNotRollOver() async throws {
    let dataRoot = try makeDataRoot()
    let (encoder, appender) = try makeEncoder(dataRoot: dataRoot, chunkSeconds: 1.0)

    try await encoder.append(makeBuffer(seconds: 0.4, sampleRate: nativeRate))

    let contents = try await appender.readContents()
    #expect(contents.isEmpty)
  }

  @Test("reaching chunkSeconds rolls over: writes both feeds and appends one chunk event")
  func rolloverWritesBothFeedsAndAppendsEvent() async throws {
    let dataRoot = try makeDataRoot()
    let start = Instant(secondsSinceEpoch: 1_000)
    let (encoder, appender) = try makeEncoder(
      dataRoot: dataRoot, chunkSeconds: 1.0, startInstant: start)

    try await encoder.append(makeBuffer(seconds: 0.5, sampleRate: nativeRate))
    try await encoder.append(makeBuffer(seconds: 0.5, sampleRate: nativeRate))

    let contents = try await appender.readContents()
    let parsed = IndexLog.parse(contents)
    #expect(parsed.malformedLines.isEmpty)
    #expect(parsed.events.count == 1)

    guard case .chunk(let eventStart, let eventEnd, let file, let frames) = parsed.events[0] else {
      Issue.record("expected a chunk event")
      return
    }
    #expect(eventStart == start)
    #expect(eventEnd == start.advanced(by: 1.0))
    #expect(frames == 48000)

    let expectedFilename = FilenameTimestampCodec.string(for: start) + ".m4a"
    let nativeURL = DataStoreLayout.chunksDirectory(dataRoot: dataRoot, sourceID: "mic")
      .appendingPathComponent(expectedFilename)
    let asrURL = DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: "mic")
      .appendingPathComponent(expectedFilename)
    #expect(FileManager.default.fileExists(atPath: nativeURL.path))
    #expect(FileManager.default.fileExists(atPath: asrURL.path))
    #expect(file == "chunks/\(expectedFilename)")
  }

  @Test("a second chunk's start is contiguous with the first chunk's end")
  func secondChunkStartsWhereFirstEnded() async throws {
    let dataRoot = try makeDataRoot()
    let start = Instant(secondsSinceEpoch: 1_000)
    let (encoder, appender) = try makeEncoder(
      dataRoot: dataRoot, chunkSeconds: 1.0, startInstant: start)

    try await encoder.append(makeBuffer(seconds: 1.0, sampleRate: nativeRate))
    try await encoder.append(makeBuffer(seconds: 1.0, sampleRate: nativeRate))

    let contents = try await appender.readContents()
    let parsed = IndexLog.parse(contents)
    #expect(parsed.events.count == 2)

    guard case .chunk(let firstStart, let firstEnd, _, _) = parsed.events[0],
      case .chunk(let secondStart, _, _, _) = parsed.events[1]
    else {
      Issue.record("expected two chunk events")
      return
    }
    #expect(firstStart == start)
    #expect(secondStart == firstEnd)
  }

  @Test("sample rate mismatch throws and does not accumulate the buffer")
  func sampleRateMismatchThrows() async throws {
    let dataRoot = try makeDataRoot()
    let (encoder, appender) = try makeEncoder(dataRoot: dataRoot, chunkSeconds: 1.0)

    await #expect(throws: DataStoreError.sampleRateMismatch(expected: nativeRate, got: 44100)) {
      try await encoder.append(makeBuffer(seconds: 0.5, sampleRate: 44100))
    }

    let contents = try await appender.readContents()
    #expect(contents.isEmpty)
  }

  @Test("flush finalizes a short chunk that hasn't reached chunkSeconds")
  func flushFinalizesShortChunk() async throws {
    let dataRoot = try makeDataRoot()
    let start = Instant(secondsSinceEpoch: 1_000)
    let (encoder, appender) = try makeEncoder(
      dataRoot: dataRoot, chunkSeconds: 30, startInstant: start)

    try await encoder.append(makeBuffer(seconds: 0.2, sampleRate: nativeRate))
    try await encoder.flush()

    let contents = try await appender.readContents()
    let parsed = IndexLog.parse(contents)
    #expect(parsed.events.count == 1)
    guard case .chunk(_, let end, _, let frames) = parsed.events[0] else {
      Issue.record("expected a chunk event")
      return
    }
    // A tolerance, not exact equality: index.jsonl round-trips timestamps
    // through ISO-8601-with-milliseconds text (IndexTimestampCodec, already
    // built), which loses sub-millisecond precision -- 0.2s doesn't land on
    // an exactly-representable binary fraction, so the value read back
    // differs from the in-memory Double by a fraction of a millisecond.
    #expect(abs(end.interval(since: start.advanced(by: 0.2))) < 0.001)
    #expect(frames == Int(0.2 * Double(nativeRate)))
  }

  @Test("flush with nothing pending is a no-op")
  func flushWithNothingPendingIsNoOp() async throws {
    let dataRoot = try makeDataRoot()
    let (encoder, appender) = try makeEncoder(dataRoot: dataRoot, chunkSeconds: 30)

    try await encoder.flush()

    let contents = try await appender.readContents()
    #expect(contents.isEmpty)
  }

  @Test("store_native = false skips the chunks/ copy and indexes the asr/ copy")
  func storeNativeFalseSkipsNativeCopy() async throws {
    let dataRoot = try makeDataRoot()
    let start = Instant(secondsSinceEpoch: 1_000)
    let (encoder, appender) = try makeEncoder(
      dataRoot: dataRoot, storeNative: false, chunkSeconds: 1.0, startInstant: start)

    try await encoder.append(makeBuffer(seconds: 1.0, sampleRate: nativeRate))

    let expectedFilename = FilenameTimestampCodec.string(for: start) + ".m4a"
    let nativeURL = DataStoreLayout.chunksDirectory(dataRoot: dataRoot, sourceID: "mic")
      .appendingPathComponent(expectedFilename)
    let asrURL = DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: "mic")
      .appendingPathComponent(expectedFilename)

    #expect(!FileManager.default.fileExists(atPath: nativeURL.path))
    #expect(FileManager.default.fileExists(atPath: asrURL.path))

    let contents = try await appender.readContents()
    let parsed = IndexLog.parse(contents)
    #expect(parsed.events.count == 1)
    guard case .chunk(_, _, let file, _) = parsed.events[0] else {
      Issue.record("expected a chunk event")
      return
    }
    #expect(file == "asr/\(expectedFilename)")
  }

  @Test(
    "an encode failure on the native feed partway through a chunk keeps the partial file, truncates the index event, and reports which feed failed"
  )
  func encodeFailureKeepsPartialChunk() async throws {
    let dataRoot = try makeDataRoot()
    let start = Instant(secondsSinceEpoch: 1_000)

    // The native feed's writer fails on its 2nd write() call (the 2nd
    // buffer); the ASR feed's writer never fails.
    let factory: ChunkFileWriterFactory = { url, _ in
      if url.path.contains("/chunks/") {
        return RecordingOrFailingWriter(url: url, failOnCall: 2)
      }
      return RecordingOrFailingWriter(url: url, failOnCall: nil)
    }

    let (encoder, appender) = try makeEncoder(
      dataRoot: dataRoot, chunkSeconds: 1.0, startInstant: start, chunkFileWriterFactory: factory)

    try await encoder.append(makeBuffer(seconds: 0.5, sampleRate: nativeRate))

    await #expect(throws: DataStoreError.partialChunkWrite(nativeFailed: true, asrFailed: false)) {
      try await encoder.append(makeBuffer(seconds: 0.5, sampleRate: nativeRate))
    }

    // The chunks/ file was still promoted (not discarded) despite the
    // failure, and contains exactly the first buffer's raw samples (the
    // fake writer writes untouched Float32 bytes).
    let expectedFilename = FilenameTimestampCodec.string(for: start) + ".m4a"
    let nativeURL = DataStoreLayout.chunksDirectory(dataRoot: dataRoot, sourceID: "mic")
      .appendingPathComponent(expectedFilename)
    #expect(FileManager.default.fileExists(atPath: nativeURL.path))
    let attributes = try FileManager.default.attributesOfItem(atPath: nativeURL.path)
    let size = attributes[.size] as? Int ?? 0
    #expect(size == 24_000 * MemoryLayout<Float>.size)  // 0.5s @ 48kHz, one buffer only

    // The ASR feed, unaffected, still has both buffers' resampled audio.
    let asrURL = DataStoreLayout.asrDirectory(dataRoot: dataRoot, sourceID: "mic")
      .appendingPathComponent(expectedFilename)
    #expect(FileManager.default.fileExists(atPath: asrURL.path))

    // The index event reflects only the successfully-written first buffer.
    let contents = try await appender.readContents()
    let parsed = IndexLog.parse(contents)
    #expect(parsed.events.count == 1)
    guard case .chunk(let eventStart, let eventEnd, let file, let frames) = parsed.events[0] else {
      Issue.record("expected a chunk event")
      return
    }
    #expect(eventStart == start)
    #expect(eventEnd == start.advanced(by: 0.5))
    #expect(frames == 24_000)
    #expect(file == "chunks/\(expectedFilename)")
  }

  @Test("the encoder is still usable for a new chunk after an encode failure")
  func encoderUsableAfterFailure() async throws {
    let dataRoot = try makeDataRoot()
    let start = Instant(secondsSinceEpoch: 1_000)

    let factory: ChunkFileWriterFactory = { url, _ in
      if url.path.contains("/chunks/") {
        return RecordingOrFailingWriter(url: url, failOnCall: 2)
      }
      return RecordingOrFailingWriter(url: url, failOnCall: nil)
    }

    let (encoder, appender) = try makeEncoder(
      dataRoot: dataRoot, chunkSeconds: 1.0, startInstant: start, chunkFileWriterFactory: factory)

    try await encoder.append(makeBuffer(seconds: 0.5, sampleRate: nativeRate))
    // This append triggers the failing rollover.
    await #expect(throws: DataStoreError.self) {
      try await encoder.append(makeBuffer(seconds: 0.5, sampleRate: nativeRate))
    }

    // A fresh append after the failure does not crash and is accepted.
    try await encoder.append(makeBuffer(seconds: 0.5, sampleRate: nativeRate))

    let contents = try await appender.readContents()
    let parsed = IndexLog.parse(contents)
    #expect(parsed.events.count == 1)  // only the truncated chunk from the failure so far
  }

  // MARK: - Post-write validity check (all-ears issue #26)

  @Test("finalizing a chunk logs capture.chunk_finalized with a passing open check")
  func finalizeLogsPassingOpenCheck() async throws {
    let dataRoot = try makeDataRoot()
    let start = Instant(secondsSinceEpoch: 1_000)
    let logger = RecordingLogRecordSink()
    // The real AAC writer + real decoder: a healthy chunk opens cleanly, so the
    // post-write check passes and the finalization is logged at debug.
    let (encoder, _) = try makeEncoder(
      dataRoot: dataRoot, chunkSeconds: 1.0, startInstant: start, logSink: logger)

    try await encoder.append(makeBuffer(seconds: 0.5, sampleRate: nativeRate))
    try await encoder.append(makeBuffer(seconds: 0.5, sampleRate: nativeRate))

    let finalized = try #require(
      logger.recorded.first(where: { $0.event == "capture.chunk_finalized" }))
    #expect(finalized.level == .debug)
    #expect(finalized.fields.contains(LogField("source", .string("mic"))))
    #expect(finalized.fields.contains(LogField("open_check", .string("ok"))))
    #expect(finalized.fields.contains(LogField("declared_sample_rate", .int(asrRate))))
    // The check decoded a real, non-empty ASR file (exact count is codec
    // -priming dependent, so this is a floor, not equality).
    let decoded = try #require(
      finalized.fields.first(where: { $0.key == "decoded_frames" }))
    guard case .int(let decodedFrames) = decoded.value else {
      Issue.record("expected an int decoded_frames field")
      return
    }
    #expect(decodedFrames > 0)
    // No error field on the happy path.
    #expect(!finalized.fields.contains { $0.key == "error" })
  }

  @Test("a finalized chunk that won't open is flagged loudly at write time")
  func finalizeFlagsUnreadableChunk() async throws {
    let dataRoot = try makeDataRoot()
    let start = Instant(secondsSinceEpoch: 1_000)
    let logger = RecordingLogRecordSink()
    // The write succeeds (real AAC writer) but the post-write open check is
    // forced to fail — modelling a chunk that lands on disk yet later refuses
    // ExtAudioFileOpenURL. The finalization log must surface it as an error at
    // write time, not leave it to poison a transcribe run silently.
    let failingReader: ChunkFileReaderFactory = { _ in
      throw ChunkEncoderTestError.unreadable
    }
    let (encoder, appender) = try makeEncoder(
      dataRoot: dataRoot, chunkSeconds: 1.0, startInstant: start,
      chunkFileReaderFactory: failingReader, logSink: logger)

    try await encoder.append(makeBuffer(seconds: 0.5, sampleRate: nativeRate))
    try await encoder.append(makeBuffer(seconds: 0.5, sampleRate: nativeRate))

    let finalized = try #require(
      logger.recorded.first(where: { $0.event == "capture.chunk_finalized" }))
    #expect(finalized.level == .error)
    #expect(finalized.fields.contains(LogField("open_check", .string("failed"))))
    #expect(finalized.fields.contains { $0.key == "error" })
    #expect(finalized.fields.contains(LogField("decoded_frames", .int(0))))

    // The chunk is still indexed — the write itself succeeded; only the
    // validity check failed, and that is what the log records.
    let parsed = IndexLog.parse(try await appender.readContents())
    #expect(parsed.events.count == 1)
  }
}

private enum ChunkEncoderTestError: Error {
  case unreadable
}

/// A ``LogRecordSink`` that captures every record so the encoder's post-write
/// validity logging can be asserted on. Mirrors the daemon-kit test sink; kept
/// local to this target to avoid a shared-test-support dependency.
private final class RecordingLogRecordSink: LogRecordSink, @unchecked Sendable {
  private let records = Mutex<[LogRecord]>([])

  func log(_ record: LogRecord) async throws {
    records.withLock { $0.append(record) }
  }

  var recorded: [LogRecord] { records.withLock { $0 } }
}
