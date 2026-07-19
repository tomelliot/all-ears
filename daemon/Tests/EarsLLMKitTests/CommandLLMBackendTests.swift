import EarsCore
import Testing

@testable import EarsLLMKit

/// Tier-2 behavior-verified tests: these run the *real* shim end to end against
/// real, trivial subprocesses (`cat`, `false`, `sleep`) rather than mocking
/// `Process` — per `docs/engineering-practices.md`'s tier-2 rule, a subprocess
/// shim is verified by driving it end to end, not unit-tested at the syscall.
@Suite("CommandLLMBackend")
struct CommandLLMBackendTests {
  @Test("echoes the full prompt back via a passthrough command")
  func echoesPrompt() async throws {
    let backend = CommandLLMBackend(info: LLMBackendInfo(name: "test"), command: "cat")
    let result = try await backend.complete(
      LLMPrompt(stablePrefix: "prefix: ", dynamicSuffix: "hello world"))
    #expect(result.text == "prefix: hello world")
  }

  @Test("surfaces a non-zero exit as nonZeroExit")
  func nonZeroExit() async {
    let backend = CommandLLMBackend(info: LLMBackendInfo(name: "test"), command: "false")
    await #expect(throws: LLMBackendError.self) {
      _ = try await backend.complete(LLMPrompt(stablePrefix: "", dynamicSuffix: "x"))
    }
  }

  @Test("an unresolvable command surfaces as a non-zero exit, not launchFailed")
  func unresolvableCommandIsNonZeroExit() async {
    let backend = CommandLLMBackend(
      info: LLMBackendInfo(name: "test"), command: "this-command-does-not-exist-anywhere")
    do {
      _ = try await backend.complete(LLMPrompt(stablePrefix: "", dynamicSuffix: "x"))
      Issue.record("expected an error")
    } catch let error as LLMBackendError {
      guard case .nonZeroExit = error else {
        Issue.record("expected .nonZeroExit, got \(error)")
        return
      }
    } catch {
      Issue.record("expected LLMBackendError, got \(error)")
    }
  }

  @Test("a process outliving the timeout is terminated and throws timedOut")
  func timesOut() async {
    let backend = CommandLLMBackend(
      info: LLMBackendInfo(name: "test"), command: "sleep 5", timeout: .milliseconds(200))
    await #expect(throws: LLMBackendError.timedOut) {
      _ = try await backend.complete(LLMPrompt(stablePrefix: "", dynamicSuffix: "x"))
    }
  }

  @Test("trims trailing whitespace/newlines from the completion")
  func trimsTrailingWhitespace() async throws {
    let backend = CommandLLMBackend(info: LLMBackendInfo(name: "test"), command: "cat")
    let result = try await backend.complete(LLMPrompt(stablePrefix: "", dynamicSuffix: "hi\n\n"))
    #expect(result.text == "hi")
  }

  @Test("info.model is echoed onto the completion result")
  func modelIsEchoed() async throws {
    let backend = CommandLLMBackend(
      info: LLMBackendInfo(name: "test", model: "claude-sonnet-5"), command: "cat")
    let result = try await backend.complete(LLMPrompt(stablePrefix: "", dynamicSuffix: "x"))
    #expect(result.model == "claude-sonnet-5")
  }
}
