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
  parseJitsiSlotSsrcs,
  readJitsiLocalName,
  type JitsiBridgeView,
  type JitsiRosterDom,
} from "./jitsi";
import { selectAdapter } from "./adapter";
import { noteBridgeMessage } from "./jitsi-colibri";
import type { RosterEntry } from "../protocol";

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

// The bridge peer connection's remote SDP as meet.jit.si sent it (2026-11-22):
// three audio slots, each SSRC named by its `a=ssrc:<ssrc> msid:` line.
const BRIDGE_SDP = [
  "v=0",
  "o=- 1923518516 2 IN IP4 0.0.0.0",
  "s=-",
  "t=0 0",
  "m=audio 9 UDP/TLS/RTP/SAVPF 111",
  "a=mid:0",
  "a=ssrc:1372919224 cname:mixed",
  "a=ssrc:1372919224 msid:remote-audio-1 remote-audio-1",
  "a=ssrc:2479650891 cname:mixed",
  "a=ssrc:2479650891 msid:remote-audio-2 remote-audio-2",
  "a=ssrc:391968325 cname:mixed",
  "a=ssrc:391968325 msid:remote-audio-3 remote-audio-3",
  "m=video 9 UDP/TLS/RTP/SAVPF 100",
  "a=mid:1",
  "a=ssrc:4444 msid:remote-video-1 remote-video-1",
  "",
].join("\r\n");

describe("parseJitsiSlotSsrcs", () => {
  it("maps each audio slot to its SSRC from the a=ssrc msid lines", () => {
    expect(parseJitsiSlotSsrcs(BRIDGE_SDP)).toEqual(
      new Map([
        ["remote-audio-1", 1372919224],
        ["remote-audio-2", 2479650891],
        ["remote-audio-3", 391968325],
      ]),
    );
  });

  it("falls back to a media-level a=msid when its section has exactly one SSRC", () => {
    const sdp = [
      "m=audio 9 UDP/TLS/RTP/SAVPF 111",
      "a=msid:remote-audio-4 remote-audio-4",
      "a=ssrc:77 cname:x",
      "m=audio 9 UDP/TLS/RTP/SAVPF 111",
      "a=msid:remote-audio-5 remote-audio-5",
      "a=ssrc:78 cname:x",
      "a=ssrc:79 cname:x",
    ].join("\n");
    expect(parseJitsiSlotSsrcs(sdp)).toEqual(new Map([["remote-audio-4", 77]]));
  });

  it("ignores endpoint-named MSIDs and empty input", () => {
    expect(parseJitsiSlotSsrcs("a=ssrc:5 msid:831de82b-audio-0-1 x")).toEqual(new Map());
    expect(parseJitsiSlotSsrcs("")).toEqual(new Map());
  });
});

/** A bridge the test drives: SDPs, slot owners, and the change listener. */
function fakeBridge(sdps: string[] = [BRIDGE_SDP]) {
  const owners = new Map<number, string>();
  let listener: (() => void) | null = null;
  const view: JitsiBridgeView = {
    remoteSdps: () => sdps,
    audioOwner: (ssrc) => owners.get(ssrc) ?? null,
    listen: (cb) => {
      listener = cb;
    },
    unlisten: (cb) => {
      if (listener === cb) listener = null;
    },
  };
  return {
    view,
    sdps,
    /** The bridge announces `owner` on `ssrc` (an AudioSourcesMap entry). */
    map(ssrc: number, owner: string) {
      owners.set(ssrc, owner);
      listener?.();
    },
    get listening() {
      return listener !== null;
    },
  };
}

describe("JitsiAdapter SSRC-rewriting slots", () => {
  const slotTrack = (id: string) => ({ id }) as MediaStreamTrack;
  const stream = (id: string) => ({ id }) as MediaStream;
  const quiet = () => vi.spyOn(console, "debug").mockImplementation(() => {});

  function adapter(bridge: ReturnType<typeof fakeBridge>, local: () => string | null = () => null) {
    const a = new JitsiAdapter(() => null, local, bridge.view);
    const identities: Array<[string, string]> = [];
    const reassigned: string[] = [];
    a.onIdentity((trackId, id) => identities.push([trackId, id]));
    a.onTrackReassigned((trackId) => reassigned.push(trackId));
    return { a, identities, reassigned };
  }

  it("names a slot at admission when the bridge has already mapped it (the initial map)", () => {
    quiet();
    const bridge = fakeBridge();
    bridge.map(391968325, "85b964a6");
    const { a } = adapter(bridge);
    expect(a.identify(slotTrack("remote-audio-3"), stream("remote-audio-3"))).toBe("85b964a6");
    expect(a.identify(slotTrack("remote-audio-1"), stream("remote-audio-1"))).toBeNull();
  });

  it("names an anonymous slot when its owner arrives", () => {
    quiet();
    const bridge = fakeBridge();
    const { a, identities, reassigned } = adapter(bridge);
    expect(a.identify(slotTrack("remote-audio-2"), stream("remote-audio-2"))).toBeNull();
    bridge.map(2479650891, "4494e60c");
    bridge.map(2479650891, "4494e60c"); // a repeat is not news
    expect(identities).toEqual([["remote-audio-2", "4494e60c"]]);
    expect(reassigned).toEqual([]);
  });

  it("reports a reused slot as reassigned, and names the new owner on the next identify", () => {
    quiet();
    const bridge = fakeBridge();
    bridge.map(1372919224, "aaaa0001");
    const { a, identities, reassigned } = adapter(bridge);
    const track = slotTrack("remote-audio-1");
    expect(a.identify(track, stream("remote-audio-1"))).toBe("aaaa0001");
    bridge.map(1372919224, "bbbb0002");
    expect(reassigned).toEqual(["remote-audio-1"]);
    expect(identities).toEqual([]);
    // The capture layer re-identifies the track under its fresh handle.
    expect(a.identify(track, stream("remote-audio-1"))).toBe("bbbb0002");
    a.pollIdentities();
    expect(reassigned).toEqual(["remote-audio-1"]); // once per change
    bridge.map(1372919224, "aaaa0001"); // and back again
    expect(reassigned).toEqual(["remote-audio-1", "remote-audio-1"]);
  });

  it("picks up a slot whose SDP lands after its map, on the next poll", () => {
    quiet();
    const sdps: string[] = [];
    const bridge = fakeBridge(sdps);
    bridge.map(391968325, "85b964a6");
    const { a, identities } = adapter(bridge);
    expect(a.identify(slotTrack("remote-audio-3"), stream("remote-audio-3"))).toBeNull();
    sdps.push(BRIDGE_SDP);
    a.pollIdentities();
    expect(identities).toEqual([["remote-audio-3", "85b964a6"]]);
  });

  it("never binds a slot to the local endpoint", () => {
    quiet();
    const bridge = fakeBridge();
    bridge.map(391968325, "831de82b");
    const { a, identities, reassigned } = adapter(bridge, () => "831de82b");
    expect(a.identify(slotTrack("remote-audio-3"), stream("remote-audio-3"))).toBeNull();
    a.pollIdentities();
    bridge.map(1372919224, "831de82b");
    expect(identities).toEqual([]);
    expect(reassigned).toEqual([]);
  });

  it("stops listening on dispose", () => {
    quiet();
    const bridge = fakeBridge();
    const { a, identities } = adapter(bridge);
    a.identify(slotTrack("remote-audio-1"), stream("remote-audio-1"));
    expect(bridge.listening).toBe(true);
    a.dispose();
    expect(bridge.listening).toBe(false);
    bridge.map(1372919224, "aaaa0001");
    a.pollIdentities();
    expect(identities).toEqual([]);
  });
});

describe("JitsiAdapter with the live bridge-channel state", () => {
  type W = { window?: unknown; __earsJitsiLocalEndpoint?: string; __earsJitsiAudioOwners?: unknown };
  const g = globalThis as unknown as W;

  function withWindow(fn: () => void): void {
    const saved = g.window;
    g.window = globalThis;
    const debug = vi.spyOn(console, "debug").mockImplementation(() => {});
    try {
      fn();
    } finally {
      g.window = saved;
      delete g.__earsJitsiLocalEndpoint;
      delete g.__earsJitsiAudioOwners;
      debug.mockRestore();
    }
  }

  it("flags you from a SenderSourceConstraints message for your video", () => {
    withWindow(() => {
      const a = new JitsiAdapter(() => fakeDom([{ id: "participant_85b964a6_name", textContent: "Ada" }], { textContent: "Tom (me)" }));
      const batches: unknown[] = [];
      a.onRoster((e) => batches.push(e));
      noteBridgeMessage('{"colibriClass":"SenderSourceConstraints","sourceName":"831de82b-v0","maxHeight":360}');
      a.pollIdentities();
      expect(batches).toEqual([
        [
          { participantId: "85b964a6", displayName: "Ada" },
          { participantId: "831de82b", displayName: "Tom", isLocal: true },
        ],
      ]);
    });
  });

  it("flags nobody with the camera off: no SenderSourceConstraints, no local id", () => {
    withWindow(() => {
      const a = new JitsiAdapter(() => fakeDom([{ id: "participant_85b964a6_name", textContent: "Ada" }], { textContent: "Tom (me)" }));
      const batches: RosterEntry[][] = [];
      a.onRoster((e) => batches.push(e));
      // Other traffic names other endpoints; none of it is taken as you.
      noteBridgeMessage('{"colibriClass":"DominantSpeakerEndpointChangeEvent","dominantSpeakerEndpoint":"85b964a6"}');
      noteBridgeMessage('{"colibriClass":"EndpointStats","from":"85b964a6"}');
      a.pollIdentities();
      expect(batches.flat().some((e) => e.isLocal)).toBe(false);
    });
  });
});
