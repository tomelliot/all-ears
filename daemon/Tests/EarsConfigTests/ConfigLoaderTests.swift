import Foundation
import Testing

@testable import EarsConfig
@testable import EarsCore

/// A temp directory that cleans itself up when the test struct is torn down.
/// `EarsConfigTests` are tier-1 (fixtures on disk, no daemon) per
/// `docs/engineering-practices.md`; this is the fixture.
private final class TempDirectory {
  let url: URL

  init() {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("EarsConfigTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func write(_ contents: String, named name: String) -> String {
    let fileURL = url.appendingPathComponent(name)
    try? contents.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL.path
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }
}

@Suite("loadConfig")
struct ConfigLoaderTests {
  @Test("with no config file present, loading succeeds with the built-in defaults, path-expanded")
  func zeroConfigUsesDefaults() {
    let temp = TempDirectory()
    let inputs = ConfigLoadInputs(
      configFlag: temp.url.appendingPathComponent("does-not-exist.toml").path,
      environment: [:],
      homeDirectory: "/Users/tom"
    )

    switch loadConfig(inputs) {
    case .success(let loaded):
      #expect(
        loaded.value
          == .table([
            "data_root": .string("/Users/tom/Library/Application Support/ears"),
            "output_root": .string("/Users/tom/Documents/Transcripts"),
            "socket_path": .string(""),
            "log": .table([
              "level": .string("info"),
              "file": .string(""),
              "format": .string("auto"),
              "oslog": .bool(true),
              "subsystem": .string("net.tomelliot.ears"),
              "rotate_max_bytes": .int(52_428_800),
              "rotate_max_files": .int(5),
            ]),
          ])
      )
    case .failure(let error):
      Issue.record("expected success, got \(error)")
    }
  }

  @Test(
    "a config file layer overrides defaults, and env overrides the file, and flags override env")
  func fullLayeringPrecedence() {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      data_root = "/from-file/data"

      [log]
      level = "debug"
      format = "json"
      """,
      named: "config.toml"
    )

    let inputs = ConfigLoadInputs(
      configFlag: configPath,
      environment: ["EARS_LOG__LEVEL": "notice"],
      homeDirectory: "/Users/tom",
      flags: .table(["log": .table(["format": .string("pretty")])])
    )

    switch loadConfig(inputs) {
    case .success(let loaded):
      guard case .table(let root) = loaded.value else {
        Issue.record("expected a table root")
        return
      }
      // From the file layer, untouched by env/flags.
      #expect(root["data_root"] == .string("/from-file/data"))
      guard case .table(let log)? = root["log"] else {
        Issue.record("expected a [log] table")
        return
      }
      // env overrides the file's "debug".
      #expect(log["level"] == .string("notice"))
      // flags override the file's "json".
      #expect(log["format"] == .string("pretty"))
      // untouched by any override layer, falls through to the default.
      #expect(log["oslog"] == .bool(true))
    case .failure(let error):
      Issue.record("expected success, got \(error)")
    }
  }

  @Test("an invalid TOML file surfaces as a tomlParseFailed error")
  func invalidTOMLFails() {
    let temp = TempDirectory()
    let configPath = temp.write("this is not = = valid toml [[[", named: "broken.toml")

    let inputs = ConfigLoadInputs(configFlag: configPath, homeDirectory: "/Users/tom")

    switch loadConfig(inputs) {
    case .success:
      Issue.record("expected a TOML parse failure")
    case .failure(let error):
      guard case .tomlParseFailed(let path, _) = error else {
        Issue.record("expected .tomlParseFailed, got \(error)")
        return
      }
      #expect(path == configPath)
    }
  }

  @Test("an unknown key in the config file surfaces as a validation error with its key path")
  func unknownKeyFailsValidation() {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      bogus_top_level_key = "nope"
      """,
      named: "config.toml"
    )

    let inputs = ConfigLoadInputs(configFlag: configPath, homeDirectory: "/Users/tom")

    switch loadConfig(inputs) {
    case .success:
      Issue.record("expected a validation failure")
    case .failure(let error):
      guard case .validation(let errors) = error else {
        Issue.record("expected .validation, got \(error)")
        return
      }
      #expect(errors.count == 1)
      #expect(errors.first?.keyPathString == "bogus_top_level_key")
      #expect(errors.first?.reason == .unknownKey)
    }
  }

  @Test("a type mismatch in the config file surfaces as a validation error with a precise message")
  func typeMismatchFailsValidation() {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      [log]
      level = 42
      """,
      named: "config.toml"
    )

    let inputs = ConfigLoadInputs(configFlag: configPath, homeDirectory: "/Users/tom")

    switch loadConfig(inputs) {
    case .success:
      Issue.record("expected a validation failure")
    case .failure(let error):
      guard case .validation(let errors) = error else {
        Issue.record("expected .validation, got \(error)")
        return
      }
      #expect(errors.first?.message == "log.level: expected string, got integer")
    }
  }

  @Test(
    "keys from not-yet-implemented sections in the file pass through without failing validation")
  func passthroughSectionsDoNotFailValidation() {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      [earsd]
      chunk_seconds = 30
      codec = "aac"
      """,
      named: "config.toml"
    )

    let inputs = ConfigLoadInputs(configFlag: configPath, homeDirectory: "/Users/tom")

    switch loadConfig(inputs) {
    case .success(let loaded):
      guard case .table(let root) = loaded.value else {
        Issue.record("expected a table root")
        return
      }
      #expect(
        root["earsd"]
          == .table([
            "chunk_seconds": .int(30),
            "codec": .string("aac"),
          ])
      )
    case .failure(let error):
      Issue.record("expected success, got \(error)")
    }
  }

  @Test("the resolved config file path is reported even when no file exists there")
  func reportsResolvedPathRegardlessOfExistence() {
    let missingPath = "/nonexistent/\(UUID().uuidString)/config.toml"
    let inputs = ConfigLoadInputs(configFlag: missingPath, homeDirectory: "/Users/tom")

    switch loadConfig(inputs) {
    case .success(let loaded):
      #expect(loaded.configFilePath == missingPath)
    case .failure(let error):
      Issue.record("expected success, got \(error)")
    }
  }

  @Test("--print-config serializes the loaded config back to TOML text")
  func printConfigSerializesLoadedConfig() {
    let inputs = ConfigLoadInputs(
      configFlag: "/nonexistent/\(UUID().uuidString).toml",
      homeDirectory: "/Users/tom"
    )

    guard case .success(let loaded) = loadConfig(inputs) else {
      Issue.record("expected success")
      return
    }

    let text = printableConfig(loaded.value)
    #expect(text.contains("data_root"))
    #expect(text.contains("/Users/tom/Library/Application Support/ears"))
  }

  // MARK: - Schema/defaults generalization (earsd's composed schema)

  @Test("a caller can pass a different schema/defaults pair, e.g. earsd's composed schema")
  func zeroConfigWithEarsdSchemaUsesEarsdDefaults() {
    let temp = TempDirectory()
    let inputs = ConfigLoadInputs(
      configFlag: temp.url.appendingPathComponent("does-not-exist.toml").path,
      homeDirectory: "/Users/tom"
    )

    switch loadConfig(
      inputs,
      defaults: EarsdConfigSchema.effectiveDefaults,
      schema: EarsdConfigSchema.effectiveSchema
    ) {
    case .success(let loaded):
      guard case .table(let root) = loaded.value else {
        Issue.record("expected a table root")
        return
      }
      // Phase 0's shared keys are still present, path-expanded.
      #expect(root["data_root"] == .string("/Users/tom/Library/Application Support/ears"))
      // earsd's own slice is present with its defaults.
      guard case .table(let earsd)? = root["earsd"] else {
        Issue.record("expected an [earsd] table")
        return
      }
      #expect(earsd["chunk_seconds"] == .int(30))
      #expect(earsd["codec"] == .string("aac"))
    case .failure(let error):
      Issue.record("expected success, got \(error)")
    }
  }

  @Test("with the earsd schema, a value that fails only earsd's own type check is rejected")
  func earsdSchemaRejectsEarsdTypeMismatch() {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      [earsd]
      chunk_seconds = "thirty"
      """,
      named: "config.toml"
    )

    let inputs = ConfigLoadInputs(configFlag: configPath, homeDirectory: "/Users/tom")

    switch loadConfig(
      inputs,
      defaults: EarsdConfigSchema.effectiveDefaults,
      schema: EarsdConfigSchema.effectiveSchema
    ) {
    case .success:
      Issue.record("expected a validation failure")
    case .failure(let error):
      guard case .validation(let errors) = error else {
        Issue.record("expected .validation, got \(error)")
        return
      }
      #expect(errors.first?.message == "earsd.chunk_seconds: expected integer, got string")
    }
  }

  @Test(
    "with the earsd schema, an unknown key under [earsd] is rejected -- it's no longer passthrough")
  func earsdSchemaRejectsUnknownEarsdKey() {
    let temp = TempDirectory()
    let configPath = temp.write(
      """
      [earsd]
      bogus = "nope"
      """,
      named: "config.toml"
    )

    let inputs = ConfigLoadInputs(configFlag: configPath, homeDirectory: "/Users/tom")

    switch loadConfig(
      inputs,
      defaults: EarsdConfigSchema.effectiveDefaults,
      schema: EarsdConfigSchema.effectiveSchema
    ) {
    case .success:
      Issue.record("expected a validation failure")
    case .failure(let error):
      guard case .validation(let errors) = error else {
        Issue.record("expected .validation, got \(error)")
        return
      }
      #expect(errors.first?.keyPathString == "earsd.bogus")
      #expect(errors.first?.reason == .unknownKey)
    }
  }

  @Test("omitting defaults/schema still defaults to Phase 0's, unchanged from before")
  func omittingSchemaArgsPreservesPhase0Behavior() {
    let temp = TempDirectory()
    let inputs = ConfigLoadInputs(
      configFlag: temp.url.appendingPathComponent("does-not-exist.toml").path,
      homeDirectory: "/Users/tom"
    )

    switch loadConfig(inputs) {
    case .success(let loaded):
      guard case .table(let root) = loaded.value else {
        Issue.record("expected a table root")
        return
      }
      // No [earsd] key at all -- Phase 0's defaults don't declare one.
      #expect(root["earsd"] == nil)
    case .failure(let error):
      Issue.record("expected success, got \(error)")
    }
  }
}
