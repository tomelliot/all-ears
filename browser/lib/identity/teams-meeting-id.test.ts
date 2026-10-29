import { describe, expect, it, vi } from "vitest";
import {
  parseTeamsMeetingId,
  parseTeamsMeetingIdFromUrl,
  parseTeamsMeetingCodeFromUrl,
  TeamsMeetingIdWatcher,
  type TeamsIdSources,
} from "./teams-meeting-id";

// Hand-rolled fakes (no jsdom), matching meet-meeting-id.test.ts's convention.

/** The shape observed on a live call (journal #161): a 48-character body,
 * 69 characters end to end. */
const THREAD_ID = "19:meeting_NWY3ZTk2ZjMtNGRiZC00YmVmLWEyMThmMjM0YTRlN0BoMWJj@thread.v2";

function fakeSources(over: Partial<TeamsIdSources> = {}): TeamsIdSources {
  return {
    url: "https://teams.microsoft.com/light-meetings/launch?anon=true&lightExperience=true",
    documentText: () => "",
    documentHtml: () => "",
    ...over,
  };
}

describe("parseTeamsMeetingId", () => {
  it("reads the shape observed live — 19:meeting_<48>@thread.v2, 69 chars", () => {
    expect(THREAD_ID).toHaveLength(69);
    expect(parseTeamsMeetingId(`<div data-tid="${THREAD_ID}">`)).toBe(THREAD_ID);
  });

  it("finds the id embedded in a page-sized blob of unrelated markup", () => {
    const html = `<html><body>${"<div class='ui-box'>x</div>".repeat(200)}<script type="application/json">{"threadId":"${THREAD_ID}"}</script></body></html>`;
    expect(parseTeamsMeetingId(html)).toBe(THREAD_ID);
  });

  it("tolerates the +/=/-/_ characters the id's base64-ish body can carry", () => {
    const id = "19:meeting_ab+cdXef=gh-ij_kl@thread.v2";
    expect(parseTeamsMeetingId(id)).toBe(id);
  });

  it("ignores ordinary chat threads, which share the 19:…@thread.v2 shape", () => {
    // A page showing the chat rail is full of these; resolving one would file
    // the recording under a random conversation.
    expect(parseTeamsMeetingId("19:8ab1c0f1e2d34a56b789@thread.v2")).toBeNull();
    expect(parseTeamsMeetingId("19:meeting_short@thread.v2")).toBeNull();
    expect(parseTeamsMeetingId(`19:meeting_${"a".repeat(48)}@thread.tacv2`)).toBeNull();
  });

  it("returns null on a non-meeting page and on empty/nullish input", () => {
    expect(parseTeamsMeetingId("<html><body>Sign in to Microsoft Teams</body></html>")).toBeNull();
    expect(parseTeamsMeetingId("")).toBeNull();
    expect(parseTeamsMeetingId(null)).toBeNull();
    expect(parseTeamsMeetingId(undefined)).toBeNull();
  });
});

describe("parseTeamsMeetingIdFromUrl", () => {
  it("reads the id out of a signed-in client deeplink route", () => {
    expect(
      parseTeamsMeetingIdFromUrl(`https://teams.microsoft.com/_#/l/meetup-join/${THREAD_ID}/0?ctx=1`),
    ).toBe(THREAD_ID);
  });

  it("reads it back out of a percent-encoded query string", () => {
    const encoded = encodeURIComponent(THREAD_ID);
    expect(encoded).not.toContain("@"); // the escaping this branch exists for
    expect(parseTeamsMeetingIdFromUrl(`https://teams.microsoft.com/x?thread=${encoded}`)).toBe(
      THREAD_ID,
    );
  });

  it("returns null for the anonymous launch URL, which carries no thread id", () => {
    // journal #161: only tenant/object ids and a per-session correlation id.
    expect(
      parseTeamsMeetingIdFromUrl(
        "https://teams.microsoft.com/light-meetings/launch?agent=web&anon=true&correlationId=6f1a…",
      ),
    ).toBeNull();
  });

  it("survives a malformed percent escape rather than throwing into the page", () => {
    expect(parseTeamsMeetingIdFromUrl("https://teams.microsoft.com/%E0%A4%A")).toBeNull();
  });
});

describe("TeamsMeetingIdWatcher", () => {
  it("resolves from the URL without touching either document surface", () => {
    const onResolved = vi.fn();
    const documentText = vi.fn(() => "");
    const documentHtml = vi.fn(() => "");
    const watcher = new TeamsMeetingIdWatcher(onResolved);

    watcher.poll(
      fakeSources({ url: `https://teams.microsoft.com/_#/${THREAD_ID}`, documentText, documentHtml }),
    );

    expect(watcher.threadId).toBe(THREAD_ID);
    expect(onResolved).toHaveBeenCalledTimes(1);
    expect(onResolved).toHaveBeenCalledWith(THREAD_ID);
    expect(documentText).not.toHaveBeenCalled();
    expect(documentHtml).not.toHaveBeenCalled();
  });

  it("falls back to document text when the URL carries nothing", () => {
    const onResolved = vi.fn();
    const watcher = new TeamsMeetingIdWatcher(onResolved);

    watcher.poll(fakeSources({ documentText: () => `{"threadId":"${THREAD_ID}"}` }));

    expect(watcher.threadId).toBe(THREAD_ID);
    expect(onResolved).toHaveBeenCalledWith(THREAD_ID);
  });

  it("sweeps the full markup on the first poll, then one poll in five", () => {
    const documentHtml = vi.fn(() => "");
    const watcher = new TeamsMeetingIdWatcher(vi.fn());
    const sources = fakeSources({ documentHtml });

    for (let i = 0; i < 11; i++) watcher.poll(sources);

    // Polls 1, 6 and 11 — the 4.9 ms surface, kept off the other eight ticks.
    expect(documentHtml).toHaveBeenCalledTimes(3);
  });

  it("resolves from an attribute only the markup sweep can see", () => {
    const onResolved = vi.fn();
    const watcher = new TeamsMeetingIdWatcher(onResolved);
    const sources = fakeSources({ documentHtml: () => `<div data-tid="${THREAD_ID}"></div>` });

    watcher.poll(sources);

    expect(watcher.threadId).toBe(THREAD_ID);
    expect(onResolved).toHaveBeenCalledWith(THREAD_ID);
  });

  it("stays unresolved on a page that has no meeting, however often it is polled", () => {
    const onResolved = vi.fn();
    const watcher = new TeamsMeetingIdWatcher(onResolved);
    const sources = fakeSources({
      url: "https://teams.microsoft.com/v2/",
      documentText: () => "Chat Teams Calendar",
      documentHtml: () => '<div class="ui-box" data-tid="chat-list"></div>',
    });

    for (let i = 0; i < 10; i++) watcher.poll(sources);

    expect(watcher.threadId).toBeNull();
    expect(onResolved).not.toHaveBeenCalled();
  });

  it("reports once and ignores every later poll", () => {
    const onResolved = vi.fn();
    const watcher = new TeamsMeetingIdWatcher(onResolved);
    const other = `19:meeting_${"b".repeat(48)}@thread.v2`;

    watcher.poll(fakeSources({ documentText: () => THREAD_ID }));
    watcher.poll(fakeSources({ documentText: () => other }));

    expect(watcher.threadId).toBe(THREAD_ID);
    expect(onResolved).toHaveBeenCalledTimes(1);
  });
});

describe("parseTeamsMeetingCodeFromUrl", () => {
  const coords = btoa(JSON.stringify({ meetingUrl: "x", meetingCode: "123456789012345", passcode: "p" }));
  const url = `https://teams.microsoft.com/light-meetings/launch?p=x&anon=true&agent=web&coords=${encodeURIComponent(coords)}`;

  it("reads meetingCode out of the base64 coords param of a meeting-ID join", () => {
    expect(parseTeamsMeetingCodeFromUrl(url)).toBe("meet:123456789012345");
  });

  it("returns null without coords, or when coords is not base64 JSON", () => {
    expect(parseTeamsMeetingCodeFromUrl("https://teams.microsoft.com/light-meetings/launch")).toBeNull();
    expect(parseTeamsMeetingCodeFromUrl("https://teams.microsoft.com/x?coords=%%%")).toBeNull();
    expect(parseTeamsMeetingCodeFromUrl(null)).toBeNull();
  });

  it("is the watcher's fallback only when no thread id is on the page", () => {
    const seen: string[] = [];
    new TeamsMeetingIdWatcher((id) => seen.push(id)).poll(fakeSources({ url }));
    expect(seen).toEqual(["meet:123456789012345"]);

    const seen2: string[] = [];
    new TeamsMeetingIdWatcher((id) => seen2.push(id)).poll(fakeSources({ url, documentText: () => THREAD_ID }));
    expect(seen2).toEqual([THREAD_ID]);
  });
});
