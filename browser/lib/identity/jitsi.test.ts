import { describe, expect, it, vi } from "vitest";
import {
  JitsiAdapter,
  JitsiMeetingTitleWatcher,
  extractJitsiMeetingTitle,
  harvestJitsiRoster,
  isJitsiHost,
  isJitsiSlotStream,
  parseJitsiEndpointId,
  parseJitsiRoom,
  readJitsiLocalName,
  type JitsiRosterDom,
} from "./jitsi";
import { selectAdapter } from "./adapter";

describe("isJitsiHost", () => {
  it("matches the hosted deployments only", () => {
    expect(isJitsiHost("meet.jit.si")).toBe(true);
    expect(isJitsiHost("8x8.vc")).toBe(true);
    expect(isJitsiHost("jitsi.example.org")).toBe(false);
    expect(isJitsiHost("notmeet.jit.si.evil.com")).toBe(false);
  });

  it("is what selectAdapter picks for those hosts", () => {
    expect(selectAdapter("meet.jit.si")?.platform).toBe("jitsi");
    expect(selectAdapter("8x8.vc")?.platform).toBe("jitsi");
  });
});

describe("parseJitsiRoom", () => {
  it("keys the room by host and lower-cases it", () => {
    expect(parseJitsiRoom("https://meet.jit.si/WeeklyStandup")).toBe("meet.jit.si/weeklystandup");
  });

  it("keeps the tenant on multi-tenant deployments", () => {
    expect(parseJitsiRoom("https://8x8.vc/vpaas-magic-cookie-abc123/SampleRoom")).toBe(
      "8x8.vc/vpaas-magic-cookie-abc123/sampleroom",
    );
  });

  it("decodes percent-encoding", () => {
    expect(parseJitsiRoom("https://meet.jit.si/Caf%C3%A9Talk")).toBe("meet.jit.si/cafétalk");
  });

  it("never reads the JWT or config overrides", () => {
    expect(parseJitsiRoom("https://meet.jit.si/Room?jwt=eyJhbGci#config.startWithAudioMuted=true")).toBe(
      "meet.jit.si/room",
    );
  });

  it("returns null for pages that are not rooms", () => {
    expect(parseJitsiRoom("https://meet.jit.si/")).toBeNull();
    expect(parseJitsiRoom("https://meet.jit.si/static/close3.html")).toBeNull();
    expect(parseJitsiRoom("https://meet.jit.si/config.js")).toBeNull();
    expect(parseJitsiRoom("https://meet.jit.si/external_api.js")).toBeNull();
    expect(parseJitsiRoom("https://meet.jit.si/libs/app.bundle.min.js")).toBeNull();
    expect(parseJitsiRoom("https://meet.jit.si/_unlock")).toBeNull();
    expect(parseJitsiRoom("https://meet.jit.si/a/b/c")).toBeNull();
    expect(parseJitsiRoom("https://meet.jit.si/%E0%A4%A")).toBeNull();
    expect(parseJitsiRoom("not a url")).toBeNull();
    expect(parseJitsiRoom(undefined)).toBeNull();
  });
});

describe("parseJitsiEndpointId", () => {
  it("reads the endpoint id from a munged MSID", () => {
    expect(parseJitsiEndpointId("831de82b-audio-0-1")).toBe("831de82b");
    expect(parseJitsiEndpointId("831de82b-audio-0-2")).toBe("831de82b"); // P2P connection
    expect(parseJitsiEndpointId("831de82b-audio-0")).toBe("831de82b"); // older builds
    expect(parseJitsiEndpointId("831de82b-audio-1-1")).toBe("831de82b"); // second audio source
  });

  it("accepts non-hex endpoint ids", () => {
    expect(parseJitsiEndpointId("jigasi-a1b2-audio-0-1")).toBe("jigasi-a1b2");
  });

  it("returns null for streams that name no participant", () => {
    expect(parseJitsiEndpointId("mixedmslabel")).toBeNull();
    expect(parseJitsiEndpointId("default")).toBeNull();
    expect(parseJitsiEndpointId("remote-audio-3")).toBeNull();
    expect(parseJitsiEndpointId("831de82b-video-0-1")).toBeNull();
    expect(parseJitsiEndpointId("{0f3a-uuid}")).toBeNull();
    expect(parseJitsiEndpointId("")).toBeNull();
    expect(parseJitsiEndpointId(null)).toBeNull();
  });

  it("recognises SSRC-rewriting slots", () => {
    expect(isJitsiSlotStream("remote-audio-1")).toBe(true);
    expect(isJitsiSlotStream("831de82b-audio-0-1")).toBe(false);
  });
});

function fakeDom(
  els: Array<{ id: string; textContent: string | null }>,
  local: { textContent: string | null } | null = null,
): JitsiRosterDom {
  return {
    querySelectorAll: (selector) => {
      expect(selector).toBe('[id^="participant_"][id$="_name"]');
      return els;
    },
    querySelector: (selector) => {
      expect(selector).toBe("#localDisplayName");
      return local;
    },
  };
}

describe("readJitsiLocalName", () => {
  it("reads your name without the (me) suffix", () => {
    expect(readJitsiLocalName(fakeDom([], { textContent: " Tom  Elliot (me) " }))).toBe("Tom Elliot");
    expect(readJitsiLocalName(fakeDom([], { textContent: "Tom" }))).toBe("Tom");
  });

  it("returns null for the placeholder, an empty label, or no label", () => {
    expect(readJitsiLocalName(fakeDom([], { textContent: "me" }))).toBeNull();
    expect(readJitsiLocalName(fakeDom([], { textContent: "" }))).toBeNull();
    expect(readJitsiLocalName(fakeDom([], null))).toBeNull();
  });
});

describe("harvestJitsiRoster", () => {
  it("reads remote names from tile labels", () => {
    const dom = fakeDom([
      { id: "participant_831de82b_name", textContent: " Ada  Lovelace " },
      { id: "participant_07af8d49_name", textContent: "Grace Hopper" },
    ]);
    expect(harvestJitsiRoster(dom)).toEqual([
      { participantId: "831de82b", displayName: "Ada Lovelace" },
      { participantId: "07af8d49", displayName: "Grace Hopper" },
    ]);
  });

  it("skips placeholder names and screen-share tiles", () => {
    const dom = fakeDom([
      { id: "participant_831de82b_name", textContent: "Fellow Jitster" },
      { id: "participant_07af8d49-v1_name", textContent: "Grace Hopper" },
      { id: "participant_95edea8d_name", textContent: "" },
      { id: "participant_95edea8d_name", textContent: null },
    ]);
    expect(harvestJitsiRoster(dom)).toEqual([]);
  });
});

describe("extractJitsiMeetingTitle", () => {
  it("prefers the subject header", () => {
    expect(extractJitsiMeetingTitle("Quarterly planning", "Weekly Standup | Jitsi Meet")).toBe("Quarterly planning");
  });

  it("falls back to the tab title without the product name", () => {
    expect(extractJitsiMeetingTitle(null, "Weekly Standup | Jitsi Meet")).toBe("Weekly Standup");
    expect(extractJitsiMeetingTitle("", "(2) Weekly Standup | 8x8")).toBe("Weekly Standup");
  });

  it("treats product names as no name", () => {
    expect(extractJitsiMeetingTitle("Jitsi Meet", "Jitsi Meet")).toBeNull();
    expect(extractJitsiMeetingTitle(undefined, "")).toBeNull();
  });
});

describe("JitsiMeetingTitleWatcher", () => {
  it("reports the first name once", () => {
    const seen: string[] = [];
    const w = new JitsiMeetingTitleWatcher((t) => seen.push(t));
    const doc = { title: "Jitsi Meet", querySelector: () => null };
    w.poll(doc);
    expect(w.title).toBeNull();
    doc.title = "Weekly Standup | Jitsi Meet";
    w.poll(doc);
    doc.title = "Something Else | Jitsi Meet";
    w.poll(doc);
    expect(seen).toEqual(["Weekly Standup"]);
  });
});

describe("JitsiAdapter", () => {
  const track = {} as MediaStreamTrack;
  const stream = (id: string) => ({ id }) as MediaStream;

  it("identifies a track by its stream's endpoint id", () => {
    const a = new JitsiAdapter(() => null);
    expect(a.identify(track, stream("831de82b-audio-0-1"))).toBe("831de82b");
    expect(a.identify(track, stream("mixedmslabel"))).toBeNull();
  });

  it("logs once, and still returns null, for SSRC-rewriting slots", () => {
    const debug = vi.spyOn(console, "debug").mockImplementation(() => {});
    const a = new JitsiAdapter(() => null);
    expect(a.identify(track, stream("remote-audio-1"))).toBeNull();
    expect(a.identify(track, stream("remote-audio-2"))).toBeNull();
    expect(debug).toHaveBeenCalledTimes(1);
    debug.mockRestore();
  });

  it("emits only new or changed roster entries", () => {
    const els = [{ id: "participant_831de82b_name", textContent: "Ada" }];
    const a = new JitsiAdapter(() => fakeDom(els));
    const batches: unknown[] = [];
    a.onRoster((e) => batches.push(e));
    a.pollIdentities();
    a.pollIdentities();
    els[0]!.textContent = "Ada Lovelace";
    a.pollIdentities();
    expect(batches).toEqual([
      [{ participantId: "831de82b", displayName: "Ada" }],
      [{ participantId: "831de82b", displayName: "Ada Lovelace" }],
    ]);
    expect(a.displayName("831de82b")).toBe("Ada Lovelace");
  });

  it("reports you with isLocal once the endpoint id and your name are both known", () => {
    const els = [{ id: "participant_4494e60c_name", textContent: "Ada" }];
    const local = { textContent: "me" };
    let endpoint: string | null = null;
    const a = new JitsiAdapter(
      () => fakeDom(els, local),
      () => endpoint,
    );
    const batches: unknown[] = [];
    a.onRoster((e) => batches.push(e));
    a.pollIdentities(); // remote only: no endpoint id yet
    endpoint = "831de82b";
    a.pollIdentities(); // endpoint id, but you set no name yet
    local.textContent = "Tom (me)";
    a.pollIdentities();
    a.pollIdentities(); // nothing changed
    local.textContent = "Tom Elliot (me)";
    a.pollIdentities();
    expect(batches).toEqual([
      [{ participantId: "4494e60c", displayName: "Ada" }],
      [{ participantId: "831de82b", displayName: "Tom", isLocal: true }],
      [{ participantId: "831de82b", displayName: "Tom Elliot", isLocal: true }],
    ]);
    expect(a.displayName("831de82b")).toBe("Tom Elliot");
  });

  it("reports you again under a new endpoint id after a rejoin", () => {
    let endpoint = "831de82b";
    const a = new JitsiAdapter(
      () => fakeDom([], { textContent: "Tom (me)" }),
      () => endpoint,
    );
    const batches: unknown[] = [];
    a.onRoster((e) => batches.push(e));
    a.pollIdentities();
    endpoint = "5c1a7f02";
    a.pollIdentities();
    expect(batches).toEqual([
      [{ participantId: "831de82b", displayName: "Tom", isLocal: true }],
      [{ participantId: "5c1a7f02", displayName: "Tom", isLocal: true }],
    ]);
  });

  it("never names a remote tile or a remote track after the local endpoint", () => {
    const debug = vi.spyOn(console, "debug").mockImplementation(() => {});
    const els = [
      { id: "participant_831de82b_name", textContent: "Impostor" },
      { id: "participant_4494e60c_name", textContent: "Ada" },
    ];
    const a = new JitsiAdapter(
      () => fakeDom(els, null),
      () => "831de82b",
    );
    const batches: unknown[] = [];
    a.onRoster((e) => batches.push(e));
    a.pollIdentities();
    expect(batches).toEqual([[{ participantId: "4494e60c", displayName: "Ada" }]]);
    expect(a.identify(track, stream("831de82b-audio-0-1"))).toBeNull();
    expect(a.identify(track, stream("4494e60c-audio-0-1"))).toBe("4494e60c");
    debug.mockRestore();
  });

  it("is inert after dispose", () => {
    const a = new JitsiAdapter(() => fakeDom([{ id: "participant_831de82b_name", textContent: "Ada" }]));
    const cb = vi.fn();
    a.onRoster(cb);
    a.dispose();
    a.pollIdentities();
    expect(cb).not.toHaveBeenCalled();
  });
});
