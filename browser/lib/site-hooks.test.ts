import { describe, expect, it } from "vitest";
import {
  hostOfPattern,
  matchPatternForUrl,
  parseSiteHookPatterns,
  patternsForFrames,
  platformForHost,
  siteHookScripts,
} from "./site-hooks";

describe("matchPatternForUrl", () => {
  it("covers the origin and drops path and port", () => {
    expect(matchPatternForUrl("https://app.cal.com/video/abc?x=1")).toBe("https://app.cal.com/*");
    expect(matchPatternForUrl("http://localhost:3000/room")).toBe("http://localhost/*");
  });

  it("refuses built-in hosts, which the manifest already hooks", () => {
    expect(matchPatternForUrl("https://meet.google.com/abc-defg-hij")).toBeNull();
    expect(matchPatternForUrl("https://us05web.zoom.us/wc/1/join")).toBeNull();
    expect(matchPatternForUrl("https://teams.microsoft.com/v2/")).toBeNull();
    expect(matchPatternForUrl("https://meetco.daily.co/room")).toBeNull();
    expect(matchPatternForUrl("https://meet.jit.si/WeeklyStandup")).toBeNull();
    expect(matchPatternForUrl("https://8x8.vc/vpaas-magic-cookie-x/room")).toBeNull();
    // Self-hosted Jitsi is not built in: the popup enables it per site.
    expect(matchPatternForUrl("https://jitsi.example.org/room")).toBe("https://jitsi.example.org/*");
  });

  it("refuses non-web schemes and garbage", () => {
    expect(matchPatternForUrl("chrome://extensions")).toBeNull();
    expect(matchPatternForUrl("about:blank")).toBeNull();
    expect(matchPatternForUrl("")).toBeNull();
  });
});

describe("patternsForFrames", () => {
  it("puts the top origin first and dedupes iframe origins", () => {
    expect(
      patternsForFrames("https://app.example.com/video/x", [
        "https://call.example.net/room",
        "about:blank",
        "https://call.example.net/other",
        "https://app.example.com/embed",
        "https://meetco.daily.co/room",
      ]),
    ).toEqual(["https://app.example.com/*", "https://call.example.net/*"]);
  });
});

describe("parseSiteHookPatterns", () => {
  it("keeps well-formed origin patterns only", () => {
    expect(
      parseSiteHookPatterns(["https://a.com/*", "https://a.com/*", "https://*/*", "https://b.com/path", 3, null]),
    ).toEqual(["https://a.com/*"]);
  });

  it("drops patterns for hosts that have become built-in", () => {
    expect(parseSiteHookPatterns(["https://app.cal.com/*", "https://meetco.daily.co/*"])).toEqual([
      "https://app.cal.com/*",
    ]);
  });

  it("reads anything malformed as empty", () => {
    expect(parseSiteHookPatterns(undefined)).toEqual([]);
    expect(parseSiteHookPatterns("https://a.com/*")).toEqual([]);
  });
});

describe("hostOfPattern", () => {
  it("strips scheme and wildcard path", () => {
    expect(hostOfPattern("https://cal.daily.co/*")).toBe("cal.daily.co");
  });
});

describe("siteHookScripts", () => {
  it("mirrors the manifest entries: relay isolated, hook in MAIN, both at document_start in all frames", () => {
    const [relay, hook] = siteHookScripts(["https://a.com/*"]);
    expect(relay).toMatchObject({ js: ["content-scripts/content.js"], allFrames: true, runAt: "document_start" });
    expect(relay).not.toHaveProperty("world");
    expect(hook).toMatchObject({
      js: ["content-scripts/hook.js"],
      world: "MAIN",
      allFrames: true,
      runAt: "document_start",
      matches: ["https://a.com/*"],
    });
  });
});

describe("platformForHost", () => {
  it("names the built-in platforms", () => {
    expect(platformForHost("meet.google.com", null)).toBe("meet");
    expect(platformForHost("us05web.zoom.us", null)).toBe("zoom");
    expect(platformForHost("teams.microsoft.com", null)).toBe("teams");
  });

  it("keeps localhost on teams for the dev harness", () => {
    expect(platformForHost("localhost", null)).toBe("teams");
    expect(platformForHost("127.0.0.1", null)).toBe("teams");
  });

  it("tags any other host as web", () => {
    expect(platformForHost("app.cal.com", null)).toBe("web");
  });

  it("defers to the adapter when there is one", () => {
    expect(platformForHost("app.cal.com", { platform: "meet" })).toBe("meet");
  });
});
