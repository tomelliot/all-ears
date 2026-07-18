@preconcurrency import CoreML
import EarsCore
import FluidAudio

/// Pure mapping from `LoadOptions.modelIdentifier` to a FluidAudio
/// `AsrModelVersion`, factored out so it is unit-testable without touching
/// Core ML or any real model (tier-0/1 per
/// `docs/engineering-practices.md`). `nil` and unrecognized identifiers fall
/// back to `.v3` (multilingual, the FluidAudio-recommended default).
func resolveModelVersion(fromIdentifier identifier: String?) -> AsrModelVersion {
  switch identifier {
  case "parakeet-tdt-v2", "v2": return .v2
  case "parakeet-tdt-v3", "v3", nil: return .v3
  case "parakeet-tdt-ctc-110m", "tdt-ctc-110m": return .tdtCtc110m
  case "parakeet-tdt-ja", "ja": return .tdtJa
  default: return .v3
  }
}

/// Pure mapping from the backend-agnostic `ComputePreference` (see
/// `docs/product/specs/model-interface.md`) to Core ML's own
/// `MLComputeUnits` selector, factored out for the same reason as
/// ``resolveModelVersion(fromIdentifier:)``.
func resolveComputeUnits(for preference: ComputePreference) -> MLComputeUnits {
  switch preference {
  case .automatic: return .all
  case .neuralEngine: return .cpuAndNeuralEngine
  case .gpu: return .cpuAndGPU
  case .cpu: return .cpuOnly
  }
}

/// A stable, human-readable version string for `ModelInfo.version`.
func versionString(for version: AsrModelVersion) -> String {
  switch version {
  case .v2: return "parakeet-tdt-0.6b-v2"
  case .v3: return "parakeet-tdt-0.6b-v3"
  case .tdtCtc110m: return "parakeet-tdt-ctc-110m"
  case .tdtJa: return "parakeet-tdt-0.6b-ja"
  }
}
