import EarsCore

/// A ``PermissionProviding`` that returns a fixed status for every permission,
/// letting tests simulate granted or denied states deterministically. Defaults to
/// `.authorized`. Proves the seam is mockable; not shipped capability.
public struct NullPermissionProviding: PermissionProviding {
  public var fixedStatus: PermissionStatus

  public init(fixedStatus: PermissionStatus = .authorized) {
    self.fixedStatus = fixedStatus
  }

  public func status(for permission: Permission) async -> PermissionStatus {
    fixedStatus
  }

  public func request(_ permission: Permission) async -> PermissionStatus {
    fixedStatus
  }
}
