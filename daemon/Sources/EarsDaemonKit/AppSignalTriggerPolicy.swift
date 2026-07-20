/// One `[[triggers.rule]]`'s runtime state: which of its `apps` currently
/// have live processes, and — while a session it opened is active — which
/// bundle id opened it and that session's id.
public struct TriggerRuleRuntimeState: Sendable, Hashable {
  /// The currently-open session's id, or `nil` if this rule has no open
  /// session right now.
  public var openSessionID: String?
  /// The bundle id whose audio-active signal opened `openSessionID` — the
  /// one bundle id whose *last process exiting* closes it again. `nil`
  /// whenever `openSessionID` is `nil`.
  public var triggeringBundleID: String?
  /// Live process counts per tracked bundle id, updated on every
  /// launch/terminate event this rule cares about.
  public var livePIDCounts: [String: Int]

  public init(
    openSessionID: String? = nil,
    triggeringBundleID: String? = nil,
    livePIDCounts: [String: Int] = [:]
  ) {
    self.openSessionID = openSessionID
    self.triggeringBundleID = triggeringBundleID
    self.livePIDCounts = livePIDCounts
  }
}

/// An event ``AppSignalTriggerPolicy`` can decide on, already scoped to one
/// rule (the owning actor has already matched the event's bundle id against
/// the rule's `apps` list before calling in).
public enum TriggerRuleEvent: Sendable, Hashable {
  /// `bundleID`'s live process count changed (a launch or a terminate); the
  /// new count is `count`, not a delta.
  case processCountChanged(bundleID: String, count: Int)
  /// `bundleID`'s own `app:<bundle-id>` source's VAD just transitioned to
  /// `.speech` — the "genuine audio activity" signal `on =
  /// "app-audio-active"` means, per `docs/specs/capture-daemon.md`'s
  /// trigger contract: not merely that the app launched.
  case audioActive(bundleID: String)
}

/// What a rule should do in response to one ``TriggerRuleEvent``.
public enum TriggerDecision: Sendable, Hashable {
  /// Open a session (`SessionRegistry.open(..., trigger: .appSignal)`) —
  /// the caller supplies `sources`/`slug` from the rule's own config; this
  /// pure core doesn't carry them since it never performs the I/O itself.
  case openSession
  /// Close the named session and run the rule's `on_close` pipeline.
  case closeSession(sessionID: String)
  case none
}

/// The pure, exhaustively-testable decision core of
/// ``AppSignalTriggerObserver``, mirroring ``SuspensionTransitionPolicy``'s
/// split for `PowerObserver`: given a rule's current state and one event,
/// decide what to do. Deliberately takes and returns plain value types
/// (state in, state out) rather than mutating anything itself — the owning
/// actor applies both the decision (real I/O: open/close a session, run a
/// pipeline) and the state transition, so this stays free of `SessionRegistry`/
/// process-spawning concerns entirely.
public enum AppSignalTriggerPolicy {
  /// What to do about `event`, given the rule's `state` *before* the event
  /// is applied (see ``applying(_:to:)``).
  ///
  /// - A session only ever opens once per rule at a time: an `.audioActive`
  ///   signal while a session is already open is a no-op (`.none`).
  /// - `.audioActive` for a bundle id with no live processes recorded is
  ///   ignored — a stale or out-of-order event, not a real signal.
  /// - `.processCountChanged` only closes a session when the count drops to
  ///   zero *for the specific bundle id that opened it* — per the prompt's
  ///   "on the matched app's last process exiting", not any configured
  ///   app's exit.
  public static func decision(for state: TriggerRuleRuntimeState, event: TriggerRuleEvent)
    -> TriggerDecision
  {
    switch event {
    case .processCountChanged(let bundleID, let count):
      guard count == 0, state.triggeringBundleID == bundleID, let sessionID = state.openSessionID
      else {
        return .none
      }
      return .closeSession(sessionID: sessionID)
    case .audioActive(let bundleID):
      guard state.openSessionID == nil else { return .none }
      guard (state.livePIDCounts[bundleID] ?? 0) > 0 else { return .none }
      return .openSession
    }
  }

  /// The state transition `event` causes, independent of what the caller
  /// ultimately does about ``decision(for:event:)``'s result. Only
  /// `.processCountChanged` mutates state here — `.openSession`'s resulting
  /// session id is applied separately, once the caller actually has it (see
  /// ``applyingOpenedSession(_:triggeringBundleID:to:)``), since opening a
  /// session is async I/O this pure function never performs.
  public static func applying(_ event: TriggerRuleEvent, to state: TriggerRuleRuntimeState)
    -> TriggerRuleRuntimeState
  {
    var next = state
    if case .processCountChanged(let bundleID, let count) = event {
      next.livePIDCounts[bundleID] = count
    }
    return next
  }

  /// Records a just-opened session's id and the bundle id that triggered it.
  public static func applyingOpenedSession(
    _ sessionID: String, triggeringBundleID: String, to state: TriggerRuleRuntimeState
  ) -> TriggerRuleRuntimeState {
    var next = state
    next.openSessionID = sessionID
    next.triggeringBundleID = triggeringBundleID
    return next
  }

  /// Clears a just-closed session's id and triggering bundle id.
  public static func applyingClosedSession(to state: TriggerRuleRuntimeState)
    -> TriggerRuleRuntimeState
  {
    var next = state
    next.openSessionID = nil
    next.triggeringBundleID = nil
    return next
  }
}
