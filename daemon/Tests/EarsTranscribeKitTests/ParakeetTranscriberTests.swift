import EarsCore
import Testing

@testable import EarsTranscribeKit

@Suite("ParakeetTranscriber")
struct ParakeetTranscriberTests {
  @Test("advertises its capability flags as base-only (no streaming/biasing/word-timings yet)")
  func infoFlags() {
    let transcriber = ParakeetTranscriber()
    #expect(!transcriber.info.supportsStreaming)
    #expect(!transcriber.info.supportsBiasing)
    #expect(!transcriber.info.wordTimings)
    #expect(transcriber.info.languages == ["en"])
  }

  @Test("casting to a capability protocol fails, matching its unset info flags")
  func noCapabilityConformances() {
    let transcriber: any Transcriber = ParakeetTranscriber()
    #expect(transcriber as? StreamingTranscriber == nil)
    #expect(transcriber as? BiasingTranscriber == nil)
    #expect(transcriber as? WordTimingTranscriber == nil)
  }

  @Test("transcribing before load throws .notLoaded rather than touching FluidAudio")
  func transcribeBeforeLoadThrows() throws {
    let transcriber = ParakeetTranscriber()
    let audio = AudioBuffer(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000)

    #expect(throws: ParakeetTranscriberError.notLoaded) {
      _ = try transcriber.transcribe(audio, context: TranscribeContext())
    }
  }
}

@Suite("blockingBridge")
struct BlockingBridgeTests {
  @Test("returns the async operation's value")
  func returnsValue() throws {
    let value = try blockingBridge { 7 }
    #expect(value == 7)
  }

  @Test("propagates a thrown error")
  func propagatesError() {
    struct Boom: Error, Equatable {}
    #expect(throws: Boom.self) {
      try blockingBridge {
        throw Boom()
      }
    }
  }
}
