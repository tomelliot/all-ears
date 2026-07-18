/// Speech-activity classification of a span, mirroring the `vad` event's `state`
/// in `index.jsonl` (see `docs/data-formats.md`).
public enum VADState: String, Sendable, Hashable, Codable, CaseIterable {
  case speech
  case silence
}
