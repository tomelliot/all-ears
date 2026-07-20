import EarsCore
import EarsIPC
import Foundation

/// Best-effort publisher of `job.publish` progress for a meeting-level
/// transcribe run — the same notification-only pattern as
/// ``SegmentEventPublisher``: the daemon persists nothing, subscribers get
/// real pipeline state instead of guessing, and every failure mode is
/// logged and swallowed so a publish problem can never fail the run.
actor JobEventPublisher {
  private let socketPath: String?
  private let jobID: String
  private let meetingID: String
  private let log: @Sendable (String) -> Void
  private var client: ControlSocketClient?

  init(
    socketPath: String?, jobID: String, meetingID: String,
    log: @escaping @Sendable (String) -> Void
  ) {
    self.socketPath = socketPath
    self.jobID = jobID
    self.meetingID = meetingID
    self.log = log
  }

  func publish(state: JobState, detail: String? = nil) async {
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
    guard let client else { return }
    do {
      _ = try await client.send(
        .jobPublish(
          JobPublishParams(
            job: jobID, kind: "transcribe", meeting: meetingID, state: state, detail: detail)),
        expecting: EmptyData.self)
    } catch {
      log("job.publish(\(state.rawValue)) failed: \(error) — continuing without progress events")
      await client.close()
      self.client = nil
    }
  }

  func shutdown() async {
    await client?.close()
    client = nil
  }
}
