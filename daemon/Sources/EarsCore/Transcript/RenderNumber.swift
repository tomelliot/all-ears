/// Deterministic `Double` → `String` rendering shared by the YAML frontmatter
/// and JSON sidecar emitters.
///
/// Whole numbers render without a decimal point (`1920`, not `1920.0`) to
/// match `docs/data-formats.md`'s frontmatter example (`duration_seconds:
/// 1920`). Fractional values use Swift's built-in `Double.description`, which
/// already produces the shortest string that round-trips back to the same
/// `Double` (e.g. `604.14`), matching the sidecar example (`"start": 604.14`).
enum RenderNumber {
  static func string(_ value: Double) -> String {
    guard value.isFinite else { return "0" }
    if value == value.rounded(), abs(value) < 1e15 {
      return String(Int64(value))
    }
    return value.description
  }
}
