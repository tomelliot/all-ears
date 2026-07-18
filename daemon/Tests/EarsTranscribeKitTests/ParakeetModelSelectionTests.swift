@preconcurrency import CoreML
import EarsCore
import FluidAudio
import Testing

@testable import EarsTranscribeKit

@Suite("resolveModelVersion(fromIdentifier:)")
struct ResolveModelVersionTests {
  @Test(
    "maps recognized identifiers to their FluidAudio model version",
    arguments: [
      ("parakeet-tdt-v2", AsrModelVersion.v2),
      ("v2", AsrModelVersion.v2),
      ("parakeet-tdt-v3", AsrModelVersion.v3),
      ("v3", AsrModelVersion.v3),
      ("parakeet-tdt-ctc-110m", AsrModelVersion.tdtCtc110m),
      ("tdt-ctc-110m", AsrModelVersion.tdtCtc110m),
      ("parakeet-tdt-ja", AsrModelVersion.tdtJa),
      ("ja", AsrModelVersion.tdtJa),
    ] as [(String, AsrModelVersion)]
  )
  func recognizedIdentifiers(identifier: String, expected: AsrModelVersion) {
    let resolved = resolveModelVersion(fromIdentifier: identifier)
    #expect(String(describing: resolved) == String(describing: expected))
  }

  @Test("nil identifier falls back to the multilingual v3 default")
  func nilFallsBackToV3() {
    #expect(
      String(describing: resolveModelVersion(fromIdentifier: nil))
        == String(describing: AsrModelVersion.v3))
  }

  @Test("an unrecognized identifier falls back to v3 rather than crashing")
  func unrecognizedFallsBackToV3() {
    #expect(
      String(describing: resolveModelVersion(fromIdentifier: "not-a-real-model"))
        == String(describing: AsrModelVersion.v3))
  }
}

@Suite("resolveComputeUnits(for:)")
struct ResolveComputeUnitsTests {
  @Test(
    "maps every ComputePreference to its Core ML compute-unit selector",
    arguments: [
      (ComputePreference.automatic, MLComputeUnits.all),
      (ComputePreference.neuralEngine, MLComputeUnits.cpuAndNeuralEngine),
      (ComputePreference.gpu, MLComputeUnits.cpuAndGPU),
      (ComputePreference.cpu, MLComputeUnits.cpuOnly),
    ]
  )
  func mapsEveryCase(preference: ComputePreference, expected: MLComputeUnits) {
    #expect(resolveComputeUnits(for: preference) == expected)
  }
}

@Suite("versionString(for:)")
struct VersionStringTests {
  @Test("every model version has a distinct, stable version string")
  func distinctAndStable() {
    let versions: [AsrModelVersion] = [.v2, .v3, .tdtCtc110m, .tdtJa]
    let strings = versions.map { versionString(for: $0) }
    #expect(Set(strings).count == strings.count)
  }
}
