import AVFoundation
import CoreAudio
import Synchronization

/// A fixed-capacity single-producer/single-consumer (SPSC) RAM ring buffer that
/// the realtime audio tap callback publishes mono PCM samples into and a separate
/// worker drains. This is the *realtime jitter buffer* from
/// `docs/architecture.md`'s "Two buffers, kept distinct" — milliseconds-to-seconds
/// deep — and is never the on-disk retroactive ring.
///
/// - `@unchecked Sendable` justification: this is the project's single documented,
///   *legitimate* exception to the "no `@unchecked Sendable`" rule
///   (`docs/architecture.md` §"Concurrency & runtime model"). The producer is a
///   realtime Core Audio render/tap callback where a custom `actor` hop would add
///   unacceptable latency and is disallowed on the audio thread. A single
///   `Mutex` guards the ring's indices and counters; the backing sample storage
///   is a preallocated `UnsafeMutableBufferPointer` so the producer path performs
///   no heap allocation. Every mutable field is reachable only under the lock, so
///   the type is race-free despite the unchecked annotation.
///
/// - Drop-loud under backpressure: when the consumer can't keep up, incoming
///   samples that don't fit are dropped (not buffered unbounded), a cumulative
///   ``droppedSampleCount`` is surfaced for logging, and after
///   ``maxConsecutiveDropEvents`` successive *write calls* that each had to drop,
///   the ring latches ``hasFailed`` so the backend can fail the stream rather
///   than silently degrading forever. A write that fits fully resets the
///   consecutive-drop run.
public final class AudioSampleRing: @unchecked Sendable {
  /// Default number of consecutive drop-events tolerated before the ring latches
  /// failure. At a typical ~10 ms tap callback cadence this is ~0.5 s of
  /// sustained, unrelieved backpressure — long enough to ride out a transient
  /// scheduling hiccup, short enough to fail loud well before memory or latency
  /// becomes a problem.
  public static let defaultMaxConsecutiveDropEvents = 50

  private struct State {
    var head = 0  // next slot to read
    var count = 0  // samples currently buffered
    var droppedSamples = 0
    var consecutiveDropEvents = 0
    var failed = false
  }

  private let storage: UnsafeMutableBufferPointer<Float>
  private let capacity: Int
  private let maxConsecutiveDropEvents: Int
  private let state = Mutex(State())

  /// - Parameters:
  ///   - capacity: fixed number of `Float` samples the ring can hold.
  ///   - maxConsecutiveDropEvents: consecutive write calls that each drop at
  ///     least one sample before the ring latches ``hasFailed``.
  public init(
    capacity: Int,
    maxConsecutiveDropEvents: Int = AudioSampleRing.defaultMaxConsecutiveDropEvents
  ) {
    precondition(capacity > 0, "ring capacity must be positive")
    self.capacity = capacity
    self.maxConsecutiveDropEvents = maxConsecutiveDropEvents
    storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
    storage.initialize(repeating: 0)
  }

  deinit {
    storage.deinitialize()
    storage.deallocate()
  }

  /// Cumulative count of samples dropped since creation, for logging.
  public var droppedSampleCount: Int {
    state.withLock { $0.droppedSamples }
  }

  /// `true` once sustained backpressure has exceeded
  /// ``maxConsecutiveDropEvents`` consecutive drop events. Latches — the ring
  /// never un-fails.
  public var hasFailed: Bool {
    state.withLock { $0.failed }
  }

  /// Samples currently available to read.
  public var availableCount: Int {
    state.withLock { $0.count }
  }

  /// Producer path (realtime-safe, allocation-free): publish `samples` into the
  /// ring. Returns `false` once the ring has latched failure. Overflow samples
  /// are dropped-loud.
  @discardableResult
  public func write(_ samples: UnsafeBufferPointer<Float>) -> Bool {
    state.withLock { s in
      writeLocked(&s, count: samples.count) { destination, sourceOffset in
        destination.pointee = samples[sourceOffset]
      }
    }
  }

  /// Convenience producer path for tests and non-realtime callers.
  @discardableResult
  public func write(_ samples: [Float]) -> Bool {
    samples.withUnsafeBufferPointer { write($0) }
  }

  /// Producer path for a live tap buffer. Derives the frame count from the
  /// buffer's **live `frameLength`** (never `ASBD.mBytesPerFrame`) — the
  /// FluidVoice 3×-playback-speed bug comes from getting this wrong — and
  /// downmixes to mono in place, allocation-free, straight into ring storage.
  /// Returns `false` once the ring has latched failure.
  @discardableResult
  public func write(from buffer: AVAudioPCMBuffer) -> Bool {
    let frames = Self.frameCount(of: buffer)
    guard frames > 0, let channels = buffer.floatChannelData else {
      return !hasFailed
    }
    let channelCount = Int(buffer.format.channelCount)
    let stride = buffer.stride
    return state.withLock { s in
      writeLocked(&s, count: frames) { destination, frame in
        if channelCount == 1 {
          destination.pointee = channels[0][frame * stride]
        } else {
          var sum: Float = 0
          for channel in 0..<channelCount {
            sum += channels[channel][frame * stride]
          }
          destination.pointee = sum / Float(channelCount)
        }
      }
    }
  }

  /// Producer path for a raw Core Audio HAL `AudioBufferList` — the shape a
  /// process-tap aggregate device's `AudioDeviceIOBlock` receives, unlike
  /// `AVAudioEngine`'s `AVAudioPCMBuffer`. Downmixes to mono in place,
  /// allocation-free, straight into ring storage, honouring
  /// `asbd.mFormatFlags`' interleaved-vs-non-interleaved layout (a tap's
  /// buffers are typically non-interleaved Float32, one buffer per channel,
  /// but this handles a single interleaved buffer too). Returns `false` once
  /// the ring has latched failure.
  ///
  /// Assumes Float32 samples throughout (`asbd`'s `mBitsPerChannel`/
  /// `mFormatID`), matching what a Core Audio process tap's
  /// `kAudioTapPropertyFormat` always reports — this is not a general PCM
  /// format converter.
  @discardableResult
  public func write(
    from bufferList: UnsafePointer<AudioBufferList>, frameCount: Int,
    asbd: AudioStreamBasicDescription
  ) -> Bool {
    guard frameCount > 0 else { return !hasFailed }
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
    let channelCount = Int(asbd.mChannelsPerFrame)
    guard channelCount > 0, abl.count > 0, let firstData = abl[0].mData else {
      return !hasFailed
    }
    let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

    return state.withLock { s in
      if nonInterleaved {
        return writeLocked(&s, count: frameCount) { destination, frame in
          if channelCount == 1 || abl.count == 1 {
            destination.pointee = firstData.assumingMemoryBound(to: Float.self)[frame]
          } else {
            var sum: Float = 0
            for channel in 0..<min(channelCount, abl.count) {
              guard let data = abl[channel].mData else { continue }
              sum += data.assumingMemoryBound(to: Float.self)[frame]
            }
            destination.pointee = sum / Float(channelCount)
          }
        }
      } else {
        let samples = firstData.assumingMemoryBound(to: Float.self)
        return writeLocked(&s, count: frameCount) { destination, frame in
          if channelCount == 1 {
            destination.pointee = samples[frame]
          } else {
            var sum: Float = 0
            for channel in 0..<channelCount {
              sum += samples[frame * channelCount + channel]
            }
            destination.pointee = sum / Float(channelCount)
          }
        }
      }
    }
  }

  /// Consumer path: remove and return up to `maxCount` buffered samples in FIFO
  /// order. Allocates on the (non-realtime) consumer thread, which is fine.
  public func read(maxCount: Int) -> [Float] {
    guard maxCount > 0 else { return [] }
    return state.withLock { s in
      let n = Swift.min(maxCount, s.count)
      guard n > 0 else { return [] }
      var out = [Float](repeating: 0, count: n)
      for i in 0..<n {
        out[i] = storage[(s.head + i) % capacity]
      }
      s.head = (s.head + n) % capacity
      s.count -= n
      return out
    }
  }

  /// The FluidVoice guard, exposed for direct testing: the frame count is the
  /// buffer's live layout, not a byte-size division.
  public static func frameCount(of buffer: AVAudioPCMBuffer) -> Int {
    Int(buffer.frameLength)
  }

  /// Shared write core, run under the lock. `produce(destination, index)` writes
  /// the `index`-th incoming sample into `destination`. Copies as many samples
  /// as fit, drops the overflow loud, and updates the failure latch.
  private func writeLocked(
    _ s: inout State,
    count: Int,
    produce: (_ destination: UnsafeMutablePointer<Float>, _ index: Int) -> Void
  ) -> Bool {
    if s.failed { return false }
    guard count > 0 else { return true }

    let free = capacity - s.count
    let toWrite = Swift.min(count, free)
    var writeIndex = (s.head + s.count) % capacity
    for i in 0..<toWrite {
      produce(storage.baseAddress! + writeIndex, i)
      writeIndex = (writeIndex + 1) % capacity
    }
    s.count += toWrite

    let dropped = count - toWrite
    if dropped > 0 {
      s.droppedSamples += dropped
      s.consecutiveDropEvents += 1
      if s.consecutiveDropEvents >= maxConsecutiveDropEvents {
        s.failed = true
        return false
      }
    } else {
      s.consecutiveDropEvents = 0
    }
    return true
  }
}
