import EarsCore

/// Seam for `earsd`'s `hard_total_cap_bytes` backstop (`docs/configuration.md`'s
/// `[earsd]` table: "0 => unlimited backstop; else evict to stay under"), and
/// `docs/specs/capture-daemon.md`'s "Ring buffer maintenance": "If
/// `hard_total_cap_bytes > 0`, evict oldest across sources until under
/// budget."
///
/// Enforcing this for real means comparing on-disk bytes *across every
/// source* and evicting from whichever is most over budget -- genuine
/// cross-source coordination. With a single enabled source there is
/// nothing to coordinate across; building
/// real cross-source accounting now would be unused, untestable-against-
/// reality code (there's no second source to prove it works against).
///
/// This is a safe no-op: the config key parses and is accepted
/// (``EarsdConfigSchema`` already declares it), and a caller can wire this
/// function into its eviction loop today without changing behaviour, but it
/// never evicts anything. Phase 4 (multi-source) replaces the body with
/// real cross-source total-size accounting without changing the call site
/// or this function's signature.
public enum HardTotalCapEnforcement {
  /// - Parameters:
  ///   - hardTotalCapBytes: `earsd`'s `hard_total_cap_bytes` config value;
  ///     `0` means unlimited, per `docs/configuration.md`.
  ///   - sources: Every currently-enabled source's id, for the future
  ///     cross-source comparison this seam exists to be extended into.
  /// - Returns: Always empty in Phase 1.
  public static func chunksToEvict(
    hardTotalCapBytes: Int,
    sources: [SourceID]
  ) -> [IndexedChunk] {
    // Phase 4: implement real cross-source total-size accounting and
    // eviction here once more than one source class is in scope.
    []
  }
}
