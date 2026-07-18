// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AllEars",
  platforms: [
    .macOS(.v15)
  ],
  products: [
    .library(name: "EarsCore", targets: ["EarsCore"]),
    .library(name: "EarsConfig", targets: ["EarsConfig"]),
    .library(name: "EarsLogging", targets: ["EarsLogging"]),
    .executable(name: "earsd", targets: ["earsd"]),
    .executable(name: "ears", targets: ["ears"]),
    .executable(name: "transcribe", targets: ["transcribe"]),
    .executable(name: "cleanup", targets: ["cleanup"]),
    .executable(name: "summarize", targets: ["summarize"]),
  ],
  dependencies: [
    .package(url: "https://github.com/LebJe/TOMLKit", exact: "0.6.0"),
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2"),
    // Native Parakeet/ASR backend (`docs/product/specs/model-interface.md`'s
    // "Backend 1 -- native"): Core ML/ANE inference via FluidAudio.
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
  ],
  targets: [
    // MARK: - Libraries

    .target(
      name: "EarsCore"
    ),
    .target(
      name: "EarsConfig",
      dependencies: [
        "EarsCore",
        .product(name: "TOMLKit", package: "TOMLKit"),
      ]
    ),
    .target(
      name: "EarsLogging",
      dependencies: [
        "EarsCore"
      ],
      exclude: ["README.md"]
    ),

    // Shared bootstrap glue for the five executable stubs: config
    // discovery (`--print-config`/`--config-path`), config loading, and
    // the day-one logging requirements (bootstrap a `LogSink`, log
    // startup, log `run.summary`). Every executable currently needs the
    // exact same sequence (see `docs/logging.md`/`docs/configuration.md`),
    // so it lives here once rather than duplicated five times. This is
    // tier-2/3 I/O glue per `docs/engineering-practices.md` (real clock,
    // environment, filesystem) — exercised end-to-end by `CLISmokeTests`
    // rather than a dedicated unit-test target; the pure decisions it
    // delegates to (`loadConfig`, `configLayer(fromCLIFlags:)`,
    // `DefaultLogFilePath`, `LogLevel` ordering) are unit-tested where
    // they're defined.
    .target(
      name: "EarsCLISupport",
      dependencies: [
        "EarsCore",
        "EarsConfig",
        "EarsLogging",
      ]
    ),

    // Unix-domain-socket transport (client + server) between `ears` and
    // `earsd`, per `docs/architecture.md`'s control-socket design.
    .target(
      name: "EarsIPC",
      dependencies: [
        "EarsCore"
      ]
    ),

    // Core Audio / `AVAudioEngine` capture shim: adapts the microphone to
    // `EarsCore`'s `CaptureBackend` protocol seam.
    .target(
      name: "EarsCaptureKit",
      dependencies: [
        "EarsCore"
      ]
    ),

    // Dual-rate chunk encoding, atomic writes, and index/session persistence
    // for captured audio, per `docs/roadmap.md`'s Phase 1 design.
    .target(
      name: "EarsDataStore",
      dependencies: [
        "EarsCore",
        "EarsConfig",
      ]
    ),

    // `earsd`'s real orchestration (`CaptureActor`, `ControlServer`,
    // `SessionStore`, per `docs/architecture.md`), kept as a library --
    // not inside the `earsd` executable target -- specifically so it is
    // `@testable import`-able without spawning a process, matching how
    // `EarsCLISupport` already keeps business logic out of the executable
    // targets.
    .target(
      name: "EarsDaemonKit",
      dependencies: [
        "EarsCore",
        "EarsConfig",
        "EarsLogging",
        "EarsIPC",
        "EarsCaptureKit",
        "EarsDataStore",
      ]
    ),

    // Test-support only: fakes and null conformances that prove the EarsCore
    // seams are mockable and unblock other targets' tests. Deliberately kept
    // out of the shipped EarsCore API surface (not a package product), so it
    // is a plain target consumed by test targets rather than production code.
    .target(
      name: "EarsCoreTestSupport",
      dependencies: [
        "EarsCore"
      ]
    ),

    // MARK: - Executables

    .executableTarget(
      name: "earsd",
      dependencies: [
        "EarsCore",
        "EarsConfig",
        "EarsLogging",
        "EarsCLISupport",
        "EarsDaemonKit",
        // For the real, mic-only `CaptureBackendFactory` the normal-run
        // path wires into `EarsDaemon` (`MicCaptureBackend`/
        // `RealMicSourceProvider`) — was missing before this target had
        // any real daemon-composition code of its own to need it.
        "EarsCaptureKit",
        // For `RealCaptureBackendFactory`'s `EARS_CAPTURE_BACKEND=synthetic`
        // test-only escape hatch (`SyntheticCaptureBackend`) — gated behind
        // an env var `earsd`'s own normal invocation never sets; see that
        // file's doc comment. `EarsCoreTestSupport` is deliberately a plain
        // library target ("for any target to reuse", per its own doc
        // comment), not a test target, so this is an ordinary dependency,
        // not a test-only one.
        "EarsCoreTestSupport",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "ears",
      dependencies: [
        "EarsCore",
        "EarsConfig",
        "EarsLogging",
        "EarsCLISupport",
        "EarsIPC",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "transcribe",
      dependencies: [
        "EarsCore",
        "EarsConfig",
        "EarsLogging",
        "EarsCLISupport",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "cleanup",
      dependencies: [
        "EarsCore",
        "EarsConfig",
        "EarsLogging",
        "EarsCLISupport",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .executableTarget(
      name: "summarize",
      dependencies: [
        "EarsCore",
        "EarsConfig",
        "EarsLogging",
        "EarsCLISupport",
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),

    // MARK: - Tests

    .testTarget(
      name: "EarsCoreTests",
      dependencies: ["EarsCore", "EarsCoreTestSupport"]
    ),
    .testTarget(
      name: "EarsConfigTests",
      dependencies: ["EarsConfig"]
    ),
    .testTarget(
      name: "EarsLoggingTests",
      dependencies: ["EarsLogging"]
    ),
    .testTarget(
      name: "EarsCoreIntegrationTests",
      dependencies: ["EarsCore"]
    ),
    // Depends on the `earsd`/`ears` executable targets (not just
    // `EarsCore`) so the pure decision logic each factors out of `main` --
    // config -> `EarsDaemonConfiguration` resolution, non-mic-source
    // skipping, duration parsing, output formatting -- is directly
    // unit-testable via `@testable import earsd`/`@testable import ears`,
    // alongside the existing process-spawn smoke tests in this same
    // target. Was missing before either executable had real decision
    // logic worth unit testing in isolation.
    .testTarget(
      name: "CLISmokeTests",
      dependencies: ["EarsCore", "earsd", "ears"]
    ),
    .testTarget(
      name: "EarsIPCTests",
      dependencies: ["EarsIPC", "EarsCoreTestSupport"]
    ),
    .testTarget(
      name: "EarsCaptureKitTests",
      dependencies: ["EarsCaptureKit", "EarsCoreTestSupport"]
    ),
    .testTarget(
      name: "EarsDataStoreTests",
      dependencies: ["EarsDataStore", "EarsCoreTestSupport"]
    ),
    .testTarget(
      name: "EarsDaemonKitTests",
      dependencies: ["EarsDaemonKit", "EarsCoreTestSupport"]
    ),
  ]
)
