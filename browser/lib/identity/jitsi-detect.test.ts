import { describe, expect, it } from "vitest";
import { describeJitsiSignal, detectJitsi } from "./jitsi-detect";

describe("detectJitsi", () => {
  it("finds nothing on an ordinary page", () => {
    expect(
      detectJitsi({
        hasJitsiMeetJSGlobal: false,
        scriptSrcs: ["https://example.org/static/js/main.3f2a.js", "https://example.org/config.js"],
        resourceUrls: ["https://example.org/api/v1/rooms", "https://cdn.example.org/react.min.js"],
        remoteAudioStreamIds: ["{a1b2c3d4-uuid}", "default"],
      }),
    ).toBeNull();
    expect(detectJitsi({})).toBeNull();
  });

  it("recognises lib-jitsi-meet's global", () => {
    expect(detectJitsi({ hasJitsiMeetJSGlobal: true })).toBe("global");
  });

  it("recognises the library script, with or without a cache-buster", () => {
    expect(detectJitsi({ scriptSrcs: ["https://jitsi.example.org/libs/lib-jitsi-meet.min.js?v=7834"] })).toBe(
      "script",
    );
    expect(detectJitsi({ scriptSrcs: ["https://cdn.example.org/lib-jitsi-meet.js"] })).toBe("script");
    expect(detectJitsi({ scriptSrcs: ["https://example.org/not-lib-jitsi-meet-docs.html"] })).toBeNull();
  });

  it("recognises Jitsi's network traffic", () => {
    expect(
      detectJitsi({ resourceUrls: ["https://jitsi.example.org/conference-request/v1?room=standup"] }),
    ).toBe("network");
    expect(detectJitsi({ resourceUrls: ["https://jitsi.example.org/libs/lib-jitsi-meet.min.js?v=1"] })).toBe(
      "network",
    );
    expect(detectJitsi({ resourceUrls: ["https://example.org/conference-request/v10"] })).toBeNull();
  });

  it("recognises Jitsi's audio stream ids", () => {
    expect(detectJitsi({ remoteAudioStreamIds: ["831de82b-audio-0-1"] })).toBe("audio");
    expect(detectJitsi({ remoteAudioStreamIds: ["mixedmslabel"] })).toBe("audio");
    // Too loose to count on its own: a non-hex owner, or no connection index.
    expect(detectJitsi({ remoteAudioStreamIds: ["alice-audio-0-1", "831de82b-audio-0"] })).toBeNull();
  });

  it("names each signal", () => {
    for (const s of ["global", "script", "network", "audio"] as const) {
      expect(describeJitsiSignal(s)).toMatch(/\w/);
    }
  });
});
