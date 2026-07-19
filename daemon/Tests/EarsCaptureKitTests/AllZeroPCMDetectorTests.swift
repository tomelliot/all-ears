import Testing

@testable import EarsCaptureKit

@Suite("AllZeroPCMDetector")
struct AllZeroPCMDetectorTests {
  @Test("an all-zero buffer is detected as all-zero")
  func allZeroBuffer() {
    #expect(AllZeroPCMDetector.isAllZero([0, 0, 0, 0]))
  }

  @Test("a buffer with any non-zero sample is not all-zero")
  func oneNonZeroSample() {
    #expect(!AllZeroPCMDetector.isAllZero([0, 0, 0.001, 0]))
  }

  @Test("an empty buffer is treated as all-zero (no evidence of real audio)")
  func emptyBufferIsAllZero() {
    #expect(AllZeroPCMDetector.isAllZero([]))
  }

  @Test("a negative-zero sample still counts as zero")
  func negativeZeroIsZero() {
    #expect(AllZeroPCMDetector.isAllZero([-0.0, 0.0]))
  }

  @Test("a window is all-zero only if every buffer in it is")
  func windowRequiresEveryBufferAllZero() {
    #expect(AllZeroPCMDetector.isAllZero(window: [[0, 0], [0, 0, 0]]))
    #expect(!AllZeroPCMDetector.isAllZero(window: [[0, 0], [0, 0.1, 0]]))
  }

  @Test("an empty window is not all-zero (no buffers sampled yet proves nothing)")
  func emptyWindowIsNotAllZero() {
    #expect(!AllZeroPCMDetector.isAllZero(window: []))
  }
}
