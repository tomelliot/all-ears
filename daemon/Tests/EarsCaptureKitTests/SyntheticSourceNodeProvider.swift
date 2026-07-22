import AVFoundation
import Synchronization

@testable import EarsCaptureKit

/// A ``CaptureEngineProvider`` that drives a real, running `AVAudioEngine` from an
/// injected `AVAudioSourceNode` synthesising a constant sample value in its render
/// block, in manual **offline** rendering mode.
///
/// This is the test-side half of the source-node parameterization: it exercises
/// the *identical* tap/ring/generation/frame-count pipeline the production mic
/// path uses, but a synthetic source node needs no microphone TCC grant and
/// offline rendering needs no audio device — so the full pipeline runs end-to-end
/// with zero permission involvement and no live-mic audio.
final class SyntheticSourceNodeProvider: CaptureEngineProvider {
  /// Reference-type counter so the (copyable) render block can capture it —
  /// `Atomic` is non-copyable and can't be captured directly.
  final class FrameCounter: Sendable {
    private let count = Atomic<Int>(0)
    func add(_ n: Int) { count.wrappingAdd(n, ordering: .acquiringAndReleasing) }
    var value: Int { count.load(ordering: .acquiring) }
  }

  let sampleValue: Float
  /// The rate the *next* `makeCaptureEngine()` synthesises at, stored in an
  /// `Atomic` (like ``FrameCounter``) so a test can flip it between rebuilds —
  /// modelling an input device that changes rate on a route change. Hz as an
  /// `Int` because `Double` isn't `AtomicRepresentable`.
  private let sampleRateHz: Atomic<Int>
  /// Whether the engines this provider hands back report having bound an input
  /// device, so a test can exercise ``MicCaptureBackend``'s bind-settle-window
  /// suppression without real Core Audio device binding.
  private let boundInputDevice: Bool
  private let framesProduced = FrameCounter()

  init(sampleValue: Float = 0.5, sampleRate: Double = 48_000, boundInputDevice: Bool = false) {
    self.sampleValue = sampleValue
    self.sampleRateHz = Atomic<Int>(Int(sampleRate))
    self.boundInputDevice = boundInputDevice
  }

  /// The rate the next rebuild will synthesise at.
  var sampleRate: Double { Double(sampleRateHz.load(ordering: .acquiring)) }

  /// Change the rate the *next* `makeCaptureEngine()` uses, so a test can
  /// simulate the input device switching sample rate across a route change.
  func setSampleRate(_ rate: Double) {
    sampleRateHz.store(Int(rate), ordering: .releasing)
  }

  /// Total frames the source node has synthesised across all engine generations.
  var totalFramesProduced: Int { framesProduced.value }

  func makeCaptureEngine() throws -> CaptureEngine {
    let engine = AVAudioEngine()
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
      throw SyntheticProviderError.couldNotMakeFormat
    }

    let value = sampleValue
    let counter = framesProduced
    let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
      let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
      for buffer in buffers {
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
        for frame in 0..<Int(frameCount) {
          data[frame] = value
        }
      }
      counter.add(Int(frameCount))
      return noErr
    }

    engine.attach(source)
    engine.connect(source, to: engine.mainMixerNode, format: format)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    return CaptureEngine(
      engine: engine, tapNode: source, tapBus: 0, tapFormat: format, mode: .offlineManual,
      boundInputDevice: boundInputDevice)
  }
}

enum SyntheticProviderError: Error {
  case couldNotMakeFormat
}
