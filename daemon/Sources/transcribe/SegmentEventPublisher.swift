import EarsCore
import EarsIPC
import Foundation

/// Best-effort publisher of finalised segments onto the daemon's live feed
/// via the v2 `segment.publish` method.
///
/// Best-effort is the contract (`docs/product/specs/transcribe.md`: the
/// socket is "notification only; the durable transcript is the on-disk
/// file"): every failure mode — no socket path resolved, daemon not
/// running, daemon restarted mid-run, command rejected — is logged (once
/// per outage, not per segment) and swallowed, never thrown, so a publish
/// problem can never abort the follow run or drop an on-disk write.
///
/// Owns its own request/response connection, dialled (and `hello`'d) lazily
/// on first publish and re-dialled after a send failure, so a daemon that
/// starts (or restarts) mid-follow picks the stream back up.
actor SegmentEventPublisher {
  private let socketPath: String?
  private let log: @Sendable (String) -> Void
  private var client: ControlSocketClient?
  private var warnedThisOutage = false

  /// - Parameters:
  ///   - socketPath: The daemon's control socket, or `nil` when none could
  ///     be resolved from config — publishing is then disabled (logged once
  ///     at construction by the caller, not per segment).
  ///   - log: Non-fatal notice sink (the pipeline's `log`).
  init(socketPath: String?, log: @escaping @Sendable (String) -> Void) {
    self.socketPath = socketPath
    self.log = log
  }

  /// Publishes one `segment` event; any non-`segment` event is ignored (the
  /// publisher exists for exactly this event kind).
  func publish(_ event: EarsEvent) async {
    guard case .segment(let params) = event else {
      return
    }
    guard let socketPath else { return }

    if client == nil {
      if let dialled = try? await ControlSocketClient.connect(toPath: socketPath) {
        do {
          try await dialled.hello(client: "transcribe/0.1.0")
          client = dialled
        } catch {
          await dialled.close()
        }
      }
    }
    guard let client else {
      warnOnce(
        "daemon unreachable at \(socketPath); live-feed segment events are not being "
          + "published (the on-disk transcript is unaffected)")
      return
    }

    do {
      _ = try await client.send(.segmentPublish(params), expecting: EmptyData.self)
      warnedThisOutage = false
    } catch let error as WireError {
      // The daemon answered but refused — the connection is fine.
      log("segment.publish rejected by daemon: [\(error.code.rawValue)] \(error.message)")
      warnedThisOutage = false
    } catch {
      warnOnce("segment.publish failed (\(error)); will retry the connection on the next segment")
      await client.close()
      self.client = nil
    }
  }

  /// Closes the connection, if one was ever dialled.
  func shutdown() async {
    await client?.close()
    client = nil
  }

  private func warnOnce(_ message: String) {
    guard !warnedThisOutage else { return }
    warnedThisOutage = true
    log(message)
  }
}
