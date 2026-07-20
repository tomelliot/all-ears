import Darwin
import EarsCore
import Foundation

/// The `command` ``LLMBackend`` from `docs/specs/llm-stages.md`'s "Shared
/// LLM backend": any shell command line taking the prompt on stdin and returning
/// the completion on stdout. This is what `docs/configuration.md`'s
/// `[llm] backend = "llm-cli"` resolves to in practice — the default `llm -m
/// <model>` invocation is just one instance of this same shape, not a special case.
///
/// - Command resolution: `command` is split on whitespace into an executable name
///   and its arguments, then run as `/usr/bin/env <executable> <arguments...>` —
///   `PATH`-resolved like a shell would, without spawning a full shell (`sh -c`)
///   and its quoting/injection surface. A `command` naming an executable that
///   isn't on `PATH` surfaces as ``LLMBackendError/nonZeroExit(code:stderr:)``
///   with `env`'s own "no such file" message and exit code 127 — not
///   ``LLMBackendError/launchFailed(_:)``, which is reserved for `/usr/bin/env`
///   itself failing to spawn (practically never, since it always exists).
/// - No shell features (pipes, globs, quoting) are supported in `command` — it is
///   a literal `executable arg1 arg2 ...` token list. A `docs/configuration.md`
///   `command` needing shell features should invoke `sh -c '...'` explicitly as
///   its own first token.
/// - stdin/stdout/stderr are drained concurrently while writing the prompt, so a
///   completion larger than the pipe buffer can't deadlock the process (the
///   classic `Process`/`Pipe` gotcha of writing all input before reading any
///   output).
/// - `timeout` bounds the whole call; on expiry the process is terminated and
///   ``LLMBackendError/timedOut`` is thrown — never left to hang forever per
///   `docs/specs/llm-stages.md`'s "failures are loud and non-zero".
public struct CommandLLMBackend: LLMBackend {
  public let info: LLMBackendInfo
  public var command: String
  public var timeout: Duration

  public init(info: LLMBackendInfo, command: String, timeout: Duration = .seconds(120)) {
    self.info = info
    self.command = command
    self.timeout = timeout
  }

  public func complete(_ prompt: LLMPrompt) async throws -> LLMCompletionResult {
    let tokens = command.split(separator: " ").map(String.init)
    guard let executable = tokens.first else {
      throw LLMBackendError.launchFailed("empty command")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + tokens.dropFirst()

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr

    do {
      try process.run()
    } catch {
      throw LLMBackendError.launchFailed(error.localizedDescription)
    }

    let inputData = Data(prompt.fullText.utf8)
    let stdinHandle = stdin.fileHandleForWriting
    // A short-lived child (e.g. a nonexistent command, or one that exits
    // immediately) can close its stdin read end before this write happens;
    // without this, the next write to that broken pipe raises SIGPIPE, whose
    // default disposition terminates the *whole process* (not just this
    // Task) — not merely this call throwing. `F_SETNOSIGPIPE` makes a write
    // to a closed pipe return `EPIPE` (a thrown error) instead, scoped to
    // this one file descriptor.
    _ = fcntl(stdinHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
    let writeTask = Task.detached {
      try? stdinHandle.write(contentsOf: inputData)
      try? stdinHandle.close()
    }

    async let stdoutData = Self.readAll(stdout.fileHandleForReading)
    async let stderrData = Self.readAll(stderr.fileHandleForReading)

    let exitStatus = await Self.waitWithTimeout(process, timeout: timeout)
    await writeTask.value

    guard let exitStatus else {
      throw LLMBackendError.timedOut
    }

    let outData = await stdoutData
    let errData = await stderrData

    guard exitStatus == 0 else {
      throw LLMBackendError.nonZeroExit(
        code: exitStatus, stderr: String(data: errData, encoding: .utf8) ?? "")
    }

    let text = String(data: outData, encoding: .utf8) ?? ""
    return LLMCompletionResult(
      text: text.trimmingCharacters(in: .whitespacesAndNewlines), model: info.model)
  }

  /// Races the process's real termination against `timeout`, without blocking a
  /// cooperative-pool thread on `Process.waitUntilExit()` — `terminationHandler`
  /// signals completion via a continuation instead. Returns `nil` on timeout;
  /// otherwise the real exit code.
  ///
  /// The timeout branch calls `process.terminate()` itself, *before* this
  /// function returns — not the caller, afterward. `withTaskGroup` cannot leave
  /// its scope until every child task finishes, and `cancelAll()` only sets a
  /// flag a `withCheckedContinuation`-based task never observes; terminating the
  /// process here is what actually resolves the other child's continuation
  /// promptly. Terminating from the caller instead would make this function
  /// block until the process finishes on its own — silently defeating the
  /// timeout for a genuinely hung process.
  private static func waitWithTimeout(_ process: Process, timeout: Duration) async -> Int32? {
    await withTaskGroup(of: Int32?.self) { group in
      group.addTask {
        await withCheckedContinuation { continuation in
          process.terminationHandler = { finished in
            continuation.resume(returning: finished.terminationStatus)
          }
        }
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        process.terminate()
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
  }

  /// Drains a pipe's read end to completion off the cooperative thread pool
  /// (`FileHandle.readDataToEndOfFile()` blocks), so it can run concurrently with
  /// writing stdin above.
  private static func readAll(_ handle: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(returning: handle.readDataToEndOfFile())
      }
    }
  }
}
