import EarsCore
import Foundation

/// Reconstructs a source's live ring-buffer chunks **from on-disk filenames**,
/// with no `index.jsonl` read.
///
/// Every chunk file is named for its start instant (see
/// ``FilenameTimestampCodec``), and eviction deletes the file from disk — so
/// the set of files present *is* the live set, exactly what
/// ``RingBufferReconstruction`` works to recover by pairing `chunk` events with
/// their `evict` events. For the daemon's cross-source eviction sweep, listing
/// the directory reconstructs nothing: it reads the truth directly, and works
/// on any source directory even when no `CaptureActor` is live and regardless of
/// how large or well-formed the index has grown.
///
/// The index remains the *write* target — ``EvictionExecutor`` still appends an
/// `evict` event per deletion so the readers that reconstruct state from it
/// (``RangeReconstructor``, ``StartupGapDetector``, `SegmentedAudioReader`, the
/// transcribe pipeline) never reference a file that's gone. This type only
/// replaces the *read* side of the eviction *decision*.
public enum DiskChunkScan {
  /// The live chunks in `sourceDirectory`, oldest-first, built from the
  /// filenames in the canonical chunk subdirectory.
  ///
  /// - Parameters:
  ///   - sourceDirectory: `<data-root>/sources/<id>/`.
  ///   - storeNative: The source's `meta.toml` `store_native`. It selects the
  ///     subdirectory (`chunks/` when native is stored, else `asr/`) whose
  ///     filenames the source's `chunk` events reference — so each returned
  ///     chunk's `file` path matches what an `evict` event must name to mask
  ///     it. (``EvictionExecutor`` deletes *both* copies regardless; the path
  ///     only needs to be right for the index bookkeeping.)
  ///
  /// A chunk's coverage ends where the next chunk begins (chunks are
  /// contiguous). The newest chunk has no successor, so its end is set to its
  /// own start: it is only ever aged out once the whole source has been idle
  /// past the cap — which is the correct outcome for a stopped source (e.g. an
  /// ended meeting) whose last recording is itself older than the window.
  public static func liveChunks(sourceDirectory: URL, storeNative: Bool) -> [IndexedChunk] {
    let subdirectory: ChunkSubdirectory = storeNative ? .chunks : .asr
    let directory = sourceDirectory.appendingPathComponent(subdirectory.rawValue)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    else { return [] }

    // (start, filename) for every file whose name is a chunk timestamp. The
    // extension (`.m4a`, …) is stripped first: `FilenameTimestampCodec.parse`
    // whole-matches the bare `YYYY-MM-DDTHH-MM-SSZ` form and rejects anything
    // trailing it, so a raw `lastPathComponent` would never parse.
    var scanned: [(start: Instant, filename: String)] = []
    for url in entries {
      let filename = url.lastPathComponent
      guard let start = FilenameTimestampCodec.parse(url.deletingPathExtension().lastPathComponent)
      else { continue }
      scanned.append((start, filename))
    }
    scanned.sort { $0.start < $1.start }

    return scanned.enumerated().map { index, item in
      let end = index + 1 < scanned.count ? scanned[index + 1].start : item.start
      let file = DataStoreLayout.relativeChunkPath(
        subdirectory: subdirectory, filename: item.filename)
      // `frames` is irrelevant to eviction — deletion and the `evict` event key
      // on `file`/`start` only — and this value is never persisted, so 0 is safe.
      return IndexedChunk(range: TimeRange(start: item.start, end: end), file: file, frames: 0)
    }
  }
}
