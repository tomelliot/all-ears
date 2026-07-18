import { registerAdapter, type PlatformAdapter } from "./adapter";

// Meet identity — Phase 4. Placeholder: returns null so capture falls back to
// speaker-<n>. Phase 4 adds tile-DOM correlation (data-participant-id + name).
class MeetAdapter implements PlatformAdapter {
  readonly platform = "meet" as const;
  identify(): null {
    return null;
  }
}

registerAdapter((host) => host === "meet.google.com", () => new MeetAdapter());
