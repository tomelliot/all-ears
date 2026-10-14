import { describe, expect, it } from "vitest";
import { extractTeamsMeetingTitle, TeamsMeetingTitleWatcher } from "./teams-meeting-title";

describe("extractTeamsMeetingTitle", () => {
  it("reads the in-call title observed live on the light client", () => {
    expect(extractTeamsMeetingTitle("Call Alice <> Bob | Microsoft Teams")).toBe("Call Alice <> Bob");
  });

  it("strips an unread-count prefix and the free-tier suffix", () => {
    expect(extractTeamsMeetingTitle("(3) Weekly sync | Microsoft Teams (free)")).toBe("Weekly sync");
  });

  it("returns null for pre-join and app-view titles", () => {
    expect(extractTeamsMeetingTitle("Microsoft Teams meeting | Microsoft Teams")).toBeNull();
    expect(extractTeamsMeetingTitle("Join conversation")).toBeNull();
    expect(extractTeamsMeetingTitle("Chat | Microsoft Teams")).toBeNull();
    expect(extractTeamsMeetingTitle("(1) Calendar | Microsoft Teams")).toBeNull();
    expect(extractTeamsMeetingTitle("Microsoft Teams")).toBeNull();
    expect(extractTeamsMeetingTitle("")).toBeNull();
    expect(extractTeamsMeetingTitle(null)).toBeNull();
  });
});

describe("TeamsMeetingTitleWatcher", () => {
  it("reports the first real title once, skipping generic ones", () => {
    const seen: string[] = [];
    const w = new TeamsMeetingTitleWatcher((t) => seen.push(t));
    w.poll({ title: "Microsoft Teams meeting | Microsoft Teams" });
    w.poll({ title: "Call Alice <> Bob | Microsoft Teams" });
    w.poll({ title: "Something else | Microsoft Teams" });
    expect(seen).toEqual(["Call Alice <> Bob"]);
    expect(w.title).toBe("Call Alice <> Bob");
  });
});
