import Foundation
import Testing

/// Tier-3 smoke coverage for issue #25: a `transcribe` run that exits non-zero
/// must log a `run.summary` whose `status` matches that exit code — a failure
/// status carrying the error message — instead of the optimistic `status=ok`
/// the shared CLI bootstrap used to log *before* the work ran.
///
/// Spawns the real, built `transcribe` binary against a forced failure that
/// never loads the ASR model (an unknown source, rejected before any
/// transcriber is constructed — see `TranscribePipelineTests`' own coverage of
/// that fail-fast path), then reads the `--log-file` JSON Lines it wrote.
@Suite("CLI Smoke: transcribe run.summary")
struct TranscribeRunSummarySmokeTests {
  private final class BundleMarker {}

  private static func transcribeBinaryURL() throws -> URL {
    let productsDirectory = Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent()
    let url = productsDirectory.appendingPathComponent("transcribe")
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw SmokeError.binaryNotFound(url.path)
    }
    return url
  }

  private enum SmokeError: Error, CustomStringConvertible {
    case binaryNotFound(String)
    var description: String {
      switch self {
      case .binaryNotFound(let path):
        return "expected a built binary at \(path) -- run `swift build` before `swift test`"
      }
    }
  }

  private struct RunResult {
    var exitCode: Int32
    var stderr: String
  }

  /// Runs `transcribe` with a fixed (not host-inherited) environment so no
  /// ambient `EARS_*` variable can leak into config resolution.
  private static func runTranscribe(_ arguments: [String]) throws -> RunResult {
    let process = Process()
    process.executableURL = try transcribeBinaryURL()
    process.arguments = arguments
    process.environment = [:]
    let stderrPipe = Pipe()
    process.standardOutput = Pipe()
    process.standardError = stderrPipe
    try process.run()
    process.waitUntilExit()
    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    return RunResult(
      exitCode: process.terminationStatus,
      stderr: String(data: stderrData, encoding: .utf8) ?? "")
  }

  /// One temp directory scrubbed on deinit, for the config + log file.
  private final class TempDirectory {
    let url: URL
    init() {
      url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "TranscribeRunSummarySmokeTests-\(UUID().uuidString)",
          isDirectory: true
        )
      try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    func write(_ contents: String, named name: String) -> String {
      let fileURL = url.appendingPathComponent(name)
      try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
      return fileURL.path
    }
    deinit { try? FileManager.default.removeItem(at: url) }
  }

  private func logObjects(atPath path: String) throws -> [[String: Any]] {
    let contents = try String(contentsOfFile: path, encoding: .utf8)
    let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    return lines.compactMap { line -> [String: Any]? in
      guard let data = line.data(using: .utf8) else { return nil }
      return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
  }

  @Test(
    "a failed transcribe run logs run.summary with a failure status and the error message, matching its non-zero exit"
  )
  func failedRunLogsFailureSummary() throws {
    let temp = TempDirectory()
    let logPath = temp.url.appendingPathComponent("transcribe.jsonl").path
    // `data_root` points at a directory with no `sources/mic`, so `--source
    // mic` is an unknown source: a precise non-zero failure raised before the
    // ASR model is ever loaded.
    let configPath = temp.write(
      """
      data_root = "\(temp.url.path)/data"
      """,
      named: "config.toml")

    let result = try runTranscribe([
      "--config", configPath, "--log-file", logPath, "--last", "1m", "--source", "mic",
    ])

    // The run failed...
    #expect(result.exitCode != 0)

    let objects = try logObjects(atPath: logPath)
    let events = objects.compactMap { $0["event"] as? String }
    #expect(events.contains("run.start"))
    #expect(events.contains("run.summary"))

    let summaries = objects.filter { ($0["event"] as? String) == "run.summary" }
    #expect(summaries.count == 1)
    let summary = try #require(summaries.first)

    // ...and the summary says so, matching the exit code, with the error
    // message that previously only reached stderr.
    #expect(summary["status"] as? String == "error")
    #expect(summary["level"] as? String == "error")
    let errorField = try #require(summary["error"] as? String)
    #expect(errorField.contains("unknown source"))

    // The premature `status=ok` this fix removes must never appear.
    #expect(!summaries.contains { ($0["status"] as? String) == "ok" })
  }
}
