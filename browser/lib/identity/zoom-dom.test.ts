import { describe, expect, it } from "vitest";
import {
  extractZoomMeetingTitle,
  parseZoomDisplayName,
  scanZoomRoster,
  usableZoomTopic,
  ZOOM_SELECTORS,
  ZoomMeetingTitleWatcher,
  ZoomRosterWatcher,
  zoomNameId,
  type ZoomDocumentLike,
  type ZoomElementLike,
} from "./zoom-dom";
import type { RosterEntry } from "../protocol";

// Hand-rolled DOM fixtures (no jsdom), matching meet-meeting-title.test.ts.
// Shapes follow the class names in ZOOM_SELECTORS; they are not yet
// confirmed against a live web-client build.

interface Fixture {
  title?: string;
  /** Participants panel rows: [name text, sibling label text]. */
  participants?: Array<[string, string?]>;
  avatarNames?: string[];
  avatarFooters?: string[];
  preJoinName?: string;
  topics?: string[];
}

function el(text: string, siblings: Record<string, string> = {}): ZoomElementLike {
  return {
    textContent: text,
    parentElement: {
      querySelector: (sel) => (sel in siblings ? { textContent: siblings[sel]! } : null),
    },
  };
}

function fakeDoc(f: Fixture): ZoomDocumentLike & { queried: string[] } {
  const queried: string[] = [];
  const all: Record<string, ZoomElementLike[]> = {
    [ZOOM_SELECTORS.participantName]: (f.participants ?? []).map(([name, label]) =>
      el(name, label ? { [ZOOM_SELECTORS.participantLabel]: label } : {}),
    ),
    [ZOOM_SELECTORS.tileNames[0]]: (f.avatarNames ?? []).map((t) => el(t)),
    [ZOOM_SELECTORS.tileNames[1]]: (f.avatarFooters ?? []).map((t) => el(t)),
    [ZOOM_SELECTORS.topic]: (f.topics ?? []).map((t) => el(t)),
  };
  return {
    title: f.title ?? "Zoom",
    queried,
    querySelectorAll: (sel) => {
      queried.push(sel);
      return all[sel] ?? [];
    },
    querySelector: (sel) =>
      sel === ZOOM_SELECTORS.preJoinName && f.preJoinName !== undefined
        ? ({ textContent: "", value: f.preJoinName } as { textContent: string })
        : null,
  };
}

describe("parseZoomDisplayName", () => {
  it("strips role suffixes", () => {
    expect(parseZoomDisplayName("Emily Kegels (Host)")).toEqual({ name: "Emily Kegels", isLocal: false });
    expect(parseZoomDisplayName("Emily Kegels (Co-host)")).toEqual({ name: "Emily Kegels", isLocal: false });
    expect(parseZoomDisplayName("Sam Lee (Guest)")).toEqual({ name: "Sam Lee", isLocal: false });
  });

  it("flags the local user from Zoom's self marker", () => {
    expect(parseZoomDisplayName("Tom Elliot (Me)")).toEqual({ name: "Tom Elliot", isLocal: true });
    expect(parseZoomDisplayName("Tom Elliot (Host, me)")).toEqual({ name: "Tom Elliot", isLocal: true });
    expect(parseZoomDisplayName("Tom Elliot (Host) (me)")).toEqual({ name: "Tom Elliot", isLocal: true });
  });

  it("keeps a parenthetical that is part of the name", () => {
    expect(parseZoomDisplayName("Sam (Berlin office)")).toEqual({ name: "Sam (Berlin office)", isLocal: false });
  });

  it("collapses whitespace and rejects empty or oversized text", () => {
    expect(parseZoomDisplayName("  Emily \n Kegels  ")?.name).toBe("Emily Kegels");
    expect(parseZoomDisplayName("   ")).toBeNull();
    expect(parseZoomDisplayName("(Host)")).toBeNull();
    expect(parseZoomDisplayName("x".repeat(81))).toBeNull();
    expect(parseZoomDisplayName(null)).toBeNull();
  });
});

describe("scanZoomRoster", () => {
  it("reads remote names from the video-tile name overlays", () => {
    const scan = scanZoomRoster([fakeDoc({ avatarNames: ["Emily Kegels", "Sam Lee", "Emily Kegels"] })]);
    expect(scan.remote).toEqual(["Emily Kegels", "Sam Lee"]);
    expect(scan.local).toBeNull();
    expect(scan.matched[".video-avatar__avatar-name"]).toBe(3);
  });

  it("falls back to the tile footer only when no name overlay matches", () => {
    const footerOnly = scanZoomRoster([fakeDoc({ avatarFooters: ["Emily Kegels"] })]);
    expect(footerOnly.remote).toEqual(["Emily Kegels"]);
    const both = fakeDoc({ avatarNames: ["Emily Kegels"], avatarFooters: ["Emily KegelsMuted"] });
    expect(scanZoomRoster([both]).remote).toEqual(["Emily Kegels"]);
    expect(both.queried).not.toContain(".video-avatar__avatar-footer");
  });

  it("excludes the local user marked in the participants panel, here and on their tile", () => {
    const scan = scanZoomRoster([
      fakeDoc({
        participants: [["Tom Elliot", "(Host, me)"], ["Emily Kegels"]],
        avatarNames: ["Tom Elliot", "Emily Kegels"],
      }),
    ]);
    expect(scan.remote).toEqual(["Emily Kegels"]);
    expect(scan.local).toBe("Tom Elliot");
  });

  it("reads a self marker inside the participant name text", () => {
    const scan = scanZoomRoster([fakeDoc({ participants: [["Tom Elliot (Me)"], ["Emily Kegels (Host)"]] })]);
    expect(scan.remote).toEqual(["Emily Kegels"]);
    expect(scan.local).toBe("Tom Elliot");
  });

  it("uses the pre-join name to exclude an unmarked self tile", () => {
    const docs = [fakeDoc({ avatarNames: ["Tom Elliot", "Emily Kegels"] })];
    expect(scanZoomRoster(docs, "Tom Elliot")).toMatchObject({ remote: ["Emily Kegels"], local: "Tom Elliot" });
    // A hint matching nobody on screen is not taken as a participant.
    expect(scanZoomRoster(docs, "Someone Else")).toMatchObject({
      remote: ["Tom Elliot", "Emily Kegels"],
      local: null,
    });
  });

  it("reads a self marker from a label with or without parentheses", () => {
    for (const label of ["Me", "(Me)", "Host, me", " (Host, me) "]) {
      const scan = scanZoomRoster([fakeDoc({ participants: [["Tom Elliot", label], ["Emily Kegels"]] })]);
      expect(scan).toMatchObject({ remote: ["Emily Kegels"], local: "Tom Elliot", localVia: "marker" });
    }
  });

  it("ignores a participant label that is not a role", () => {
    const scan = scanZoomRoster([fakeDoc({ participants: [["Emily Kegels", "Muted"]] })]);
    expect(scan).toMatchObject({ remote: ["Emily Kegels"], local: null, localVia: null });
  });

  it("matches the local hint ignoring case, keeping Zoom's spelling", () => {
    const scan = scanZoomRoster([fakeDoc({ avatarNames: ["Tom Elliot", "Emily Kegels"] })], " tom elliot ");
    expect(scan).toMatchObject({ remote: ["Emily Kegels"], local: "Tom Elliot", localVia: "hint" });
  });

  it("leaves every tile remote and no one local with no marker and no hint (2026-10-26 live)", () => {
    const scan = scanZoomRoster([fakeDoc({ avatarFooters: ["Tom Elliot", "Emily Kegels"] })]);
    expect(scan).toMatchObject({ remote: ["Tom Elliot", "Emily Kegels"], local: null, localVia: null });
  });

  it("merges names across frames", () => {
    const scan = scanZoomRoster([fakeDoc({ avatarNames: ["Emily Kegels"] }), fakeDoc({ avatarNames: ["Sam Lee"] })]);
    expect(scan.remote).toEqual(["Emily Kegels", "Sam Lee"]);
  });

  it("finds nothing on a page with none of the selectors", () => {
    const scan = scanZoomRoster([fakeDoc({})]);
    expect(scan).toMatchObject({ remote: [], local: null });
    expect(Object.values(scan.matched).every((n) => n === 0)).toBe(true);
  });
});

describe("ZoomRosterWatcher", () => {
  it("sends each name once, then a late local flag as news", () => {
    const batches: unknown[] = [];
    const w = new ZoomRosterWatcher((e) => batches.push(e));
    w.poll([fakeDoc({ avatarNames: ["Tom Elliot", "Emily Kegels"] })]);
    w.poll([fakeDoc({ avatarNames: ["Tom Elliot", "Emily Kegels"] })]);
    // The panel opens and marks Tom as the local user.
    w.poll([fakeDoc({ participants: [["Tom Elliot", "(Host, me)"], ["Emily Kegels"]] })]);
    expect(batches).toEqual([
      [
        { participantId: zoomNameId("Tom Elliot"), displayName: "Tom Elliot" },
        { participantId: zoomNameId("Emily Kegels"), displayName: "Emily Kegels" },
      ],
      [{ participantId: zoomNameId("Tom Elliot"), displayName: "Tom Elliot", isLocal: true }],
    ]);
  });

  it("flags the local user from the pre-join field seen before join", () => {
    const batches: unknown[] = [];
    const w = new ZoomRosterWatcher((e) => batches.push(e));
    w.observePreJoin([fakeDoc({ preJoinName: " Tom Elliot " })]);
    w.observePreJoin([fakeDoc({})]); // the field is gone after join; the hint stays
    w.poll([fakeDoc({ avatarNames: ["Emily Kegels", "Tom Elliot"] })]);
    expect(batches).toEqual([
      [
        { participantId: zoomNameId("Emily Kegels"), displayName: "Emily Kegels" },
        { participantId: zoomNameId("Tom Elliot"), displayName: "Tom Elliot", isLocal: true },
      ],
    ]);
  });

  it("keeps the local user once the participants panel closes", () => {
    const batches: RosterEntry[][] = [];
    const lines: string[] = [];
    const w = new ZoomRosterWatcher(
      (e) => batches.push(e),
      (l) => lines.push(l),
    );
    w.poll([fakeDoc({ participants: [["Tom Elliot", "(Host, me)"], ["Emily Kegels"]] })]);
    w.poll([fakeDoc({ avatarNames: ["Tom Elliot", "Emily Kegels", "Sam Lee"] })]);
    expect(w.localName).toBe("Tom Elliot");
    expect(batches).toEqual([
      [
        { participantId: zoomNameId("Emily Kegels"), displayName: "Emily Kegels" },
        { participantId: zoomNameId("Tom Elliot"), displayName: "Tom Elliot", isLocal: true },
      ],
      [{ participantId: zoomNameId("Sam Lee"), displayName: "Sam Lee" }],
    ]);
    expect(lines.at(-1)).toMatch(/^roster scan: 2 remote, 1 local \(pre-join name not seen; local via marker\)/);
  });

  it("reads the pre-join field in any frame, and again after join (a rejoin)", () => {
    const batches: RosterEntry[][] = [];
    const w = new ZoomRosterWatcher((e) => batches.push(e));
    w.poll([fakeDoc({ avatarNames: ["Tom Elliot", "Emily Kegels"] })]);
    // Rejoin: the field shows again, in the inner frame only.
    w.observePreJoin([fakeDoc({}), fakeDoc({ preJoinName: "Tom Elliot" })]);
    w.poll([fakeDoc({ avatarNames: ["Tom Elliot", "Emily Kegels"] })]);
    expect(w.localName).toBe("Tom Elliot");
    expect(batches.at(-1)).toEqual([
      { participantId: zoomNameId("Tom Elliot"), displayName: "Tom Elliot", isLocal: true },
    ]);
  });

  it("lets a (me) marker replace a pre-join name", () => {
    const w = new ZoomRosterWatcher(() => {});
    w.observePreJoin([fakeDoc({ preJoinName: "Emily Kegels" })]);
    w.poll([fakeDoc({ avatarNames: ["Emily Kegels", "Tom Elliot"] })]);
    expect(w.localName).toBe("Emily Kegels");
    w.poll([fakeDoc({ participants: [["Tom Elliot (me)"], ["Emily Kegels"]] })]);
    expect(w.localName).toBe("Tom Elliot");
  });

  it("offers the pre-join name as a hint before the roster confirms it", () => {
    const w = new ZoomRosterWatcher(() => {});
    expect(w.ownNameHint).toBeNull();
    w.observePreJoin([fakeDoc({ preJoinName: "Tom Elliot" })]);
    expect(w.localName).toBeNull();
    expect(w.ownNameHint).toBe("Tom Elliot");
  });

  it("sends nothing when nothing matches", () => {
    const batches: unknown[] = [];
    const w = new ZoomRosterWatcher((e) => batches.push(e));
    w.poll([fakeDoc({})]);
    expect(batches).toEqual([]);
  });

  it("logs counts and selectors on change only, never names", () => {
    const lines: string[] = [];
    const w = new ZoomRosterWatcher(
      () => {},
      (l) => lines.push(l),
    );
    w.poll([fakeDoc({})]);
    w.poll([fakeDoc({})]);
    w.poll([fakeDoc({ participants: [["Tom Elliot (me)"]], avatarNames: ["Emily Kegels", "Tom Elliot"] })]);
    expect(lines).toEqual([
      "roster scan: 0 remote, 0 local (pre-join name not seen; local via nothing); matched nothing",
      "roster scan: 1 remote, 1 local (pre-join name not seen; local via marker); matched " +
        ".participants-item__display-name=1 .video-avatar__avatar-name=2",
    ]);
    for (const l of lines) expect(l).not.toMatch(/Emily|Tom/);
  });
});

describe("usableZoomTopic", () => {
  it("strips the product suffix from a tab title", () => {
    expect(usableZoomTopic("Weekly sync - Zoom")).toBe("Weekly sync");
    expect(usableZoomTopic("Weekly sync | Zoom Workplace")).toBe("Weekly sync");
  });

  it("rejects generic screen titles", () => {
    for (const t of ["Zoom", "Zoom Meeting", "zoom meeting - Zoom", "Join Meeting", "Topic", "", "  "]) {
      expect(usableZoomTopic(t)).toBeNull();
    }
  });

  it("rejects Zoom's auto-generated host topics", () => {
    expect(usableZoomTopic("Emily Kegels's Zoom Meeting")).toBeNull();
    expect(usableZoomTopic("James’ Zoom Meeting")).toBeNull();
    expect(usableZoomTopic("Emily Kegels's Personal Meeting Room")).toBeNull();
  });

  it("rejects a bare meeting id", () => {
    expect(usableZoomTopic("879 7373 4905")).toBeNull();
  });

  it("rejects the web client's own screen names", () => {
    for (const t of [
      "Zoom meeting on web", // live tab title, 2026-10-26
      "Zoom Meeting on Web - Zoom",
      "Zoom Webinar on the web",
      "Zoom Web Client",
      "Zoom web app",
      "Zoom Workplace Meeting",
      "Meeting on web",
      "Waiting Room",
      "Join from your browser",
    ]) {
      expect(usableZoomTopic(t)).toBeNull();
    }
  });

  it("keeps a real topic that starts with the product name", () => {
    expect(usableZoomTopic("Zoom rollout planning")).toBe("Zoom rollout planning");
    expect(usableZoomTopic("Zoom meeting on web performance - Zoom")).toBe("Zoom meeting on web performance");
  });

  it("rejects a topic that is only the local user's name", () => {
    expect(usableZoomTopic("Tom Elliot - Zoom", "tom elliot")).toBeNull();
    expect(usableZoomTopic("Tom Elliot / Emily Kegels", "Tom Elliot")).toBe("Tom Elliot / Emily Kegels");
  });
});

describe("extractZoomMeetingTitle", () => {
  it("prefers a topic in the tab title", () => {
    const docs = [fakeDoc({ title: "Design review - Zoom", topics: ["Other"] })];
    expect(extractZoomMeetingTitle(docs)).toEqual({ title: "Design review", via: "document.title" });
  });

  it("falls back to a topic element when the tab title is generic", () => {
    const docs = [fakeDoc({ title: "Zoom", topics: ["Topic", "Design review"] })];
    expect(extractZoomMeetingTitle(docs)).toEqual({ title: "Design review", via: ZOOM_SELECTORS.topic });
  });

  it("returns null when no topic is exposed, leaving the roster title to the daemon", () => {
    expect(extractZoomMeetingTitle([fakeDoc({ title: "Zoom Meeting", avatarNames: ["Emily Kegels"] })])).toBeNull();
  });
});

describe("ZoomMeetingTitleWatcher", () => {
  it("reports the first topic exactly once", () => {
    const seen: string[] = [];
    const w = new ZoomMeetingTitleWatcher((t) => seen.push(t));
    w.poll([fakeDoc({ title: "Zoom" })]);
    expect(w.title).toBeNull();
    w.poll([fakeDoc({ title: "Design review - Zoom" })]);
    w.poll([fakeDoc({ title: "Something else - Zoom" })]);
    expect(seen).toEqual(["Design review"]);
    expect(w.title).toBe("Design review");
  });

  it("waits past a tab title that is the web client's or the local user's name", () => {
    const seen: string[] = [];
    const w = new ZoomMeetingTitleWatcher((t) => seen.push(t));
    w.poll([fakeDoc({ title: "Zoom meeting on web" })]);
    w.poll([fakeDoc({ title: "Tom Elliot - Zoom" })], "Tom Elliot");
    expect(w.title).toBeNull();
    w.poll([fakeDoc({ title: "Design review - Zoom" })], "Tom Elliot");
    expect(seen).toEqual(["Design review"]);
  });
});
