import EarsCore
import Foundation
import Testing

@testable import EarsDataStore

/// Real-temp-directory round-trip tests for ``SourceMetaStore`` -- tier-1
/// per `docs/engineering-practices.md`. The TOML content mapping itself
/// (``SourceDescriptorTOML``) is already covered in `EarsConfigTests`; these
/// tests cover the file I/O this type adds on top: path layout, directory
/// creation, and the not-found error.
@Suite("SourceMetaStore")
struct SourceMetaStoreTests {
  private func makeDataRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SourceMetaStoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private static let referenceDescriptor = SourceDescriptor(
    schema: 1,
    id: "app:us.zoom.xos",
    sourceClass: .app,
    label: "Zoom",
    deviceUID: "",
    nativeSampleRate: 48000,
    asrSampleRate: 16000,
    storeNative: true,
    channels: 1,
    codec: "aac",
    bitrate: 64000,
    timeCapSeconds: 7200,
    created: Instant(secondsSinceEpoch: 1_784_284_200)
  )

  @Test("writes meta.toml at the documented path, creating the source directory")
  func writesAtDocumentedPath() throws {
    let dataRoot = try makeDataRoot()
    try SourceMetaStore.write(Self.referenceDescriptor, dataRoot: dataRoot)

    let expectedPath = dataRoot.appendingPathComponent("sources/app_us.zoom.xos/meta.toml")
    #expect(FileManager.default.fileExists(atPath: expectedPath.path))
  }

  @Test("round-trips a descriptor through a real file")
  func roundTrips() throws {
    let dataRoot = try makeDataRoot()
    try SourceMetaStore.write(Self.referenceDescriptor, dataRoot: dataRoot)

    let readBack = try SourceMetaStore.read(
      sourceID: Self.referenceDescriptor.id, dataRoot: dataRoot)
    #expect(readBack == Self.referenceDescriptor)
  }

  @Test("reading a source with no meta.toml throws sourceMetaNotFound")
  func missingFileThrows() throws {
    let dataRoot = try makeDataRoot()
    #expect(throws: DataStoreError.sourceMetaNotFound("mic")) {
      try SourceMetaStore.read(sourceID: "mic", dataRoot: dataRoot)
    }
  }

  @Test("writing again overwrites the prior content")
  func writeOverwrites() throws {
    let dataRoot = try makeDataRoot()
    try SourceMetaStore.write(Self.referenceDescriptor, dataRoot: dataRoot)

    var updated = Self.referenceDescriptor
    updated.label = "Zoom (renamed)"
    try SourceMetaStore.write(updated, dataRoot: dataRoot)

    let readBack = try SourceMetaStore.read(sourceID: updated.id, dataRoot: dataRoot)
    #expect(readBack.label == "Zoom (renamed)")
  }
}
