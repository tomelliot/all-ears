import { describe, expect, it } from "vitest";
import {
  JITSI_DETECT_BUDGET_MS,
  JITSI_MAX_RESOURCE_ENTRIES,
  JITSI_MAX_URL_LENGTH,
  JitsiDetector,
  describeJitsiSignal,
  detectJitsi,
  hasJitsiMeetJSGlobal,
  type JitsiDetectionResult,
} from "./jitsi-detect";

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

function detector(clock: { t: number } = { t: 0 }) {
  const results: JitsiDetectionResult[] = [];
  const d = new JitsiDetector(() => clock.t, (r) => results.push(r));
  return { d, results, clock };
}

describe("JitsiDetector", () => {
  it("reports a match once and then ignores input", () => {
    const { d, results } = detector();
    d.feed({ scriptSrcs: ["https://x.example/app.js"] });
    expect(d.active).toBe(true);
    d.feed({ resourceUrls: ["https://x.example/libs/lib-jitsi-meet.min.js"] });
    d.feed({ hasJitsiMeetJSGlobal: true });
    expect(results).toEqual([{ signal: "network", checks: 2, spentMs: 0 }]);
    expect(d.active).toBe(false);
  });

  it("gives up for good once the time budget is spent", () => {
    const clock = { t: 0 };
    const results: JitsiDetectionResult[] = [];
    // Each check "takes" 5 ms (the clock advances on every read).
    const d = new JitsiDetector(
      () => (clock.t += 5),
      (r) => results.push(r),
    );
    for (let i = 0; i < 10; i++) d.feed({ scriptSrcs: ["https://x.example/app.js"] });
    expect(results).toHaveLength(1);
    expect(results[0]).toMatchObject({ signal: null, reason: "time budget" });
    expect(results[0]!.spentMs).toBeGreaterThanOrEqual(JITSI_DETECT_BUDGET_MS);
    d.feed({ hasJitsiMeetJSGlobal: true });
    expect(results).toHaveLength(1);
  });

  it("stops examining resources past the cap but keeps the audio signal", () => {
    const { d, results } = detector();
    const filler = Array.from({ length: JITSI_MAX_RESOURCE_ENTRIES }, (_, i) => `https://x.example/r${i}`);
    d.feed({ resourceUrls: filler });
    expect(d.resourcesExhausted).toBe(true);
    d.feed({ resourceUrls: ["https://x.example/conference-request/v1"] });
    expect(results).toEqual([]);
    d.feed({ remoteAudioStreamIds: ["831de82b-audio-0-1"] });
    expect(results[0]).toMatchObject({ signal: "audio" });
  });

  it("skips oversized URLs instead of parsing them", () => {
    const huge = `https://x.example/libs/lib-jitsi-meet.min.js?${"a".repeat(JITSI_MAX_URL_LENGTH)}`;
    expect(detectJitsi({ resourceUrls: [huge], scriptSrcs: [huge] })).toBeNull();
  });

  it("stays cheap on a large page", () => {
    const urls = Array.from({ length: JITSI_MAX_RESOURCE_ENTRIES }, (_, i) => `https://cdn.example.org/a/b/c/${i}.js?v=${i}`);
    const t0 = performance.now();
    detectJitsi({ resourceUrls: urls, scriptSrcs: urls.slice(0, 300) });
    // Generous bound for slow CI; this whole worst case measured ~2 ms locally.
    expect(performance.now() - t0).toBeLessThan(200);
  });
});

describe("hasJitsiMeetJSGlobal", () => {
  it("reads plain data properties", () => {
    expect(hasJitsiMeetJSGlobal({ JitsiMeetJS: { version: "abc123" } })).toBe(true);
    expect(hasJitsiMeetJSGlobal({ JitsiMeetJS: { version: 3 } })).toBe(false);
    expect(hasJitsiMeetJSGlobal({})).toBe(false);
  });

  it("never invokes a page-defined getter", () => {
    let called = false;
    const win = {};
    Object.defineProperty(win, "JitsiMeetJS", {
      get() {
        called = true;
        for (;;); // would hang if read
      },
    });
    expect(hasJitsiMeetJSGlobal(win)).toBe(false);
    const lib = {};
    Object.defineProperty(lib, "version", {
      get() {
        called = true;
        throw new Error("boom");
      },
    });
    expect(hasJitsiMeetJSGlobal({ JitsiMeetJS: lib })).toBe(false);
    expect(called).toBe(false);
  });
});
