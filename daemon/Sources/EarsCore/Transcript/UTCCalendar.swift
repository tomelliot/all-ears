/// Pure, `Foundation`-free UTC calendar formatting for ``Instant``.
///
/// `Instant` deliberately carries no formatting logic (see its doc comment);
/// other modules own the string conversion for their own on-disk formats. This
/// one is scoped to what transcript rendering needs: whole-second ISO-8601
/// UTC timestamps for frontmatter (`2026-07-17T10:30:00Z`) and `HH:MM:SS`
/// time-of-day for Markdown headings (`10:30:04`). Both use the same
/// epoch-seconds → civil calendar conversion (Howard Hinnant's
/// `civil_from_days` algorithm), which is exact integer math and needs no
/// `Foundation.Date`/`Calendar`.
///
/// `public` (the enum and ``timeOfDay(_:)``) so `transcribe --follow`'s
/// plain-stdout segment lines render the same `[HH:MM:SS]` prefix the
/// Markdown headings use, from the same calendar math.
public enum UTCCalendar {
  struct CivilTime {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
  }

  /// Decomposes an instant into its UTC calendar date and time-of-day,
  /// truncating towards the start of the second (fractional seconds dropped
  /// — transcript frontmatter and headings only need whole-second precision).
  static func civilTime(for instant: Instant) -> CivilTime {
    let totalSeconds = instant.secondsSinceEpoch.rounded(.down)
    let epochDay = Int((totalSeconds / 86400).rounded(.down))
    let secondOfDay = Int(totalSeconds - Double(epochDay) * 86400)

    let (year, month, day) = civilFromDays(epochDay)
    let hour = secondOfDay / 3600
    let minute = (secondOfDay % 3600) / 60
    let second = secondOfDay % 60

    return CivilTime(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
  }

  /// `YYYY-MM-DDTHH:MM:SSZ`.
  static func iso8601(_ instant: Instant) -> String {
    let c = civilTime(for: instant)
    return "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2))T"
      + "\(pad(c.hour, 2)):\(pad(c.minute, 2)):\(pad(c.second, 2))Z"
  }

  /// `HH:MM:SS`.
  public static func timeOfDay(_ instant: Instant) -> String {
    let c = civilTime(for: instant)
    return "\(pad(c.hour, 2)):\(pad(c.minute, 2)):\(pad(c.second, 2))"
  }

  private static func pad(_ value: Int, _ width: Int) -> String {
    let digits = String(value)
    guard digits.count < width else { return digits }
    return String(repeating: "0", count: width - digits.count) + digits
  }

  /// Howard Hinnant's `civil_from_days`: converts a day count since the Unix
  /// epoch (1970-01-01) into a proleptic Gregorian (year, month, day).
  /// Exact for all `Int`-representable day counts, including before 1970.
  private static func civilFromDays(_ z: Int) -> (year: Int, month: Int, day: Int) {
    let shifted = z + 719_468
    let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097  // [0, 146096]
    let yearOfEra =
      (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365  // [0, 399]
    let year = yearOfEra + era * 400
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)  // [0, 365]
    let monthPrime = (5 * dayOfYear + 2) / 153  // [0, 11]
    let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1  // [1, 31]
    let month = monthPrime + (monthPrime < 10 ? 3 : -9)  // [1, 12]
    return (year + (month <= 2 ? 1 : 0), month, day)
  }
}
