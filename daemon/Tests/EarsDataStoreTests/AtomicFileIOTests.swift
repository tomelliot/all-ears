import Foundation
import Testing

@testable import EarsDataStore

/// Real-temp-directory tests for ``AtomicFileIO`` -- tier-1/2 per
/// `docs/engineering-practices.md` (genuine filesystem I/O, no fakes needed
/// at this layer).
@Suite("AtomicFileIO")
struct AtomicFileIOTests {
  private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AtomicFileIOTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("final file is not visible under its name until the write completes")
  func finalFileNotVisibleDuringWrite() throws {
    let dir = try makeTempDirectory()
    let finalURL = dir.appendingPathComponent("chunk.txt")
    var sawFinalMidWrite = false

    try AtomicFileIO.writeAtomically(to: finalURL) { tempURL in
      try "hello".data(using: .utf8)!.write(to: tempURL)
      sawFinalMidWrite = FileManager.default.fileExists(atPath: finalURL.path)
    }

    #expect(sawFinalMidWrite == false)
    #expect(FileManager.default.fileExists(atPath: finalURL.path))
  }

  @Test("no leftover temp file remains after a successful write")
  func noLeftoverTempFile() throws {
    let dir = try makeTempDirectory()
    let finalURL = dir.appendingPathComponent("chunk.txt")

    try AtomicFileIO.writeAtomically(to: finalURL) { tempURL in
      try "hello".data(using: .utf8)!.write(to: tempURL)
    }

    let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(entries == ["chunk.txt"])
  }

  @Test("written content matches exactly what the closure wrote")
  func contentMatches() throws {
    let dir = try makeTempDirectory()
    let finalURL = dir.appendingPathComponent("chunk.txt")

    try AtomicFileIO.writeAtomically(to: finalURL) { tempURL in
      try "the-content".data(using: .utf8)!.write(to: tempURL)
    }

    let readBack = try String(contentsOf: finalURL, encoding: .utf8)
    #expect(readBack == "the-content")
  }

  @Test("parent directories are created as needed")
  func createsParentDirectories() throws {
    let dir = try makeTempDirectory()
    let finalURL = dir.appendingPathComponent("nested").appendingPathComponent("chunk.txt")

    try AtomicFileIO.writeAtomically(to: finalURL) { tempURL in
      try "hello".data(using: .utf8)!.write(to: tempURL)
    }

    #expect(FileManager.default.fileExists(atPath: finalURL.path))
  }

  @Test("a second write replaces the first under the same final name")
  func secondWriteReplacesFirst() throws {
    let dir = try makeTempDirectory()
    let finalURL = dir.appendingPathComponent("chunk.txt")

    try AtomicFileIO.writeAtomically(to: finalURL) { tempURL in
      try "first".data(using: .utf8)!.write(to: tempURL)
    }
    try AtomicFileIO.writeAtomically(to: finalURL) { tempURL in
      try "second".data(using: .utf8)!.write(to: tempURL)
    }

    let readBack = try String(contentsOf: finalURL, encoding: .utf8)
    #expect(readBack == "second")
    let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(entries == ["chunk.txt"])
  }

  private enum InjectedError: Error {
    case boom
  }

  @Test("on failure after the temp file is created, the partial file is promoted, not discarded")
  func keepsPartialFileOnFailure() throws {
    let dir = try makeTempDirectory()
    let finalURL = dir.appendingPathComponent("chunk.txt")

    #expect(throws: InjectedError.self) {
      try AtomicFileIO.writeAtomically(to: finalURL) { tempURL in
        try "partial".data(using: .utf8)!.write(to: tempURL)
        throw InjectedError.boom
      }
    }

    #expect(FileManager.default.fileExists(atPath: finalURL.path))
    let readBack = try String(contentsOf: finalURL, encoding: .utf8)
    #expect(readBack == "partial")
  }

  @Test("on failure before any temp file is created, nothing is promoted and no final file appears")
  func noPromotionWhenNoTempFileCreated() throws {
    let dir = try makeTempDirectory()
    let finalURL = dir.appendingPathComponent("chunk.txt")

    #expect(throws: InjectedError.self) {
      try AtomicFileIO.writeAtomically(to: finalURL) { _ in
        throw InjectedError.boom
      }
    }

    #expect(FileManager.default.fileExists(atPath: finalURL.path) == false)
    let entries = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    #expect(entries.isEmpty)
  }

  @Test("fsync succeeds on a plain file")
  func fsyncFile() throws {
    let dir = try makeTempDirectory()
    let fileURL = dir.appendingPathComponent("f.txt")
    try "x".data(using: .utf8)!.write(to: fileURL)
    try AtomicFileIO.fsync(fileURL)
  }

  @Test("fsync succeeds on a directory")
  func fsyncDirectory() throws {
    let dir = try makeTempDirectory()
    try AtomicFileIO.fsync(dir)
  }
}
