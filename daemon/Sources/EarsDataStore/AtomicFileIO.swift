import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Atomic temp-file-then-rename writes with explicit `fsync`, per
/// `docs/data-formats.md`'s "Audio chunks" section: "Written atomically
/// (temp + rename); on flush, `fsync` both the file and its directory; on
/// encode failure, keep the partial chunk."
///
/// This is the one place in the module that performs the rename/fsync
/// dance, so every caller (chunk encoding, `meta.toml`/`session.toml`
/// writes) gets the same atomicity and failure-keeping guarantee for free.
public enum AtomicFileIO {
  /// Writes to `finalURL` by calling `write` with a temporary sibling URL
  /// (in the same directory, so the final `rename` is same-volume and
  /// atomic), then promoting that temp file into place: `fsync` the temp
  /// file, rename it to `finalURL`, and `fsync` the containing directory.
  ///
  /// `write` is expected to have fully written and released any open file
  /// handle to the temp URL by the time it returns (or throws) -- this
  /// function does not hold the file open itself.
  ///
  /// **No content is ever visible under `finalURL` until the rename
  /// completes** -- the temp file's name is never the final name, so a
  /// reader listing the directory mid-write never sees a partial file
  /// under the name it expects.
  ///
  /// **On failure, the partial temp file is promoted anyway** rather than
  /// discarded, per the "keep the partial chunk" rule above -- as long as
  /// `write` got far enough to create the temp file before throwing. The
  /// original error is rethrown after promotion so the caller can log it.
  public static func writeAtomically(to finalURL: URL, write: (URL) throws -> Void) throws {
    let directory = finalURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let tempURL = directory.appendingPathComponent(
      ".tmp-\(UUID().uuidString)-\(finalURL.lastPathComponent)")

    do {
      try write(tempURL)
    } catch {
      if FileManager.default.fileExists(atPath: tempURL.path) {
        try? promote(tempURL, to: finalURL)
      }
      throw error
    }
    try promote(tempURL, to: finalURL)
  }

  /// `fsync`s `url` (a regular file or a directory) via a raw POSIX file
  /// descriptor. `FileHandle`'s `synchronize()` cannot be used uniformly
  /// here: it refuses to open a directory path, but directories still need
  /// `fsync`ing per the atomic-write contract above, so a plain `open`/
  /// `fsync`/`close` is used for both cases.
  public static func fsync(_ url: URL) throws {
    let descriptor = url.path.withCString { open($0, O_RDONLY) }
    guard descriptor >= 0 else {
      throw DataStoreIOError.fsyncFailed(path: url.path, errno: errno)
    }
    defer { close(descriptor) }
    guard Darwin.fsync(descriptor) == 0 else {
      throw DataStoreIOError.fsyncFailed(path: url.path, errno: errno)
    }
  }

  private static func promote(_ tempURL: URL, to finalURL: URL) throws {
    try fsync(tempURL)
    _ = try FileManager.default.replaceItemAt(
      finalURL, withItemAt: tempURL, options: .usingNewMetadataOnly)
    try fsync(finalURL.deletingLastPathComponent())
  }
}

/// Low-level I/O failures ``AtomicFileIO`` can raise. Kept separate from
/// ``DataStoreError`` because these are POSIX-level failures (a bad `fd`,
/// `errno`), not domain-level ones.
public enum DataStoreIOError: Error, Sendable, Hashable {
  case fsyncFailed(path: String, errno: Int32)
}
