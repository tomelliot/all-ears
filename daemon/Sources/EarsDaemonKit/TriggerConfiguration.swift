import EarsCore

/// The resolved, ready-to-run shape of one `[[triggers.rule]]` entry (see
/// `docs/configuration.md`'s "Auto-triggers" reference) that
/// ``AppSignalTriggerObserver`` runs against. Building this from a loaded
/// `EarsdConfigSchema` config is ``Sources/earsd/DaemonConfigResolution``'s
/// job (mirroring how it resolves `[[earsd.source]]` into
/// `SourceDescriptor`s); this type is deliberately just a plain value the
/// caller hands in.
public struct TriggerRuleConfiguration: Sendable, Hashable {
  public var name: String
  /// The trigger condition. Only `"app-audio-active"` is documented today —
  /// left as a plain string (not an enum) at the config-resolution boundary,
  /// matching `EarsdConfigSchema`'s own "no closed-set-of-strings" schema
  /// engine; ``AppSignalTriggerObserver`` is where an unrecognised value is
  /// actually rejected/ignored.
  public var on: String
  /// Bundle ids (or, per the doc's own example, sometimes a human app name —
  /// matched only by exact `NSRunningApplication.bundleIdentifier` equality;
  /// a non-bundle-id entry here simply never matches anything, a config
  /// authoring error rather than this type's concern).
  public var apps: [String]
  public var openSession: Bool
  public var sources: [SourceID]
  /// Pipeline stage names to run in order on session close, e.g.
  /// `["transcribe", "cleanup", "summarize"]`.
  public var onClose: [String]
  /// Seconds of already-buffered ring audio to widen a session's
  /// transcribed range backward by, when transcribing this rule's sessions.
  /// `0` (the default) means no widening.
  public var preRollSeconds: Int

  public init(
    name: String,
    on: String,
    apps: [String],
    openSession: Bool,
    sources: [SourceID],
    onClose: [String],
    preRollSeconds: Int = 0
  ) {
    self.name = name
    self.on = on
    self.apps = apps
    self.openSession = openSession
    self.sources = sources
    self.onClose = onClose
    self.preRollSeconds = preRollSeconds
  }
}

/// `[triggers]`'s resolved shape: whether auto-triggers are enabled at all,
/// the configured rules, and whether a browser-extension-triggered session
/// close runs the transcribe stage automatically.
public struct TriggersConfiguration: Sendable, Hashable {
  public var enabled: Bool
  public var rules: [TriggerRuleConfiguration]
  /// `[triggers].transcribe_on_browser_session_close`: when `true`, a session
  /// closed with `trigger == .browserExtension` runs the `transcribe` stage
  /// via the shared ``OnClosePipelineRunner`` — the browser-side analogue of
  /// a rule's `on_close`, which only fires on app-signal rule matches.
  /// Default `true`: a browser meeting transcribes when it ends unless the
  /// user opts out with `transcribe_on_browser_session_close = false`.
  public var transcribeOnBrowserSessionClose: Bool

  public init(
    enabled: Bool = false,
    rules: [TriggerRuleConfiguration] = [],
    transcribeOnBrowserSessionClose: Bool = true
  ) {
    self.enabled = enabled
    self.rules = rules
    self.transcribeOnBrowserSessionClose = transcribeOnBrowserSessionClose
  }
}
