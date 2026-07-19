import AVFoundation
import CoreAudio
import Testing

@testable import EarsCaptureKit

@Suite("AudioSampleRing")
struct AudioSampleRingTests {
  @Test("writes and reads samples FIFO")
  func fifoRoundTrip() {
    let ring = AudioSampleRing(capacity: 8)
    #expect(ring.write([1, 2, 3]))
    #expect(ring.availableCount == 3)
    #expect(ring.read(maxCount: 2) == [1, 2])
    #expect(ring.read(maxCount: 10) == [3])
    #expect(ring.availableCount == 0)
  }

  @Test("wraps around the end of the backing storage")
  func wrapAround() {
    let ring = AudioSampleRing(capacity: 4)
    #expect(ring.write([1, 2, 3]))
    _ = ring.read(maxCount: 2)  // head now at 2
    #expect(ring.write([4, 5, 6]))  // wraps past capacity boundary
    #expect(ring.read(maxCount: 10) == [3, 4, 5, 6])
  }

  @Test("drops overflow loud and counts dropped samples")
  func dropsOverflow() {
    let ring = AudioSampleRing(capacity: 4)
    #expect(ring.write([1, 2, 3, 4, 5, 6]))  // 2 don't fit
    #expect(ring.droppedSampleCount == 2)
    #expect(ring.read(maxCount: 10) == [1, 2, 3, 4])  // kept the first four
  }

  @Test("a fully-fitting write resets the consecutive-drop run")
  func fittingWriteResets() {
    let ring = AudioSampleRing(capacity: 4, maxConsecutiveDropEvents: 3)
    #expect(ring.write([1, 2, 3, 4, 5]))  // drop event 1
    _ = ring.read(maxCount: 4)
    #expect(ring.write([6, 7]))  // fits: resets run
    _ = ring.read(maxCount: 2)
    // Three more drop events should be needed to fail now that the run reset.
    #expect(ring.write([1, 2, 3, 4, 5]))  // 1
    _ = ring.read(maxCount: 4)
    #expect(ring.write([1, 2, 3, 4, 5]))  // 2
    _ = ring.read(maxCount: 4)
    #expect(!ring.hasFailed)
  }

  @Test("latches failure after N consecutive drop events")
  func latchesFailure() {
    let ring = AudioSampleRing(capacity: 2, maxConsecutiveDropEvents: 3)
    #expect(ring.write([1, 2, 3]))  // drop 1
    #expect(ring.write([1, 2, 3]))  // drop 2 (ring already full)
    #expect(!ring.hasFailed)
    #expect(!ring.write([1, 2, 3]))  // drop 3 -> latch, returns false
    #expect(ring.hasFailed)
    #expect(!ring.write([9]))  // stays failed
  }

  @Test("frameCount derives from live frameLength, not byte size")
  func frameCountFromLiveLayout() throws {
    // A stereo float buffer: mBytesPerFrame == 8, so a byte-based derivation
    // (the FluidVoice bug) would miscount. frameLength is the truth.
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
    buffer.frameLength = 100
    #expect(AudioSampleRing.frameCount(of: buffer) == 100)
  }

  @Test("write(from:) downmixes stereo to mono using live frame count")
  func downmixStereo() throws {
    let format = try #require(
      AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
    buffer.frameLength = 3
    let channels = try #require(buffer.floatChannelData)
    // L = [1, 2, 3], R = [3, 4, 5] -> mono average [2, 3, 4]
    for (i, l) in [Float(1), 2, 3].enumerated() { channels[0][i] = l }
    for (i, r) in [Float(3), 4, 5].enumerated() { channels[1][i] = r }

    let ring = AudioSampleRing(capacity: 16)
    #expect(ring.write(from: buffer))
    #expect(ring.availableCount == 3)  // 3 frames, not 4 (capacity) and not a byte count
    #expect(ring.read(maxCount: 10) == [2, 3, 4])
  }

  // MARK: - write(from: AudioBufferList, ...) — the process-tap IO path

  private static func nonInterleavedASBD(channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: 48000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: channels,
      mBitsPerChannel: 32,
      mReserved: 0)
  }

  private static func interleavedASBD(channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
      mSampleRate: 48000,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat,
      mBytesPerPacket: 4 * channels,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4 * channels,
      mChannelsPerFrame: channels,
      mBitsPerChannel: 32,
      mReserved: 0)
  }

  @Test("write(from: AudioBufferList) downmixes non-interleaved stereo to mono")
  func downmixNonInterleavedBufferList() {
    let frameCount = 3
    let left: [Float] = [1, 2, 3]
    let right: [Float] = [3, 4, 5]
    let abl = AudioBufferList.allocate(maximumBuffers: 2)
    defer { abl.unsafeMutablePointer.deallocate() }

    left.withUnsafeBufferPointer { leftPointer in
      right.withUnsafeBufferPointer { rightPointer in
        abl[0] = AudioBuffer(
          mNumberChannels: 1, mDataByteSize: UInt32(frameCount * 4),
          mData: UnsafeMutableRawPointer(mutating: leftPointer.baseAddress))
        abl[1] = AudioBuffer(
          mNumberChannels: 1, mDataByteSize: UInt32(frameCount * 4),
          mData: UnsafeMutableRawPointer(mutating: rightPointer.baseAddress))

        let ring = AudioSampleRing(capacity: 16)
        #expect(
          ring.write(
            from: abl.unsafePointer, frameCount: frameCount,
            asbd: Self.nonInterleavedASBD(channels: 2)))
        #expect(ring.read(maxCount: 10) == [2, 3, 4])
      }
    }
  }

  @Test("write(from: AudioBufferList) reads a single-channel non-interleaved buffer directly")
  func monoNonInterleavedBufferList() {
    let frameCount = 3
    let samples: [Float] = [10, 20, 30]
    let abl = AudioBufferList.allocate(maximumBuffers: 1)
    defer { abl.unsafeMutablePointer.deallocate() }

    samples.withUnsafeBufferPointer { pointer in
      abl[0] = AudioBuffer(
        mNumberChannels: 1, mDataByteSize: UInt32(frameCount * 4),
        mData: UnsafeMutableRawPointer(mutating: pointer.baseAddress))

      let ring = AudioSampleRing(capacity: 16)
      #expect(
        ring.write(
          from: abl.unsafePointer, frameCount: frameCount,
          asbd: Self.nonInterleavedASBD(channels: 1)))
      #expect(ring.read(maxCount: 10) == samples)
    }
  }

  @Test("write(from: AudioBufferList) downmixes a single interleaved stereo buffer")
  func downmixInterleavedBufferList() {
    let frameCount = 3
    // Interleaved L/R: (1,3), (2,4), (3,5) -> mono average [2, 3, 4]
    let interleaved: [Float] = [1, 3, 2, 4, 3, 5]
    let abl = AudioBufferList.allocate(maximumBuffers: 1)
    defer { abl.unsafeMutablePointer.deallocate() }

    interleaved.withUnsafeBufferPointer { pointer in
      abl[0] = AudioBuffer(
        mNumberChannels: 2, mDataByteSize: UInt32(frameCount * 2 * 4),
        mData: UnsafeMutableRawPointer(mutating: pointer.baseAddress))

      let ring = AudioSampleRing(capacity: 16)
      #expect(
        ring.write(
          from: abl.unsafePointer, frameCount: frameCount,
          asbd: Self.interleavedASBD(channels: 2)))
      #expect(ring.read(maxCount: 10) == [2, 3, 4])
    }
  }
}
