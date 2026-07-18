/// Preferred compute unit for loading a model, mapped by the shim to the
/// backend's own selector (e.g. Core ML's `MLComputeUnits`).
///
/// Kept backend-agnostic so pure code and config can express intent without
/// linking Core ML. The daemon deliberately runs the VAD on ``cpu`` to avoid
/// ANE contention with the ASR model during live work (see the model spec).
public enum ComputePreference: String, Sendable, Hashable, Codable, CaseIterable {
  /// Let the backend choose the best available unit.
  case automatic
  /// Prefer the Apple Neural Engine.
  case neuralEngine
  /// Prefer the GPU / Metal.
  case gpu
  /// Force CPU-only execution.
  case cpu
}
