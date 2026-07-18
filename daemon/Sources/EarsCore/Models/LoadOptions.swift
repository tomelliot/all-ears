/// Options for loading a ``Transcriber`` backend's weights and selecting compute.
///
/// Corresponds to the `[transcribe]` selection config (`model`, `compute`) in the
/// model spec. `modelIdentifier` names the weights to load (a Hugging Face id, a
/// local path, or a backend-defined name); its interpretation is the backend's.
public struct LoadOptions: Sendable, Hashable, Codable {
  /// The model to load (Hugging Face id, path, or backend-defined name); `nil`
  /// uses the backend default.
  public var modelIdentifier: String?
  /// Preferred compute unit.
  public var compute: ComputePreference

  public init(modelIdentifier: String? = nil, compute: ComputePreference = .automatic) {
    self.modelIdentifier = modelIdentifier
    self.compute = compute
  }
}
