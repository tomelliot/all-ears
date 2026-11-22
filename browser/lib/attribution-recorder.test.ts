import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  ATTRIBUTION_DECLARE_SETTLE_MS,
  attributionDebugState,
  flushAttribution,
  recordAttribution,
  setAttributionMeetingLive,
  setAttributionPlatform,
} from "./attribution-recorder";

// A bare window whose postMessage records what would cross to the relay.
function fakeWindow(): { win: Record<string, unknown>; posted: unknown[] } {
  const posted: unknown[] = [];
  const win: Record<string, unknown> = { postMessage: (env: { __ears: true; msg: unknown }) => posted.push(env.msg) };
  return { win, posted };
}

const event = (t: number) => ({ type: "track-unmuted" as const, t, trackId: "remote-audio-1" });

describe("attribution flush gate", () => {
  let posted: unknown[];

  beforeEach(() => {
    const f = fakeWindow();
    posted = f.posted;
    vi.stubGlobal("window", f.win);
    setAttributionPlatform("jitsi");
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("holds events recorded before the meeting is declared", () => {
    recordAttribution(event(1));
    flushAttribution(10_000);
    expect(posted).toEqual([]);
    expect(attributionDebugState().pending).toBe(1);
  });

  it("ships the held events once the declare has had time to land", () => {
    recordAttribution(event(1));
    setAttributionMeetingLive(true, 5_000);
    flushAttribution(5_000 + ATTRIBUTION_DECLARE_SETTLE_MS - 1);
    expect(posted).toEqual([]);
    flushAttribution(5_000 + ATTRIBUTION_DECLARE_SETTLE_MS);
    expect(posted).toHaveLength(1);
    expect(posted[0]).toMatchObject({ kind: "attribution", platform: "jitsi" });
    expect((posted[0] as { events: string[] }).events).toHaveLength(1);
  });

  it("holds again after the meeting ends, for the next declare", () => {
    setAttributionMeetingLive(true, 0);
    setAttributionMeetingLive(false);
    recordAttribution(event(2));
    flushAttribution(60_000);
    expect(posted).toEqual([]);
  });

  it("keeps the first declare time when a meeting is declared again", () => {
    setAttributionMeetingLive(true, 0);
    setAttributionMeetingLive(true, 50_000);
    recordAttribution(event(3));
    flushAttribution(ATTRIBUTION_DECLARE_SETTLE_MS);
    expect(posted).toHaveLength(1);
  });
});
