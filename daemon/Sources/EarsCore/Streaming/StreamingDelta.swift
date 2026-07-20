/// The append-only delta contract for streaming transcription output, per
/// `docs/specs/transcribe.md`'s "Append-only delta contract": output
/// safe for a **no-backspace sink** (a terminal, the socket's live feed, a
/// file being appended).
///
/// Invariants, in this type's terms:
///
/// - ``emitted`` is the cursor: it only ever grows. ``advance(_:)`` returns
///   the newly-safe suffix to emit; once returned, that text is never
///   retracted or edited. A hypothesis that *contradicts* already-emitted
///   text (doesn't extend it) emits nothing — the cursor never moves
///   backward, by construction.
/// - A **trailing incomplete unit is held back** until a later hypothesis
///   confirms it: the trailing run of non-whitespace characters (a possibly
///   partial token — including a trailing U+FFFD from a partial multibyte
///   decode, which is never whitespace) is not emitted until text with a
///   boundary *after* it arrives, so a consumer never sees a garbled or
///   half-decoded tail.
/// - ``finish()`` implements the end-of-stream half of two-pass
///   finalization's commit rule: the held-back tail is flushed as a final
///   commit — it is real decoded text that simply never got a following
///   boundary — **except** a trailing U+FFFD run, which is discarded: a
///   replacement character at end of stream can never be completed into a
///   valid unit, and emitting it would put the exact garbled tail the
///   contract exists to prevent onto every sink. (This is the "flush or
///   discard the held-back partial" decision `transcribe --follow` documents.)
///
/// Pure text bookkeeping — no I/O, no model, tier-0 tested per
/// `docs/engineering-practices.md`. The two-pass *re-decode* itself (cheap
/// partials, then one max-look-ahead decode of the committed text) is the
/// caller's pipeline; this type guarantees whatever stream of hypotheses that
/// pipeline produces reaches sinks append-only.
///
/// The unit of confirmation is deliberately *textual*: whitespace after a
/// token is what marks it complete. A caller that knows out-of-band that the
/// current tail is complete — e.g. `transcribe --follow` committing a window
/// that ended at a genuine VAD pause — expresses that by appending the
/// boundary whitespace to its hypothesis (`advance(hypothesis + " ")`): the
/// pause *is* a word boundary, rendered in the contract's own vocabulary
/// rather than through a side-channel flag this type would have to mirror.
public struct StreamingDelta: Sendable, Hashable {
  /// Everything emitted so far — the append-only cursor. Never shrinks.
  public private(set) var emitted: String = ""
  /// The trailing incomplete unit awaiting confirmation by a later
  /// hypothesis (or ``finish()``). Not yet visible to any sink.
  public private(set) var heldBack: String = ""

  public init() {}

  /// Feed the latest hypothesis — the full text decoded so far on this
  /// stream — and get back the delta that is newly safe to emit (possibly
  /// empty).
  ///
  /// A hypothesis that does not extend ``emitted`` (the model revised text
  /// that was already emitted) returns `""` and leaves the cursor and
  /// ``heldBack`` unchanged: emitted text is never retracted, and the
  /// previously held tail stays held until a hypothesis consistent with the
  /// cursor arrives.
  public mutating func advance(_ hypothesis: String) -> String {
    guard hypothesis.hasPrefix(emitted) else { return "" }
    let tail = String(hypothesis.dropFirst(emitted.count))
    let confirmed = Self.confirmedPrefix(of: tail)
    heldBack = String(tail.dropFirst(confirmed.count))
    guard !confirmed.isEmpty else { return "" }
    emitted += confirmed
    return confirmed
  }

  /// End of stream: flush the held-back tail as a final commit, discarding a
  /// trailing U+FFFD run (see the type doc for why flushed-vs-discarded
  /// splits exactly there). Returns the flushed text (possibly empty).
  public mutating func finish() -> String {
    var flushed = heldBack
    heldBack = ""
    while flushed.hasSuffix("\u{FFFD}") {
      flushed.removeLast()
    }
    guard !flushed.isEmpty else { return "" }
    emitted += flushed
    return flushed
  }

  /// The prefix of `tail` that is safe to emit now: everything up to and
  /// including the last whitespace character. The trailing non-whitespace
  /// run — a partial token, or a trailing U+FFFD (not whitespace) — is the
  /// incomplete unit held for the next hypothesis to confirm.
  private static func confirmedPrefix(of tail: String) -> String {
    var confirmed = tail
    while let last = confirmed.last, !last.isWhitespace {
      confirmed.removeLast()
    }
    return confirmed
  }
}
