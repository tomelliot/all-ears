import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// The real ``ChunkFileReading`` conformance: `mmap`s a raw interleaved mono
/// `Float32` PCM chunk file read-only, so a range of frames can be read
/// without ever loading the whole file into memory -- the constant-memory
/// "memory-mapped, disk-backed audio source" `docs/data-formats.md`'s
/// "Dual-rate audio storage" section calls for.
///
/// A `final class` (not a `struct`) so `deinit` can `munmap` the region
/// exactly once when the last reference is dropped. `mmap`ed memory is safe
/// to read concurrently from multiple threads (no writes ever happen
/// through this type, `PROT_READ` only), so `@unchecked Sendable` is the
/// same "thin shim behind a protocol" exception `docs/architecture.md`
/// grants ``AVFoundationChunkFileWriter``.
public final class MmapPCMChunkFileReader: ChunkFileReading, @unchecked Sendable {
  private let mapping: UnsafeMutableRawPointer?
  private let mappedByteCount: Int
  public let frameCount: Int

  public init(url: URL) throws {
    let path = url.path
    let descriptor = path.withCString { open($0, O_RDONLY) }
    guard descriptor >= 0 else {
      throw DataStoreError.chunkFileUnreadable(path: path)
    }
    defer { close(descriptor) }

    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw DataStoreError.chunkFileUnreadable(path: path)
    }
    let byteCount = Int(info.st_size)

    guard byteCount > 0 else {
      // `mmap` rejects a zero-length mapping outright; an empty chunk file
      // (a real, if rare, on-disk state -- e.g. a chunk truncated to
      // nothing by an encode failure) simply has no frames to read.
      self.mapping = nil
      self.mappedByteCount = 0
      self.frameCount = 0
      return
    }

    guard let pointer = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, descriptor, 0),
      pointer != MAP_FAILED
    else {
      throw DataStoreError.chunkFileUnreadable(path: path)
    }
    self.mapping = pointer
    self.mappedByteCount = byteCount
    self.frameCount = byteCount / MemoryLayout<Float>.size
  }

  deinit {
    if let mapping {
      munmap(mapping, mappedByteCount)
    }
  }

  public func read(frames range: Range<Int>) throws -> [Float] {
    guard range.lowerBound >= 0, range.upperBound <= frameCount else {
      throw DataStoreError.chunkRangeOutOfBounds(requested: range, available: frameCount)
    }
    guard let mapping, !range.isEmpty else { return [] }
    let floatPointer = mapping.bindMemory(to: Float.self, capacity: frameCount)
    let buffer = UnsafeBufferPointer(start: floatPointer + range.lowerBound, count: range.count)
    return Array(buffer)
  }

  /// Default ``ChunkFileReaderFactory`` real code uses.
  public static func make(url: URL) throws -> any ChunkFileReading {
    try MmapPCMChunkFileReader(url: url)
  }
}
