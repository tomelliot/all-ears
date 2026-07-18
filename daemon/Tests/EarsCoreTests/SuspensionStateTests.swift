import Testing

@testable import EarsCore

/// Covers ``SuspensionState``: `docs/specs/capture-daemon.md`'s "Power/idle
/// awareness" requirement that system sleep, display sleep, and screen lock
/// are independent suspension sources — waking from one while another is
/// still active must still report suspended.
@Suite("SuspensionState")
struct SuspensionStateTests {
  @Test("all flags false is not suspended")
  func allFalseNotSuspended() {
    let state = SuspensionState()
    #expect(!state.isSuspended)
    #expect(!state.isSystemAsleep)
    #expect(!state.isDisplayAsleep)
    #expect(!state.isScreenLocked)
  }

  @Test("system sleep alone causes suspension")
  func systemSleepSuspends() {
    let state = SuspensionState().withSystemAsleep(true)
    #expect(state.isSuspended)
  }

  @Test("display sleep alone causes suspension")
  func displaySleepSuspends() {
    let state = SuspensionState().withDisplayAsleep(true)
    #expect(state.isSuspended)
  }

  @Test("screen lock alone causes suspension")
  func screenLockSuspends() {
    let state = SuspensionState().withScreenLocked(true)
    #expect(state.isSuspended)
  }

  @Test("multiple active flags still just report suspended, not a count")
  func multipleFlagsStillJustSuspended() {
    let state = SuspensionState()
      .withSystemAsleep(true)
      .withDisplayAsleep(true)
      .withScreenLocked(true)
    #expect(state.isSuspended)
    #expect(state.isSystemAsleep)
    #expect(state.isDisplayAsleep)
    #expect(state.isScreenLocked)
  }

  @Test("wake-while-locked: clearing system sleep while the screen stays locked keeps it suspended")
  func wakeWhileLockedStaysSuspended() {
    let asleepAndLocked = SuspensionState()
      .withSystemAsleep(true)
      .withScreenLocked(true)
    #expect(asleepAndLocked.isSuspended)

    let wokenButStillLocked = asleepAndLocked.withSystemAsleep(false)
    #expect(!wokenButStillLocked.isSystemAsleep)
    #expect(wokenButStillLocked.isScreenLocked)
    #expect(wokenButStillLocked.isSuspended)
  }

  @Test("clearing every flag ends suspension")
  func clearingAllFlagsEndsSuspension() {
    let state = SuspensionState()
      .withSystemAsleep(true)
      .withDisplayAsleep(true)
      .withScreenLocked(true)
      .withSystemAsleep(false)
      .withDisplayAsleep(false)
      .withScreenLocked(false)
    #expect(!state.isSuspended)
  }

  @Test("updates are immutable: the original value is untouched by a with-update")
  func updatesAreImmutable() {
    let original = SuspensionState()
    let updated = original.withSystemAsleep(true)
    #expect(!original.isSuspended)
    #expect(updated.isSuspended)
  }
}
