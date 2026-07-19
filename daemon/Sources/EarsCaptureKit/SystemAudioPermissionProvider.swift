import EarsCore
import Synchronization

/// A ``PermissionProviding`` for the system-audio tap grant, backed by the
/// create-and-destroy probe `docs/product/specs/capture-daemon.md`'s
/// "Permissions and TCC probing" section calls for: there is no query API
/// for this grant, so it is detected by building a throwaway global tap,
/// sampling a short window of its real IO, and checking whether every
/// sample came back zero (the signature of a TCC-denied tap) — then
/// destroying it either way.
///
/// This provider covers `.systemAudio` only; `.microphone` is
/// `MicrophonePermissionProvider`'s concern (a real, queryable
/// `AVCaptureDevice` check) and resolves to `.notDetermined` here, matching
/// that type's own reciprocal scoping.
///
/// Shares ``AllZeroPCMDetector`` with ``SystemAudioCaptureBackend``'s own
/// start-time denial check, so the heuristic — and its documented
/// silence-vs-denial limitation — lives in one place.
public struct SystemAudioPermissionProvider: PermissionProviding {
  private let tapProvider: any ProcessTapEngineProvider
  private let probeWindow: Duration

  public init(
    tapProvider: any ProcessTapEngineProvider = RealProcessTapProvider(),
    probeWindow: Duration = .milliseconds(300)
  ) {
    self.tapProvider = tapProvider
    self.probeWindow = probeWindow
  }

  public func status(for permission: Permission) async -> PermissionStatus {
    switch permission {
    case .microphone:
      return .notDetermined  // MicrophonePermissionProvider's concern
    case .systemAudio:
      return await probeSystemAudio()
    }
  }

  /// There is no separate "request" affordance for this grant — macOS
  /// prompts the user automatically the first time a real tap is created,
  /// so requesting *is* probing (the throwaway tap this creates is exactly
  /// the kind of real attempt that triggers that first-time prompt).
  public func request(_ permission: Permission) async -> PermissionStatus {
    await status(for: permission)
  }

  /// Builds a throwaway global tap, samples a short window of real IO
  /// callbacks, and destroys it. Never fakes a result with a timer: a tap
  /// that couldn't even be built or started resolves to `.notDetermined`
  /// (a genuine "don't know", not a denial guess), matching the all-zero
  /// heuristic's own care not to claim more certainty than it has.
  private func probeSystemAudio() async -> PermissionStatus {
    let engine: any ProcessTapEngine
    do {
      engine = try tapProvider.makeTapEngine(mode: .system)
    } catch {
      return .notDetermined
    }
    defer { engine.stop() }

    let collected = Mutex<[Float]>([])
    do {
      try engine.start { _, inputData, _, _, _ in
        let byteSize = Int(inputData.pointee.mBuffers.mDataByteSize)
        guard byteSize > 0, let data = inputData.pointee.mBuffers.mData else { return }
        let sampleCount = byteSize / MemoryLayout<Float>.size
        let samples = data.assumingMemoryBound(to: Float.self)
        collected.withLock { collectedSamples in
          guard collectedSamples.count < 48_000 else { return }  // bounded: ~1s at 48kHz
          collectedSamples.append(
            contentsOf: UnsafeBufferPointer(start: samples, count: sampleCount))
        }
      }
    } catch {
      return .notDetermined
    }

    try? await Task.sleep(for: probeWindow)
    let samples = collected.withLock { $0 }

    if samples.isEmpty {
      return .notDetermined
    }
    return AllZeroPCMDetector.isAllZero(samples) ? .denied : .authorized
  }
}
