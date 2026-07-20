import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import {
  BROWSER_TRIGGER,
  controlRequest,
  encodeBinaryFrame,
  INGEST_FORMAT,
  PROTOCOL_VERSION,
  sanitizeLabel,
  sourceLabel,
} from "./protocol";

// The golden wire fixtures shared with the Swift suite
// (daemon/Tests/EarsCoreTests/ControlProtocolV2FixtureTests.swift) — the same
// JSON frames decoded/encoded by both sides, so the two codecs can't drift.
const fixtures = JSON.parse(
  readFileSync(
    join(dirname(fileURLToPath(import.meta.url)), "../../shared/protocol-fixtures/control-v2.json"),
    "utf8",
  ),
) as {
  requests: Array<{ name: string; frame: Record<string, unknown> }>;
  responses: Array<{ name: string; frame: Record<string, unknown> }>;
  events: Array<{ name: string; frame: Record<string, unknown> }>;
};

function fixture(kind: "requests" | "responses" | "events", name: string): Record<string, unknown> {
  const found = fixtures[kind].find((f) => f.name === name);
  if (!found) throw new Error(`no fixture ${kind}/${name}`);
  return found.frame;
}

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
  it("matches earsd AudioFormatSpec keys and v1 values (ingest is out of v2 scope)", () => {
    expect(INGEST_FORMAT).toEqual({ sample_rate: 16000, channels: 1, encoding: "pcm_s16le" });
  });
});

describe("controlRequest builders match the golden fixtures", () => {
  it("hello", () => {
    expect(controlRequest.hello(1, "browser-extension/0.1.0")).toEqual(
      fixture("requests", "hello"),
    );
    expect(PROTOCOL_VERSION).toBe(2);
  });

  it("subscribe with a telemetry filter", () => {
    expect(controlRequest.subscribe(2, ["job"])).toEqual(
      fixture("requests", "subscribe-job-filter"),
    );
  });

  it("meeting.start carries identity and the browser-extension trigger", () => {
    expect(controlRequest.meetingStart(3, "meet", "abc-defg-hij")).toEqual(
      fixture("requests", "meeting.start-browser"),
    );
    expect(BROWSER_TRIGGER).toBe("browser-extension");
  });

  it("meeting.pause / meeting.resume / meeting.end reference the meeting id", () => {
    const meeting = "0d5e1111-aaaa-bbbb-cccc-222233334444";
    expect(controlRequest.meetingPause(5, meeting)).toEqual(fixture("requests", "meeting.pause"));
    expect(controlRequest.meetingResume(6, meeting)).toEqual(fixture("requests", "meeting.resume"));
    expect(controlRequest.meetingEnd(7, meeting)).toEqual(fixture("requests", "meeting.end"));
  });

  it("meeting.attendee upsert (display name + source link)", () => {
    expect(
      controlRequest.meetingAttendee(9, "0d5e1111-aaaa-bbbb-cccc-222233334444", {
        id: "spaces/x/devices/y",
        display_name: "Jane Doe",
        source: "browser:meet:jane-a1b2",
      }),
    ).toEqual(fixture("requests", "meeting.attendee-upsert"));
  });
});

describe("fixture frames parse into the shapes the transport consumes", () => {
  it("hello result advertises this transport's capability tier", () => {
    const result = fixture("responses", "hello-result").result as {
      protocol: number;
      boot_id: string;
      capabilities: string[];
    };
    expect(result.protocol).toBe(PROTOCOL_VERSION);
    expect(result.boot_id).toBeTruthy();
    expect(result.capabilities).toEqual(["observe", "meetings"]);
  });

  it("meeting result carries intervals-as-marks with a null open end", () => {
    const meeting = fixture("responses", "meeting-result").result as {
      state: string;
      intervals: Array<{ start: string; end: string | null }>;
      rev: number;
    };
    expect(meeting.state).toBe("active");
    expect(meeting.intervals.at(-1)!.end).toBeNull();
    expect(meeting.rev).toBeGreaterThan(0);
  });

  it("error frames carry a stable machine-readable code", () => {
    const error = fixture("responses", "error-meeting-not-found").error as { code: string };
    expect(error.code).toBe("meeting_not_found");
  });

  it("state events carry rev; telemetry events don't", () => {
    expect(fixture("events", "meeting-event").rev).toBe(43);
    expect(fixture("events", "source-event").rev).toBe(44);
    expect(fixture("events", "vad-event").rev).toBeUndefined();
    expect(fixture("events", "segment-event").rev).toBeUndefined();
    expect(fixture("events", "job-event").rev).toBeUndefined();
  });
});
