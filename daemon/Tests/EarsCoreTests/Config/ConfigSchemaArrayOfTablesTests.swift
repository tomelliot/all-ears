import Testing

@testable import EarsCore

/// Exercises the array-of-tables schema extension (`ConfigSchema.Field.elementSchema`)
/// in isolation, with a small hand-built schema — not `EarsdConfigSchema` — so this
/// suite covers the generic engine capability independent of any one caller's shape.
/// Mirrors the `[[earsd.source]]` case from `docs/configuration.md`: a top-level table
/// with an array-valued key whose elements are themselves validated against a nested
/// schema.
@Suite("Array-of-tables schema validation")
struct ConfigSchemaArrayOfTablesTests {
  /// A schema for `{ items: [{ id: String, count: Int }] }`, standing in for
  /// `[[earsd.source]]`'s shape without depending on `EarsdConfigSchema`.
  static let schema = ConfigSchema(
    fields: [
      "items": ConfigSchema.Field(
        type: .array,
        elementSchema: ConfigSchema(
          fields: [
            "id": ConfigSchema.Field(type: .string),
            "count": ConfigSchema.Field(type: .int),
          ]
        )
      )
    ]
  )

  @Test("a valid list of table elements validates cleanly")
  func validListValidates() {
    let value: ConfigValue = .table([
      "items": .array([
        .table(["id": .string("a"), "count": .int(1)]),
        .table(["id": .string("b"), "count": .int(2)]),
      ])
    ])

    let errors = validateConfig(value, against: Self.schema)
    #expect(errors.isEmpty)
  }

  @Test("an unknown key inside an element is reported with a precise indexed key path")
  func unknownKeyInElement() {
    let value: ConfigValue = .table([
      "items": .array([
        .table(["id": .string("a"), "count": .int(1)]),
        .table(["id": .string("b"), "count": .int(2), "bogus": .bool(true)]),
      ])
    ])

    let errors = validateConfig(value, against: Self.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPath == ["items[1]", "bogus"])
    #expect(errors.first?.keyPathString == "items[1].bogus")
    #expect(errors.first?.reason == .unknownKey)
  }

  @Test("a type mismatch inside an element is reported with a precise indexed key path")
  func typeMismatchInElement() {
    let value: ConfigValue = .table([
      "items": .array([
        .table(["id": .string("a"), "count": .int(1)]),
        .table(["id": .string("b"), "count": .string("two")]),
      ])
    ])

    let errors = validateConfig(value, against: Self.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "items[1].count")
    #expect(errors.first?.reason == .typeMismatch(expected: .int, got: .string))
  }

  @Test("an element that isn't a table at all is itself a type mismatch")
  func nonTableElement() {
    let value: ConfigValue = .table([
      "items": .array([
        .table(["id": .string("a"), "count": .int(1)]),
        .string("not a table"),
      ])
    ])

    let errors = validateConfig(value, against: Self.schema)
    #expect(errors.count == 1)
    #expect(errors.first?.keyPathString == "items[1]")
    #expect(errors.first?.reason == .typeMismatch(expected: .table, got: .string))
  }

  @Test("an empty array validates cleanly")
  func emptyArrayValidates() {
    let value: ConfigValue = .table(["items": .array([])])
    let errors = validateConfig(value, against: Self.schema)
    #expect(errors.isEmpty)
  }

  @Test("errors across multiple elements are all collected, sorted by key path")
  func multipleElementErrorsCollected() {
    let value: ConfigValue = .table([
      "items": .array([
        .table(["id": .int(1), "count": .int(1)]),
        .table(["id": .string("b"), "count": .string("nope")]),
      ])
    ])

    let errors = validateConfig(value, against: Self.schema)
    #expect(errors.map(\.keyPathString) == ["items[0].id", "items[1].count"])
  }

  @Test("a nested schema with no elementSchema behaves exactly as before (arrays untouched)")
  func plainArrayFieldWithoutElementSchemaIsUnaffected() {
    let schema = ConfigSchema(
      fields: ["tags": ConfigSchema.Field(type: .array)]
    )
    let value: ConfigValue = .table(["tags": .array([.string("a"), .int(1), .bool(true)])])
    let errors = validateConfig(value, against: schema)
    #expect(errors.isEmpty)
  }
}
