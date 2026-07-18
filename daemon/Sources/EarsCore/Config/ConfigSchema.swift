/// A declared schema for a slice of the config tree — just the keys the caller
/// actually wants validated. `EarsCore` ships ``Phase0ConfigSchema`` for the
/// keys Phase 0 needs; later phases add their own slice (`[earsd]`,
/// `[transcribe]`, ...) as they implement that subsystem, rather than one
/// schema trying to describe the whole reference config up front.
public struct ConfigSchema: Sendable {
  /// A single declared field: its expected kind, and — for `.table` fields —
  /// the nested schema its contents are validated against.
  public struct Field: Sendable {
    public var type: ConfigValueKind
    public var children: ConfigSchema?
    /// For `.array` fields whose elements are themselves tables (e.g.
    /// `[[earsd.source]]`), the schema each element is validated against.
    /// `nil` for arrays of scalars, which are left unvalidated element-wise —
    /// only `type == .array` is checked for those.
    public var elementSchema: ConfigSchema?

    public init(
      type: ConfigValueKind,
      children: ConfigSchema? = nil,
      elementSchema: ConfigSchema? = nil
    ) {
      self.type = type
      self.children = children
      self.elementSchema = elementSchema
    }
  }

  /// Declared keys at this level of the tree, by name.
  public var fields: [String: Field]

  /// Keys at this level that belong to a schema slice not yet declared (e.g.
  /// `[earsd]` before Phase 0's caller implements that subsystem). Present in
  /// the tree but unvalidated: not type-checked, and not rejected as unknown.
  public var passthroughKeys: Set<String>

  public init(fields: [String: Field], passthroughKeys: Set<String> = []) {
    self.fields = fields
    self.passthroughKeys = passthroughKeys
  }

  /// Composes this schema with `other` at the same tree level: their declared
  /// fields are unioned (`other`'s field wins on a name collision) and their
  /// passthrough keys are unioned, minus any key now covered by a declared
  /// field in either schema. This is how a subsystem's own schema slice (e.g.
  /// ``EarsdConfigSchema``) is combined with the shared keys every tool needs
  /// (``Phase0ConfigSchema``) into one effective schema, without either slice
  /// needing to know about the other's fields up front.
  public func union(_ other: ConfigSchema) -> ConfigSchema {
    let mergedFields = fields.merging(other.fields) { _, new in new }
    let mergedPassthroughKeys =
      passthroughKeys
      .union(other.passthroughKeys)
      .subtracting(mergedFields.keys)
    return ConfigSchema(fields: mergedFields, passthroughKeys: mergedPassthroughKeys)
  }
}
