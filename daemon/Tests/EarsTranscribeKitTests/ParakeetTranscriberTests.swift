import EarsCore
import Testing

@testable import EarsTranscribeKit

@Suite("ParakeetTranscriber")
struct ParakeetTranscriberTests {
  @Test("advertises streaming (and only streaming) among the capability flags")
  func infoFlags() {
    let transcriber = ParakeetTranscriber()
    #expect(transcriber.info.supportsStreaming)
    #expect(!transcriber.info.supportsBiasing)
    #expect(!transcriber.info.wordTimings)
    #expect(transcriber.info.languages == ["en"])
  }

  @Test("capability casts match the info flags: streaming yes, the rest no")
  func capabilityConformancesMatchFlags() {
    let transcriber: any Transcriber = ParakeetTranscriber()
    #expect(transcriber as? StreamingTranscriber != nil)
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

  @Test("stepping before load throws .notLoaded rather than touching FluidAudio")
  func stepBeforeLoadThrows() throws {
    let transcriber = ParakeetTranscriber()
    let audio = AudioBuffer(samples: Array(repeating: 0, count: 16_000), sampleRate: 16_000)
    var state = DecoderState()

    #expect(throws: ParakeetTranscriberError.notLoaded) {
      _ = try transcriber.step(audio, state: &state)
    }
  }

  @Test("a step longer than the model window is refused, not silently de-streamed")
  func oversizedStepThrows() throws {
    let transcriber = ParakeetTranscriber()
    let tooLong = ParakeetTranscriber.maxStepFrameCount + 1
    let audio = AudioBuffer(samples: Array(repeating: 0, count: tooLong), sampleRate: 16_000)
    var state = DecoderState()

    #expect(
      throws: ParakeetTranscriberError.stepTooLong(
        frameCount: tooLong, maxFrameCount: ParakeetTranscriber.maxStepFrameCount)
    ) {
      _ = try transcriber.step(audio, state: &state)
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
