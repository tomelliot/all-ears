import EarsCore
import EarsIPC
import Foundation

/// Best-effort publisher of finalised segments onto the daemon's live feed
/// via the `segment.publish` control-socket command.
///
/// Best-effort is the contract (`docs/product/specs/transcribe.md`: the
/// socket is "notification only; the durable transcript is the on-disk
/// file"): every failure mode — no socket path resolved, daemon not
/// running, daemon restarted mid-run, command rejected — is logged (once
/// per outage, not per segment) and swallowed, never thrown, so a publish
/// problem can never abort the follow run or drop an on-disk write.
///
/// Owns its own dedicated request/response connection: `subscribe` is
/// terminal for a control-socket connection (see ``ControlSocketClient``),
/// so a publisher can never share a connection with anything that watches
/// the feed. The connection is dialled lazily on first publish and
/// re-dialled after a send failure, so a daemon that starts (or restarts)
/// mid-follow picks the stream back up.
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
    guard case .segment(let session, let speaker, let start, let end, let text) = event else {
      return
    }
    guard let socketPath else { return }

    if client == nil {
      client = try? await ControlSocketClient.connect(toPath: socketPath)
    }
    guard let client else {
      warnOnce(
        "daemon unreachable at \(socketPath); live-feed segment events are not being "
          + "published (the on-disk transcript is unaffected)")
      return
    }

    do {
      let response = try await client.send(
        .segmentPublish(session: session, speaker: speaker, start: start, end: end, text: text),
        expecting: EmptyData.self)
      if case .failure(let error) = response {
        log("segment.publish rejected by daemon: \(error.message)")
      }
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
