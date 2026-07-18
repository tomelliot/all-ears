/// Merges two config layers, key-wise: a key present in `overlay` overrides the
/// same key in `base`; when both sides hold a table at a given key, the merge
/// recurses so sibling keys from `base` survive. Any other type pairing (or a
/// scalar/array on either side) is a wholesale replacement — `overlay` wins
/// outright.
public func mergeConfigValues(base: ConfigValue, overlay: ConfigValue) -> ConfigValue {
  guard case .table(let baseTable) = base, case .table(let overlayTable) = overlay else {
    return overlay
  }

  var merged = baseTable
  for (key, overlayValue) in overlayTable {
    if let baseValue = merged[key] {
      merged[key] = mergeConfigValues(base: baseValue, overlay: overlayValue)
    } else {
      merged[key] = overlayValue
    }
  }
  return .table(merged)
}

/// Merges ordered config layers into one tree, lowest precedence first — per
/// `docs/configuration.md`: built-in defaults → config file → environment
/// variables → CLI flags. Each layer overrides the ones before it, recursively
/// at every key path.
public func mergeConfigLayers(_ layers: [ConfigValue]) -> ConfigValue {
  layers.reduce(ConfigValue.table([:])) { mergeConfigValues(base: $0, overlay: $1) }
}
