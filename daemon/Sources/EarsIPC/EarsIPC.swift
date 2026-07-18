/// Unix-domain-socket transport between the `ears` CLI and the `earsd` daemon,
/// per `docs/architecture.md`'s control-socket design.
///
/// The transport is the ``SocketListener``/``SocketConnection`` seam with a
/// real Network.framework conformance (``NetworkSocketListener``,
/// ``NetworkSocketConnection``), the ``ControlSocketServer`` that frames,
/// dispatches, and fans events out under backpressure, and the
/// ``ControlSocketClient`` that drives it. This namespace carries only the
/// module version.
public enum EarsIPC {
  /// Version of the `EarsIPC` module.
  public static let version = "0.1.0"
}
