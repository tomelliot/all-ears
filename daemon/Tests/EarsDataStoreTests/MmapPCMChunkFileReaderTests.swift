import Foundation
import Testing

@testable import EarsDataStore

/// Tier-2 per `docs/engineering-practices.md`: exercises the real
/// `mmap`-backed reader directly (this is the thin shim itself) -- the
/// read-side mirror of `AVFoundationChunkFileWriterTests`.
@Suite("MmapPCMChunkFileReader")
struct MmapPCMChunkFileReaderTests {
  private func writeRawPCMFile(_ samples: [Float]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MmapPCMChunkFileReaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("chunk.pcm")
    let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
    try data.write(to: url)
    return url
  }

  @Test("frameCount reflects the file's actual sample count, not any external claim")
  func frameCountReflectsFileSize() throws {
    let url = try writeRawPCMFile([0.1, 0.2, 0.3, 0.4, 0.5])
    let reader = try MmapPCMChunkFileReader(url: url)
    #expect(reader.frameCount == 5)
  }

  @Test("reading a sub-range returns exactly those samples, without loading the whole file")
  func readsExactSubRange() throws {
    let url = try writeRawPCMFile([0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9])
    let reader = try MmapPCMChunkFileReader(url: url)
    let samples = try reader.read(frames: 2..<5)
    #expect(samples == [0.2, 0.3, 0.4])
  }

  @Test("reading the full range returns every sample")
  func readsFullRange() throws {
    let values: [Float] = [1.0, -1.0, 0.5, -0.5]
    let url = try writeRawPCMFile(values)
    let reader = try MmapPCMChunkFileReader(url: url)
    #expect(try reader.read(frames: 0..<4) == values)
  }

  @Test("reading a range that runs past frameCount throws chunkRangeOutOfBounds")
  func readPastEndThrows() throws {
    let url = try writeRawPCMFile([0.1, 0.2, 0.3])
    let reader = try MmapPCMChunkFileReader(url: url)
    #expect(throws: DataStoreError.chunkRangeOutOfBounds(requested: 1..<5, available: 3)) {
      try reader.read(frames: 1..<5)
    }
  }

  @Test("an empty (zero-byte) chunk file has frameCount 0 and reads nothing")
  func emptyFileHasZeroFrameCount() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MmapPCMChunkFileReaderTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("empty.pcm")
    FileManager.default.createFile(atPath: url.path, contents: Data())

    let reader = try MmapPCMChunkFileReader(url: url)
    #expect(reader.frameCount == 0)
    #expect(try reader.read(frames: 0..<0) == [])
  }

  @Test("opening a nonexistent file throws chunkFileUnreadable")
  func nonexistentFileThrows() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MmapPCMChunkFileReaderTests-does-not-exist-\(UUID().uuidString).pcm")
    #expect(throws: DataStoreError.chunkFileUnreadable(path: url.path)) {
      _ = try MmapPCMChunkFileReader(url: url)
    }
  }
}
