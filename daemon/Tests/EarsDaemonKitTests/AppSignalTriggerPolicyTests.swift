import Testing

@testable import EarsDaemonKit

@Suite("AppSignalTriggerPolicy")
struct AppSignalTriggerPolicyTests {
  @Test("audioActive with no live processes recorded is ignored (stale/out-of-order signal)")
  func audioActiveWithNoLiveProcessesIsIgnored() {
    let state = TriggerRuleRuntimeState(livePIDCounts: ["us.zoom.xos": 0])
    let decision = AppSignalTriggerPolicy.decision(
      for: state, event: .audioActive(bundleID: "us.zoom.xos"))
    #expect(decision == .none)
  }

  @Test("audioActive with a live process opens a session")
  func audioActiveWithLiveProcessOpensSession() {
    let state = TriggerRuleRuntimeState(livePIDCounts: ["us.zoom.xos": 1])
    let decision = AppSignalTriggerPolicy.decision(
      for: state, event: .audioActive(bundleID: "us.zoom.xos"))
    #expect(decision == .openSession)
  }

  @Test("audioActive while a session is already open is a no-op")
  func audioActiveWhileAlreadyOpenIsNoOp() {
    let state = TriggerRuleRuntimeState(
      openSessionID: "existing-session", triggeringBundleID: "us.zoom.xos",
      livePIDCounts: ["us.zoom.xos": 1])
    let decision = AppSignalTriggerPolicy.decision(
      for: state, event: .audioActive(bundleID: "us.zoom.xos"))
    #expect(decision == .none)
  }

  @Test("processCountChanged to zero for the triggering bundle id closes the session")
  func processCountToZeroForTriggeringBundleIDCloses() {
    let state = TriggerRuleRuntimeState(
      openSessionID: "session-1", triggeringBundleID: "us.zoom.xos",
      livePIDCounts: ["us.zoom.xos": 1])
    let decision = AppSignalTriggerPolicy.decision(
      for: state, event: .processCountChanged(bundleID: "us.zoom.xos", count: 0))
    #expect(decision == .closeSession(sessionID: "session-1"))
  }

  @Test("processCountChanged to zero for a non-triggering bundle id in the same rule is a no-op")
  func processCountToZeroForOtherBundleIDIsNoOp() {
    // e.g. a rule watching both us.zoom.xos and com.microsoft.teams2 --
    // teams exiting shouldn't close a session that zoom's audio opened.
    let state = TriggerRuleRuntimeState(
      openSessionID: "session-1", triggeringBundleID: "us.zoom.xos",
      livePIDCounts: ["us.zoom.xos": 1, "com.microsoft.teams2": 1])
    let decision = AppSignalTriggerPolicy.decision(
      for: state, event: .processCountChanged(bundleID: "com.microsoft.teams2", count: 0))
    #expect(decision == .none)
  }

  @Test("processCountChanged to zero with no session open is a no-op")
  func processCountToZeroWithNoSessionOpenIsNoOp() {
    let state = TriggerRuleRuntimeState(livePIDCounts: ["us.zoom.xos": 1])
    let decision = AppSignalTriggerPolicy.decision(
      for: state, event: .processCountChanged(bundleID: "us.zoom.xos", count: 0))
    #expect(decision == .none)
  }

  @Test("processCountChanged to a non-zero count never closes")
  func processCountToNonZeroNeverCloses() {
    let state = TriggerRuleRuntimeState(
      openSessionID: "session-1", triggeringBundleID: "us.zoom.xos",
      livePIDCounts: ["us.zoom.xos": 1])
    let decision = AppSignalTriggerPolicy.decision(
      for: state, event: .processCountChanged(bundleID: "us.zoom.xos", count: 2))
    #expect(decision == .none)
  }

  @Test("applying(_:to:) updates the live PID count and nothing else")
  func applyingUpdatesLivePIDCount() {
    let state = TriggerRuleRuntimeState(livePIDCounts: ["us.zoom.xos": 1])
    let next = AppSignalTriggerPolicy.applying(
      .processCountChanged(bundleID: "us.zoom.xos", count: 3), to: state)
    #expect(next.livePIDCounts["us.zoom.xos"] == 3)
    #expect(next.openSessionID == nil)
  }

  @Test("applying(_:to:) for audioActive doesn't mutate state (session id applied separately)")
  func applyingAudioActiveIsNoOp() {
    let state = TriggerRuleRuntimeState(livePIDCounts: ["us.zoom.xos": 1])
    let next = AppSignalTriggerPolicy.applying(.audioActive(bundleID: "us.zoom.xos"), to: state)
    #expect(next == state)
  }

  @Test("applyingOpenedSession records the session id and triggering bundle id")
  func applyingOpenedSessionRecords() {
    let state = TriggerRuleRuntimeState(livePIDCounts: ["us.zoom.xos": 1])
    let next = AppSignalTriggerPolicy.applyingOpenedSession(
      "session-42", triggeringBundleID: "us.zoom.xos", to: state)
    #expect(next.openSessionID == "session-42")
    #expect(next.triggeringBundleID == "us.zoom.xos")
  }

  @Test("applyingClosedSession clears the session id and triggering bundle id")
  func applyingClosedSessionClears() {
    let state = TriggerRuleRuntimeState(
      openSessionID: "session-42", triggeringBundleID: "us.zoom.xos",
      livePIDCounts: ["us.zoom.xos": 1])
    let next = AppSignalTriggerPolicy.applyingClosedSession(to: state)
    #expect(next.openSessionID == nil)
    #expect(next.triggeringBundleID == nil)
    #expect(next.livePIDCounts["us.zoom.xos"] == 1)  // untouched
  }

  @Test("a full open-then-close cycle via the pure core end to end")
  func fullOpenCloseCycle() {
    var state = TriggerRuleRuntimeState()
    state = AppSignalTriggerPolicy.applying(
      .processCountChanged(bundleID: "us.zoom.xos", count: 1), to: state)
    #expect(
      AppSignalTriggerPolicy.decision(for: state, event: .audioActive(bundleID: "us.zoom.xos"))
        == .openSession)
    state = AppSignalTriggerPolicy.applyingOpenedSession(
      "session-1", triggeringBundleID: "us.zoom.xos", to: state)

    // A second audio-active signal while open is a no-op.
    #expect(
      AppSignalTriggerPolicy.decision(for: state, event: .audioActive(bundleID: "us.zoom.xos"))
        == .none)

    state = AppSignalTriggerPolicy.applying(
      .processCountChanged(bundleID: "us.zoom.xos", count: 0), to: state)
    #expect(
      AppSignalTriggerPolicy.decision(
        for: state, event: .processCountChanged(bundleID: "us.zoom.xos", count: 0))
        == .closeSession(sessionID: "session-1"))
    state = AppSignalTriggerPolicy.applyingClosedSession(to: state)
    #expect(state.openSessionID == nil)
  }
}
