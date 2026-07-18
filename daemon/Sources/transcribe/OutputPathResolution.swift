import EarsCore
import Foundation

/// Resolves where a `transcribe` run's Markdown transcript and JSON sidecar
/// get written, per `docs/data-formats.md`'s output layout:
/// `<output-root>/<date>/<time>_<slug|range>.transcript.md` (and the sibling
/// `.transcript.json`).
///
/// Pure `URL` construction only -- no filesystem access -- so path shape is
/// unit-tested without touching disk, matching ``DataStoreLayout``'s own
/// split between pure path construction and I/O.
enum OutputPathResolution {
  struct Paths: Equatable {
    var markdown: URL
    var sidecar: URL
  }

  /// - Parameters:
  ///   - outputRoot: The configured `output_root`.
  ///   - requestedStart: The transcribed range's start, used for the
  ///     `<date>/<time>_` prefix when `explicitOut` isn't given.
  ///   - sourceIDs: Sources included in the run, joined into the filename's
  ///     `<slug>` (`docs/data-formats.md` doesn't define a slug for a plain
  ///     `--last`/`--source` run with no `--session`/`--slug`, so the
  ///     path-safe source ids stand in for it).
  ///   - explicitOut: `--out`, if given -- used verbatim as the Markdown
  ///     path; the JSON sidecar is derived by swapping its extension to
  ///     `.json`.
  static func resolve(
    outputRoot: URL, requestedStart: Instant, sourceIDs: [SourceID], explicitOut: String?
  ) -> Paths {
    if let explicitOut, !explicitOut.isEmpty {
      let markdown = URL(fileURLWithPath: explicitOut)
      let sidecar = markdown.deletingPathExtension().appendingPathExtension("json")
      return Paths(markdown: markdown, sidecar: sidecar)
    }

    // FilenameTimestampCodec renders "YYYY-MM-DDTHH-MM-SSZ"; splitting on
    // "T" gives exactly the "<date>" and "<time>" (minus its trailing "Z")
    // components docs/data-formats.md's output layout wants, with no new
    // date-formatting logic of this type's own.
    let timestamp = FilenameTimestampCodec.string(for: requestedStart)
    let components = timestamp.split(separator: "T", maxSplits: 1)
    let date = String(components[0])
    let time = String(components[1].dropLast())  // drop trailing "Z"

    let slug = sourceIDs.map(\.pathSafe).joined(separator: "_")
    let baseName = "\(time)_\(slug).transcript"
    let dayDirectory = outputRoot.appendingPathComponent(date)

    return Paths(
      markdown: dayDirectory.appendingPathComponent(baseName).appendingPathExtension("md"),
      sidecar: dayDirectory.appendingPathComponent(baseName).appendingPathExtension("json")
    )
  }

  /// Synthesises a session identifier for a plain `--last`/`--source` run
  /// with no `--session` (not implemented yet -- see
  /// `TranscribeRangeResolution`'s doc comment), in the same
  /// `<start-timestamp>_<slug>` shape `docs/data-formats.md` uses for a real
  /// session id (e.g. `2026-07-17T10-30-00Z_standup`), so
  /// ``TranscriptFrontmatter/session`` -- not optional in that type -- still
  /// gets a meaningful, reproducible value instead of a placeholder string.
  static func sessionIdentifier(requestedStart: Instant, sourceIDs: [SourceID]) -> String {
    let timestamp = FilenameTimestampCodec.string(for: requestedStart)
    let slug = sourceIDs.map(\.pathSafe).joined(separator: "_")
    return "\(timestamp)_\(slug)"
  }
}
