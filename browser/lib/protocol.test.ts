import { describe, expect, it } from "vitest";
import {
  BROWSER_TRIGGER,
  controlRequest,
  encodeBinaryFrame,
  INGEST_FORMAT,
  sanitizeLabel,
  sourceLabel,
} from "./protocol";

describe("sanitizeLabel", () => {
  it("keeps allowed characters", () => {
    expect(sanitizeLabel("Jane.Doe_1-2")).toBe("Jane.Doe_1-2");
  });
  it("replaces disallowed runs with a single dash", () => {
    expect(sanitizeLabel("jane doe!!@#123")).toBe("jane-doe-123");
  });
  it("trims leading/trailing dashes", () => {
    expect(sanitizeLabel("  hi  ")).toBe("hi");
    expect(sanitizeLabel("***")).toBe("unknown");
  });
  it("never returns empty", () => {
    expect(sanitizeLabel("")).toBe("unknown");
  });
});

describe("sourceLabel", () => {
  it("builds browser:<platform>:<participant>", () => {
    expect(sourceLabel("meet", "jane-a1b2")).toBe("browser:meet:jane-a1b2");
    expect(sourceLabel("teams", "Speaker 3")).toBe("browser:teams:Speaker-3");
  });
});

describe("encodeBinaryFrame", () => {
  it("frames [u8 idLen][id][pcm]", () => {
    const pcm = new Uint8Array([1, 2, 3, 4]);
    const frame = encodeBinaryFrame("s7", pcm);
    expect(frame[0]).toBe(2); // idLen
    expect(String.fromCharCode(frame[1]!, frame[2]!)).toBe("s7");
    expect([...frame.subarray(3)]).toEqual([1, 2, 3, 4]);
    expect(frame.length).toBe(1 + 2 + 4);
  });

  it("round-trips through the stub's parse", () => {
    const pcm = new Uint8Array([0xff, 0x00, 0x10, 0x20]);
    const frame = encodeBinaryFrame("s123", pcm);
    const idLen = frame[0]!;
    const streamId = new TextDecoder().decode(frame.subarray(1, 1 + idLen));
    const payload = frame.subarray(1 + idLen);
    expect(streamId).toBe("s123");
    expect([...payload]).toEqual([...pcm]);
  });

  it("rejects an over-long stream id (u8 length)", () => {
    expect(() => encodeBinaryFrame("s".repeat(256), new Uint8Array(0))).toThrow();
  });
});

describe("INGEST_FORMAT", () => {
  it("matches earsd AudioFormatSpec keys and v1 values", () => {
    expect(INGEST_FORMAT).toEqual({ sample_rate: 16000, channels: 1, encoding: "pcm_s16le" });
  });
});

describe("controlRequest", () => {
  it("builds meeting.resolve with the snake_case external_id key", () => {
    expect(controlRequest.meetingResolve("meet", "AbCdEf")).toEqual({
      cmd: "meeting.resolve",
      platform: "meet",
      external_id: "AbCdEf",
    });
  });

  it("builds session.open with the browser-extension trigger baked in", () => {
    expect(controlRequest.sessionOpen(["browser:meet:jane"], "meeting-uuid")).toEqual({
      cmd: "session.open",
      sources: ["browser:meet:jane"],
      slug: "meeting-uuid",
      trigger: BROWSER_TRIGGER,
    });
  });

  it("builds session.close and session.add_source", () => {
    expect(controlRequest.sessionClose("sid")).toEqual({ cmd: "session.close", id: "sid" });
    expect(controlRequest.sessionAddSource("sid", "browser:meet:jo")).toEqual({
      cmd: "session.add_source",
      id: "sid",
      source: "browser:meet:jo",
    });
  });
});
