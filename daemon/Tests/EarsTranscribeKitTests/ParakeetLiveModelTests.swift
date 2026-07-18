import EarsCore
import Foundation
import Testing

@testable import EarsTranscribeKit

/// Real, hardware-touching proof of concept for ``ParakeetTranscriber``:
/// downloads the actual Parakeet Core ML models from Hugging Face via
/// FluidAudio and runs one real ANE/Core ML inference. Per the tier-2 rule
/// in `docs/engineering-practices.md` ("behaviour-verified, not
/// unit-tested"), this is deliberately **not** part of the default `swift
/// test` run: it needs network egress and real Core ML/ANE hardware, and
/// downloads several hundred MB of model weights on first run, none of
/// which is appropriate for a gating CI suite. It only runs when
/// `EARS_LIVE_MODEL_TEST=1` is set, so it stays off by default while still
/// being a real, driveable end-to-end check a human (or a dedicated,
/// separately-scheduled CI job) can run on real hardware.
@Suite(
  "ParakeetTranscriber live model (opt-in, real FluidAudio)",
  .enabled(if: ProcessInfo.processInfo.environment["EARS_LIVE_MODEL_TEST"] == "1")
)
struct ParakeetLiveModelTests {
  @Test("downloads real Parakeet weights and transcribes a real inference call")
  func realEndToEnd() throws {
    let cacheDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("ears-live-model-test", isDirectory: true)

    let transcriber = ParakeetTranscriber(modelDirectory: cacheDir)
    try transcriber.load(LoadOptions())

    // 2 seconds of silence at 16 kHz -- enough samples to clear FluidAudio's
    // minimum-audio-length guard; silence is an acceptable "does the whole
    // pipeline run and return without throwing" smoke check (this pass
    // deliberately does not implement trailing-silence padding).
    let audio = AudioBuffer(samples: Array(repeating: 0, count: 32_000), sampleRate: 16_000)
    let segments = try transcriber.transcribe(audio, context: TranscribeContext())

    #expect(segments.count == 1)
  }
}
