import Foundation

/// Pure parsing for a vocabulary list file (`docs/configuration.md`'s
/// `[vocab].global`, or a `cleanup --vocab <path>` extra list): one term per
/// line, blank lines and `#`-prefixed comment lines ignored.
public enum VocabFile {
  public static func parse(_ content: String) -> [String] {
    content
      .split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty && !$0.hasPrefix("#") }
  }
}
