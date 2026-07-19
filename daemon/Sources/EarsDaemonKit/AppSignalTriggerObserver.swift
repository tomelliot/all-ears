import EarsCaptureKit
import EarsCore
import Foundation

/// Watches configured `[[triggers.rule]]`s for `on = "app-audio-active"`
/// (per `docs/configuration.md`'s "Auto-triggers"): opens a session when one
/// of a rule's `apps` produces genuine audio (not merely launches — its own
/// `app:<bundle-id>` source's VAD transitioning to `.speech`), and closes it
/// (running the rule's `on_close` pipeline) when that same app's last
/// process exits.
///
/// Testability split mirrors ``PowerObserver``'s: the pure decision core
/// (``AppSignalTriggerPolicy``) is exhaustively unit tested on its own; this
/// actor is thin, behavior-verified glue wiring real launch/terminate events
/// and the `EarsDaemon` event-bus's `vad` events into that core, then
/// carrying out its decisions (`SessionRegistry.open`/`.close`, spawning the
/// `on_close` pipeline).
///
/// ## Injection seams (mirrors `PowerObserver`'s `init(pausables:)`)
///
/// `tracker`/`runProcess`/`clock` are all injected so tests drive fake
/// launch/terminate/vad events and a fake subprocess runner — never real
/// `NSWorkspace` or a real spawned `transcribe`/`cleanup`/`summarize`.
public actor AppSignalTriggerObserver {
  /// Runs one `on_close` pipeline stage (`"transcribe"`, `"cleanup"`,
  /// `"summarize"`) with the given arguments and returns its exit code. The
  /// production runner spawns the real binary via `Foundation.Process`
  /// (resolved through `PATH`, matching `EarsLLMKit.CommandLLMBackend`'s own
  /// `/usr/bin/env` resolution); tests inject a scripted fake.
  public typealias ProcessRunner = @Sendable (String, [String]) async -> Int32

  private let rules: [TriggerRuleConfiguration]
  private let sessions: SessionRegistry
  private let tracker: any RunningApplicationTracking
  private let runProcess: ProcessRunner
  private let outputRoot: URL
  private let log: @Sendable (String) -> Void

  private var states: [String: TriggerRuleRuntimeState] = [:]
  private var appEventsTask: Task<Void, Never>?

  public init(
    rules: [TriggerRuleConfiguration],
    sessions: SessionRegistry,
    outputRoot: URL,
    tracker: any RunningApplicationTracking = RealRunningApplicationTracker(),
    runProcess: @escaping ProcessRunner = AppSignalTriggerObserver.realProcessRunner,
    log: @escaping @Sendable (String) -> Void = { _ in }
  ) {
    self.rules = rules
    self.sessions = sessions
    self.outputRoot = outputRoot
    self.tracker = tracker
    self.runProcess = runProcess
    self.log = log
    for rule in rules {
      states[rule.name] = TriggerRuleRuntimeState(
        livePIDCounts: Dictionary(uniqueKeysWithValues: rule.apps.map { ($0, 0) }))
    }
  }

  /// Starts observing launch/terminate events. Subscribes to
  /// `tracker.events()` *synchronously* before returning — exactly like
  /// `SystemAudioCaptureBackend`'s own app-event subscription — so no event
  /// landing immediately afterward is silently missed.
  public func start() {
    let events = tracker.events()
    appEventsTask = Task { [weak self] in
      for await event in events {
        await self?.handleAppEvent(event)
      }
    }
  }

  public func stop() {
    appEventsTask?.cancel()
    appEventsTask = nil
  }

  /// The `EarsDaemon.start()` event-bus fan-out calls this for every
  /// published live-feed event (widening the same `eventBus.attach` closure
  /// that forwards to the control socket) — only `.vad` transitions to
  /// `.speech`, on an `app:<bundle-id>` source, are relevant here.
  public func handle(_ event: EarsEvent) async {
    guard case .vad(let source, let state, _) = event, state == .speech else { return }
    guard source.sourceClass == .app, let bundleID = source.detail else { return }
    await route(.audioActive(bundleID: bundleID))
  }

  private func handleAppEvent(_ event: RunningApplicationEvent) async {
    let bundleID: String
    switch event {
    case .launched(let id, _), .terminated(let id, _): bundleID = id
    }
    let count = tracker.livePIDs(forBundleID: bundleID).count
    await route(.processCountChanged(bundleID: bundleID, count: count))
  }

  private func route(_ event: TriggerRuleEvent) async {
    let bundleID: String
    switch event {
    case .processCountChanged(let id, _), .audioActive(let id): bundleID = id
    }
    for rule in rules where rule.apps.contains(bundleID) {
      await apply(event, to: rule)
    }
  }

  private func apply(_ event: TriggerRuleEvent, to rule: TriggerRuleConfiguration) async {
    let current = states[rule.name] ?? TriggerRuleRuntimeState()
    let decision = AppSignalTriggerPolicy.decision(for: current, event: event)
    states[rule.name] = AppSignalTriggerPolicy.applying(event, to: current)

    switch decision {
    case .none:
      return
    case .openSession:
      guard case .audioActive(let bundleID) = event else { return }
      do {
        let descriptor = try await sessions.open(
          sources: rule.sources, slug: rule.name, start: nil, vocab: nil, trigger: .appSignal,
          preRollSeconds: rule.preRollSeconds)
        states[rule.name] = AppSignalTriggerPolicy.applyingOpenedSession(
          descriptor.id, triggeringBundleID: bundleID, to: states[rule.name] ?? current)
        log("trigger '\(rule.name)': opened session '\(descriptor.id)' (app-signal: \(bundleID))")
      } catch {
        log(
          "trigger '\(rule.name)': failed to open a session for app-signal '\(bundleID)': \(error)")
      }
    case .closeSession(let sessionID):
      let closedDescriptor: SessionDescriptor?
      do {
        closedDescriptor = try await sessions.close(id: sessionID)
        states[rule.name] = AppSignalTriggerPolicy.applyingClosedSession(
          to: states[rule.name] ?? current)
        log("trigger '\(rule.name)': closed session '\(sessionID)'")
      } catch {
        states[rule.name] = AppSignalTriggerPolicy.applyingClosedSession(
          to: states[rule.name] ?? current)
        log("trigger '\(rule.name)': failed to close session '\(sessionID)': \(error)")
        closedDescriptor = nil
      }
      if let closedDescriptor {
        await runOnClosePipeline(rule: rule, descriptor: closedDescriptor)
      }
    }
  }

  // MARK: - on_close pipeline

  /// Runs `rule.onClose`'s stages in order against the closed session,
  /// stopping the chain — loudly — on the first non-zero exit. Never
  /// silently continues past a failed stage as if the run succeeded.
  private func runOnClosePipeline(rule: TriggerRuleConfiguration, descriptor: SessionDescriptor)
    async
  {
    for stage in rule.onClose {
      guard ["transcribe", "cleanup", "summarize"].contains(stage) else {
        log("trigger '\(rule.name)' on_close: unrecognised stage '\(stage)'; stopping the chain")
        return
      }
      let arguments = pipelineArguments(stage: stage, descriptor: descriptor)
      let exitCode = await runProcess(stage, arguments)
      guard exitCode == 0 else {
        log(
          "trigger '\(rule.name)' on_close: stage '\(stage)' failed (exit \(exitCode)) for "
            + "session '\(descriptor.id)'; stopping the chain"
        )
        return
      }
      log(
        "trigger '\(rule.name)' on_close: stage '\(stage)' succeeded for session '\(descriptor.id)'"
      )
    }
  }

  /// Builds each stage's argv. `transcribe` resolves the session directly;
  /// `cleanup`/`summarize` are handed the file path the *previous* stage is
  /// expected to have written, per `docs/product/specs/llm-stages.md`'s
  /// composition example (`transcribe --session "$SID" && cleanup
  /// "$OUT/....transcript.md" && summarize "$OUT/....clean.md"`).
  ///
  /// **Known duplication:** the `<date>/<time>_<slug>.transcript.md` path
  /// shape mirrors `transcribe`'s own `OutputPathResolution` convention,
  /// restated here rather than shared, since that type lives in the
  /// `transcribe` executable target, not a library `EarsDaemonKit` can
  /// depend on. If that convention ever changes, this must change with it.
  private func pipelineArguments(stage: String, descriptor: SessionDescriptor) -> [String] {
    switch stage {
    case "transcribe":
      return ["--session", descriptor.id]
    case "cleanup":
      return [transcriptPath(for: descriptor).path]
    case "summarize":
      return [cleanedPath(for: descriptor).path, "--all-presets"]
    default:
      return []
    }
  }

  private func transcriptPath(for descriptor: SessionDescriptor) -> URL {
    let timestamp = FilenameTimestampCodec.string(for: descriptor.start)
    let components = timestamp.split(separator: "T", maxSplits: 1)
    let date = String(components[0])
    let time = String(components[1].dropLast())  // drop trailing "Z"
    return
      outputRoot
      .appendingPathComponent(date)
      .appendingPathComponent("\(time)_\(descriptor.slug).transcript.md")
  }

  private func cleanedPath(for descriptor: SessionDescriptor) -> URL {
    let transcript = transcriptPath(for: descriptor)
    let name = transcript.lastPathComponent
    guard name.hasSuffix(".transcript.md") else { return transcript }
    let stem = String(name.dropLast(".transcript.md".count))
    return transcript.deletingLastPathComponent().appendingPathComponent("\(stem).clean.md")
  }

  /// The production ``ProcessRunner``: spawns `name` (PATH-resolved via
  /// `/usr/bin/env`, matching `EarsLLMKit.CommandLLMBackend`'s own
  /// resolution) with `arguments`, waits for exit, and returns its status.
  public static let realProcessRunner: ProcessRunner = { name, arguments in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [name] + arguments
    do {
      try process.run()
    } catch {
      return -1
    }
    return await withCheckedContinuation { continuation in
      process.terminationHandler = { finished in
        continuation.resume(returning: finished.terminationStatus)
      }
    }
  }

  // MARK: - Testing hooks

  var stateForTesting: [String: TriggerRuleRuntimeState] { states }
}
