import { registerAdapter, type PlatformAdapter } from "./adapter";

// Teams identity — Phase 6. Placeholder: returns null so capture falls back to
// speaker-<n>. Phase 6 adds dominant-speaker-at-timestamp attribution over the
// single mixed track. Teams is attribution, not isolation — never presented as
// true per-participant.
class TeamsAdapter implements PlatformAdapter {
  readonly platform = "teams" as const;
  identify(): null {
    return null;
  }
}

registerAdapter((host) => host === "teams.microsoft.com", () => new TeamsAdapter());
