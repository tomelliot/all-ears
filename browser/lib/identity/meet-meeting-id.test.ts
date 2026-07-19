import { describe, expect, it, vi } from "vitest";
import {
  extractMeetSpaceId,
  MeetMeetingIdWatcher,
  scanTilesForSpaceId,
  type TileDocumentLike,
} from "./meet-meeting-id";

// Hand-rolled fakes (no jsdom), matching meet.test.ts's convention.

function fakeDoc(tiles: Array<Record<string, string>>): TileDocumentLike {
  return {
    querySelectorAll(selectors: string) {
      // Selector shape is "[attr]" — match tiles carrying that attribute.
      const attr = selectors.slice(1, -1);
      return tiles
        .filter((t) => attr in t)
        .map((t) => ({ getAttribute: (name: string) => t[name] ?? null }));
    },
  };
}

describe("extractMeetSpaceId", () => {
  it("extracts the space segment from a full device id", () => {
    expect(extractMeetSpaceId("spaces/AbCd-123/devices/xyz")).toBe("AbCd-123");
  });

  it("extracts from a bare spaces/<space> value", () => {
    expect(extractMeetSpaceId("spaces/AbCd-123")).toBe("AbCd-123");
  });

  it("returns null for fallback ids, empty, and null", () => {
    expect(extractMeetSpaceId("speaker-3")).toBeNull();
    expect(extractMeetSpaceId("")).toBeNull();
    expect(extractMeetSpaceId(null)).toBeNull();
    expect(extractMeetSpaceId(undefined)).toBeNull();
    expect(extractMeetSpaceId("spaces/")).toBeNull();
  });

  it("tolerates surrounding whitespace", () => {
    expect(extractMeetSpaceId("  spaces/AbCd/devices/d  ")).toBe("AbCd");
  });
});

describe("scanTilesForSpaceId", () => {
  it("finds the first spaces-shaped id across the probed attributes", () => {
    const doc = fakeDoc([
      { "data-participant-id": "not-a-space-id" },
      { "data-requested-participant-id": "spaces/QqQ/devices/1" },
    ]);
    expect(scanTilesForSpaceId(doc)).toBe("QqQ");
  });

  it("returns null when no tile carries a spaces-shaped id", () => {
    expect(scanTilesForSpaceId(fakeDoc([{ "data-participant-id": "bogus" }]))).toBeNull();
    expect(scanTilesForSpaceId(fakeDoc([]))).toBeNull();
  });
});

describe("MeetMeetingIdWatcher", () => {
  it("resolves once from a candidate id and ignores later inputs", () => {
    const onResolved = vi.fn();
    const watcher = new MeetMeetingIdWatcher(onResolved);

    watcher.observeCandidate("speaker-1"); // no match — still unresolved
    expect(watcher.spaceId).toBeNull();

    watcher.observeCandidate("spaces/First/devices/a");
    watcher.observeCandidate("spaces/Second/devices/b");
    watcher.poll(fakeDoc([{ "data-participant-id": "spaces/Third/devices/c" }]));

    expect(watcher.spaceId).toBe("First");
    expect(onResolved).toHaveBeenCalledTimes(1);
    expect(onResolved).toHaveBeenCalledWith("First");
  });

  it("resolves from a tile poll when no candidate has matched", () => {
    const onResolved = vi.fn();
    const watcher = new MeetMeetingIdWatcher(onResolved);

    watcher.poll(fakeDoc([])); // nothing mounted yet
    expect(watcher.spaceId).toBeNull();

    watcher.poll(fakeDoc([{ "data-participant-id": "spaces/Tile/devices/x" }]));
    expect(watcher.spaceId).toBe("Tile");
    expect(onResolved).toHaveBeenCalledWith("Tile");
  });
});
