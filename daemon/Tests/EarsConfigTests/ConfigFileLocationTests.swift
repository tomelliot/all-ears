import Testing

@testable import EarsConfig

@Suite("Config file location resolution")
struct ConfigFileLocationTests {
  @Test("the --config flag wins over everything")
  func flagWinsOverAll() {
    let path = resolveConfigFilePath(
      configFlag: "/flag/path.toml",
      environment: [
        "EARS_CONFIG": "/env/path.toml",
        "XDG_CONFIG_HOME": "/xdg",
      ],
      homeDirectory: "/home/tom"
    )
    #expect(path == "/flag/path.toml")
  }

  @Test("EARS_CONFIG wins over XDG_CONFIG_HOME and the home fallback")
  func envConfigWinsOverXDGAndHome() {
    let path = resolveConfigFilePath(
      configFlag: nil,
      environment: [
        "EARS_CONFIG": "/env/path.toml",
        "XDG_CONFIG_HOME": "/xdg",
      ],
      homeDirectory: "/home/tom"
    )
    #expect(path == "/env/path.toml")
  }

  @Test("XDG_CONFIG_HOME wins over the home fallback when set")
  func xdgConfigHomeWinsOverHomeFallback() {
    let path = resolveConfigFilePath(
      configFlag: nil,
      environment: ["XDG_CONFIG_HOME": "/xdg"],
      homeDirectory: "/home/tom"
    )
    #expect(path == "/xdg/ears/config.toml")
  }

  @Test("falls back to ~/.config/ears/config.toml when nothing else is set")
  func fallsBackToHomeConfigDirectory() {
    let path = resolveConfigFilePath(
      configFlag: nil,
      environment: [:],
      homeDirectory: "/home/tom"
    )
    #expect(path == "/home/tom/.config/ears/config.toml")
  }

  @Test("an empty --config flag is treated as absent")
  func emptyFlagIsIgnored() {
    let path = resolveConfigFilePath(
      configFlag: "",
      environment: [:],
      homeDirectory: "/home/tom"
    )
    #expect(path == "/home/tom/.config/ears/config.toml")
  }

  @Test("an empty XDG_CONFIG_HOME is treated as unset")
  func emptyXDGConfigHomeIsIgnored() {
    let path = resolveConfigFilePath(
      configFlag: nil,
      environment: ["XDG_CONFIG_HOME": ""],
      homeDirectory: "/home/tom"
    )
    #expect(path == "/home/tom/.config/ears/config.toml")
  }
}
