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
  /// `/usr/bin/env` resolution); tests inject a scripted fake. Now shared
  /// with browser-triggered closes as ``OnClosePipelineRunner/ProcessRunner``.
  public typealias ProcessRunner = OnClosePipelineRunner.ProcessRunner

  private let rules: [TriggerRuleConfiguration]
  private let sessions: SessionRegistry
  private let tracker: any RunningApplicationTracking
  private let pipeline: OnClosePipelineRunner
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
    self.tracker = tracker
    self.pipeline = OnClosePipelineRunner(outputRoot: outputRoot, runProcess: runProcess, log: log)
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

  /// Runs `rule.onClose`'s stages in order against the closed session, via
  /// the shared ``OnClosePipelineRunner`` (which owns the stop-loudly-on-
  /// failure contract and the per-stage argv construction).
  private func runOnClosePipeline(rule: TriggerRuleConfiguration, descriptor: SessionDescriptor)
    async
  {
    await pipeline.run(
      stages: rule.onClose, for: descriptor, context: "trigger '\(rule.name)'")
  }

  /// The production ``ProcessRunner`` — kept as an alias so existing callers
  /// (and tests) don't need to know the pipeline moved.
  public static let realProcessRunner: ProcessRunner = OnClosePipelineRunner.realProcessRunner

  // MARK: - Testing hooks

  var stateForTesting: [String: TriggerRuleRuntimeState] { states }
}
