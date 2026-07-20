/// Single-flight serialization for Apple Neural Engine / Core ML inference.
///
/// Per `docs/specs/model-interface.md`'s native FluidAudio backend
/// section: concurrent Core ML inference on the ANE crashes with **SIGBUS**
/// on macOS 14. Every ANE-bound inference call (model load, decode step, VAD
/// pass, ...) must be funneled through one shared gate so at most one call is
/// ever in flight, no matter how many callers arrive concurrently.
///
/// An actor's mailbox alone does **not** guarantee this: if the wrapped
/// operation itself suspends (every real Core ML call does — prediction is
/// asynchronous), Swift's actor reentrancy lets the actor start processing
/// the *next* queued call while the first is still suspended mid-flight,
/// so two operations' bodies could genuinely run concurrently. This type
/// avoids that by holding an explicit "is a call in flight" flag and an
/// explicit FIFO queue of waiters, so a second caller is suspended *before*
/// its operation ever starts, not merely queued as the next actor message.
public actor ANEInferenceGate {
  private var isHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init() {}

  /// Runs `operation` with the gate held, awaiting any earlier caller's
  /// operation to fully finish (return or throw) first, and releasing the
  /// gate for the next queued caller once `operation` completes.
  public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    await acquire()
    do {
      let result = try await operation()
      release()
      return result
    } catch {
      release()
      throw error
    }
  }

  /// Claims the gate, suspending until it is free. The fast (uncontended)
  /// path sets `isHeld` before any `await`, so — because actor methods run
  /// without interruption between suspension points — it can never race with
  /// another caller's fast path.
  private func acquire() async {
    if !isHeld {
      isHeld = true
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
    // `isHeld` is already `true` here — handed off by `release()`, which
    // deliberately does not clear it when passing the baton to a waiter.
  }

  /// Releases the gate: hands it directly to the oldest waiting caller
  /// (keeping `isHeld == true`), or clears `isHeld` when no one is waiting.
  private func release() {
    if waiters.isEmpty {
      isHeld = false
    } else {
      let next = waiters.removeFirst()
      next.resume()
    }
  }
}
