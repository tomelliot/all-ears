import EarsCore
import Foundation
import Synchronization
import Testing

@testable import EarsDaemonKit

/// Coverage for all-ears issue #21: the daemon's on-close/on-end pipeline must
/// capture the spawned child's stderr and surface it — with the exit code and
/// the full argv, keyed by meeting id — in the daemon log on any non-zero
/// exit, so a failing run is diagnosable from the log alone instead of leaving
/// its "actual error message unrecoverable".
@Suite("OnClosePipelineRunner")
struct OnClosePipelineRunnerTests {
  /// Collects the runner's log lines in order.
  private final class LogCollector: Sendable {
    private let lines = Mutex<[String]>([])
    var log: @Sendable (String) -> Void { { line in self.lines.withLock { $0.append(line) } } }
    var snapshot: [String] { lines.withLock { $0 } }
  }

  /// A scripted ``OnClosePipelineRunner/ProcessRunner`` that returns a fixed
  /// outcome and records the argv it was handed.
  private final class ScriptedRunner: Sendable {
    private let outcomes: Mutex<[SpawnOutcome]>
    private let recorded = Mutex<[(name: String, arguments: [String])]>([])

    init(_ outcomes: [SpawnOutcome]) { self.outcomes = Mutex(outcomes) }

    var runner: OnClosePipelineRunner.ProcessRunner {
      { name, arguments in
        self.recorded.withLock { $0.append((name, arguments)) }
        return self.outcomes.withLock { $0.isEmpty ? SpawnOutcome(exitCode: 0) : $0.removeFirst() }
      }
    }

    var calls: [(name: String, arguments: [String])] { recorded.withLock { $0 } }
  }

  private static let outputRoot = URL(fileURLWithPath: "/tmp/on-close-runner-tests")

  // MARK: - meeting on_end

  @Test("a successful meeting transcribe logs the spawn argv and a success line, returns true")
  func meetingTranscribeSuccess() async throws {
    let logs = LogCollector()
    let runner = ScriptedRunner([SpawnOutcome(exitCode: 0)])
    let pipeline = OnClosePipelineRunner(
      outputRoot: Self.outputRoot, runProcess: runner.runner, log: logs.log)

    let succeeded = await pipeline.runMeetingTranscribe(
      meetingID: "b7acc61f", context: "meeting-end")

    #expect(succeeded)
    #expect(runner.calls.map(\.name) == ["transcribe"])
    #expect(runner.calls.first?.arguments == ["--meeting", "b7acc61f"])
    // The spawn record names the full argv, keyed by the meeting id.
    #expect(
      logs.snapshot.contains {
        $0.contains("spawning transcribe --meeting b7acc61f") && $0.contains("meeting 'b7acc61f'")
      })
    #expect(logs.snapshot.contains { $0.contains("transcribe succeeded for meeting 'b7acc61f'") })
  }

  @Test("a failed meeting transcribe logs the exit code and the captured stderr, returns false")
  func meetingTranscribeFailureLogsStderr() async throws {
    let logs = LogCollector()
    let runner = ScriptedRunner([
      SpawnOutcome(exitCode: 1, stderr: "error: unknown source 'mic': no data found")
    ])
    let pipeline = OnClosePipelineRunner(
      outputRoot: Self.outputRoot, runProcess: runner.runner, log: logs.log)

    let succeeded = await pipeline.runMeetingTranscribe(
      meetingID: "b7acc61f", context: "meeting-end")

    #expect(!succeeded)
    let failure = try #require(
      logs.snapshot.first { $0.contains("transcribe failed (exit 1)") })
    // Keyed by meeting id, and carries the child's real error message.
    #expect(failure.contains("meeting 'b7acc61f'"))
    #expect(failure.contains("stderr: error: unknown source 'mic'"))
  }

  @Test("a failed meeting transcribe with no stderr says so rather than logging an empty tail")
  func meetingTranscribeFailureEmptyStderr() async throws {
    let logs = LogCollector()
    let runner = ScriptedRunner([SpawnOutcome(exitCode: 2, stderr: "   \n")])
    let pipeline = OnClosePipelineRunner(
      outputRoot: Self.outputRoot, runProcess: runner.runner, log: logs.log)

    _ = await pipeline.runMeetingTranscribe(meetingID: "55815f35", context: "meeting-end")

    #expect(
      logs.snapshot.contains {
        $0.contains("transcribe failed (exit 2)") && $0.contains("no stderr captured")
      })
  }

  // MARK: - session on_close

  @Test("a failed on_close stage logs its stderr alongside the failure notice and stops the chain")
  func onCloseFailureLogsStderr() async throws {
    let logs = LogCollector()
    // transcribe ok, cleanup fails with a message → summarize must never run.
    let runner = ScriptedRunner([
      SpawnOutcome(exitCode: 0),
      SpawnOutcome(exitCode: 1, stderr: "error: cleanup backend timed out"),
    ])
    let pipeline = OnClosePipelineRunner(
      outputRoot: Self.outputRoot, runProcess: runner.runner, log: logs.log)

    let descriptor = SessionDescriptor(
      schema: 1, id: "2026-07-23T14-00-00Z_call", slug: "call",
      sources: ["mic"], start: Instant(secondsSinceEpoch: 1_784_284_800),
      end: Instant(secondsSinceEpoch: 1_784_285_000), state: .closed, trigger: .browserExtension)

    await pipeline.run(
      stages: ["transcribe", "cleanup", "summarize"], for: descriptor,
      context: "trigger 'meetings'")

    #expect(runner.calls.map(\.name) == ["transcribe", "cleanup"])
    #expect(
      logs.snapshot.contains {
        $0.contains("stage 'cleanup' failed (exit 1)")
          && $0.contains("stderr: error: cleanup backend timed out")
          && $0.contains("stopping the chain")
      })
  }

  // MARK: - bounded stderr

  @Test("bounded stderr trims whitespace and passes a short message through unchanged")
  func boundedStderrShort() {
    #expect(OnClosePipelineRunner.boundedStderr("  boom  \n") == "boom")
    #expect(OnClosePipelineRunner.boundedStderr("") == "")
  }

  @Test("bounded stderr keeps the tail of an over-long message and marks the truncation")
  func boundedStderrLongKeepsTail() {
    let long = String(repeating: "x", count: OnClosePipelineRunner.maxStderrLogBytes + 500)
      + "TAIL-MARKER"
    let bounded = OnClosePipelineRunner.boundedStderr(long)
    #expect(bounded.hasPrefix("…(truncated) "))
    #expect(bounded.hasSuffix("TAIL-MARKER"))
    // Bounded to the cap plus the short truncation prefix, never the full input.
    #expect(bounded.utf8.count < long.utf8.count)
  }

  // MARK: - real process runner

  @Test("the real process runner captures a child's stderr and its non-zero exit code")
  func realRunnerCapturesStderr() async throws {
    let outcome = await OnClosePipelineRunner.realProcessRunner(
      "sh", ["-c", "printf 'boom on stderr' 1>&2; exit 3"])
    #expect(outcome.exitCode == 3)
    #expect(outcome.stderr.contains("boom on stderr"))
  }

  @Test("the real process runner reports a clean zero exit with empty stderr for a silent child")
  func realRunnerSilentChild() async throws {
    let outcome = await OnClosePipelineRunner.realProcessRunner("sh", ["-c", "exit 0"])
    #expect(outcome.exitCode == 0)
    #expect(outcome.stderr.isEmpty)
  }
}
