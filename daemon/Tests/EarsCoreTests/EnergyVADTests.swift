import Foundation
import Testing

@testable import EarsCore

/// Covers ``EnergyVAD``: the RMS-threshold ``VAD`` conformance. All fixtures
/// use a sample rate and frame duration that divide evenly, so expected span
/// boundaries are exact — no rounding slop to reason about.
@Suite("EnergyVAD")
struct EnergyVADTests {
  private let sampleRate = 16_000

  /// `count` frames of `frameMs` each, either loud (a half-amplitude sine
  /// wave, well above any threshold used below) or silent (all zero).
  private func samples(frameMs: Double, loudFrames: [Bool]) -> [Float] {
    let frameSize = Int(Double(sampleRate) * frameMs / 1000)
    var result: [Float] = []
    result.reserveCapacity(frameSize * loudFrames.count)
    var phase = 0
    for loud in loudFrames {
      for _ in 0..<frameSize {
        if loud {
          let t = Double(phase) / Double(sampleRate)
          result.append(Float(0.5 * sin(2 * .pi * 440 * t)))
        } else {
          result.append(0)
        }
        phase += 1
      }
    }
    return result
  }

  private func buffer(frameMs: Double, loudFrames: [Bool]) -> AudioBuffer {
    AudioBuffer(samples: samples(frameMs: frameMs, loudFrames: loudFrames), sampleRate: sampleRate)
  }

  /// Tolerant equality for span boundaries derived from `speechPadMs / 1000`
  /// arithmetic, which can land a floating-point epsilon off an exact
  /// decimal (e.g. `0.6 + 0.3` is `0.8999999999999999`, not `0.9`).
  private func approxEqual(_ lhs: Double, _ rhs: Double) -> Bool {
    abs(lhs - rhs) < 1e-9
  }

  @Test("a pure-silence buffer yields no spans")
  func pureSilence() throws {
    let vad = EnergyVAD()
    let audio = buffer(frameMs: 20, loudFrames: Array(repeating: false, count: 10))
    #expect(try vad.detect(in: audio).isEmpty)
  }

  @Test("a fully loud buffer yields one span covering it, clamped to the buffer edges")
  func fullyLoud() throws {
    let vad = EnergyVAD()
    let audio = buffer(frameMs: 20, loudFrames: Array(repeating: true, count: 10))
    let spans = try vad.detect(in: audio)
    #expect(spans.count == 1)
    #expect(spans[0].state == .speech)
    #expect(spans[0].start == 0)
    #expect(spans[0].end == audio.duration)
  }

  @Test("a short silence gap below min_silence_ms merges the surrounding speech into one span")
  func shortGapMerges() throws {
    // 5 loud frames (500ms), 2 silent frames (200ms, below the 500ms
    // min-silence floor), 5 loud frames (500ms). No padding, to isolate
    // the merge behaviour from padding.
    let vad = EnergyVAD(speechPadMs: 0, minSilenceMs: 500)
    let loudFrames = Array(repeating: true, count: 5)
    let silentFrames = Array(repeating: false, count: 2)
    let audio = buffer(frameMs: 100, loudFrames: loudFrames + silentFrames + loudFrames)

    let spans = try vad.detect(in: audio)
    #expect(spans.count == 1)
    #expect(spans[0].state == .speech)
    #expect(spans[0].start == 0)
    #expect(spans[0].end == 1.2)
  }

  @Test("a long silence gap above min_silence_ms keeps speech spans separate")
  func longGapStaysSeparate() throws {
    // 5 loud frames (500ms), 6 silent frames (600ms, above the 500ms
    // min-silence floor), 5 loud frames (500ms). No padding.
    let vad = EnergyVAD(speechPadMs: 0, minSilenceMs: 500)
    let loudFrames = Array(repeating: true, count: 5)
    let silentFrames = Array(repeating: false, count: 6)
    let audio = buffer(frameMs: 100, loudFrames: loudFrames + silentFrames + loudFrames)

    let spans = try vad.detect(in: audio)
    #expect(spans.count == 2)
    #expect(spans[0].start == 0)
    #expect(spans[0].end == 0.5)
    #expect(spans[1].start == 1.1)
    #expect(spans[1].end == 1.6)
  }

  @Test("speech_pad_ms pads a span outward on both sides when there's room")
  func paddingExtendsBothEdges() throws {
    // 2 silent frames, 6 loud frames, 2 silent frames, all 100ms: a loud
    // region from 0.2s to 0.8s inside a 1.0s buffer. 100ms of padding on
    // each side lands well clear of the buffer edges.
    let vad = EnergyVAD(speechPadMs: 100, minSilenceMs: 500)
    let silentFrames = Array(repeating: false, count: 2)
    let loudFrames = Array(repeating: true, count: 6)
    let audio = buffer(frameMs: 100, loudFrames: silentFrames + loudFrames + silentFrames)

    let spans = try vad.detect(in: audio)
    #expect(spans.count == 1)
    #expect(spans[0].start == 0.1)
    #expect(spans[0].end == 0.9)
  }

  @Test("padding at the buffer start clamps to 0 instead of going negative")
  func paddingClampsAtStart() throws {
    // Speech starts at the very first frame; padding would push the start
    // negative without clamping.
    let vad = EnergyVAD(speechPadMs: 300, minSilenceMs: 500)
    let loudFrames = Array(repeating: true, count: 6)
    let silentFrames = Array(repeating: false, count: 4)
    let audio = buffer(frameMs: 100, loudFrames: loudFrames + silentFrames)

    let spans = try vad.detect(in: audio)
    #expect(spans.count == 1)
    #expect(spans[0].start == 0)
    #expect(approxEqual(spans[0].end, 0.9))
  }

  @Test("padding at the buffer end clamps to the buffer duration instead of overshooting")
  func paddingClampsAtEnd() throws {
    // Speech runs all the way to the last frame; padding would push the
    // end past the buffer's duration without clamping.
    let vad = EnergyVAD(speechPadMs: 300, minSilenceMs: 500)
    let silentFrames = Array(repeating: false, count: 4)
    let loudFrames = Array(repeating: true, count: 6)
    let audio = buffer(frameMs: 100, loudFrames: silentFrames + loudFrames)

    let spans = try vad.detect(in: audio)
    #expect(spans.count == 1)
    #expect(approxEqual(spans[0].start, 0.1))
    #expect(spans[0].end == 1.0)
  }

  @Test("an empty buffer yields no spans")
  func emptyBuffer() throws {
    let vad = EnergyVAD()
    let audio = AudioBuffer(samples: [], sampleRate: sampleRate)
    #expect(try vad.detect(in: audio).isEmpty)
  }
}
