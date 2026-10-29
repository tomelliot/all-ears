import { describe, expect, it } from "vitest";
import { diagnoseSilentTrack, type PeerConnectionLike, type ReceiverLike } from "./silent-diagnosis";

// Hand-rolled fakes (no jsdom), matching the other capture tests.

function inbound(id: string, packets: number, samples: number): [string, Record<string, unknown>][] {
  return [
    [id, { type: "inbound-rtp", kind: "audio", packetsReceived: packets, bytesReceived: packets * 100, totalSamplesReceived: samples, concealedSamples: 0, audioLevel: 0.1, codecId: `c-${id}` }],
    [`c-${id}`, { type: "codec", mimeType: "audio/opus" }],
  ];
}

function receiver(trackId: string, stats: [string, Record<string, unknown>][], transform?: unknown): ReceiverLike {
  return { track: { id: trackId }, transform, getStats: async () => new Map(stats) };
}

const track = { id: "mainAudio-1", muted: false, readyState: "live" };
const pc = (...receivers: ReceiverLike[]): PeerConnectionLike => ({ getReceivers: () => receivers });

describe("diagnoseSilentTrack", () => {
  it("blames the frame source when the receiver decodes audio", async () => {
    const d = await diagnoseSilentTrack(track, [pc(receiver("mainAudio-1", inbound("a", 500, 48000)))], []);
    expect(d.receiverFound).toBe(true);
    expect(d.self).toMatchObject({ packetsReceived: 500, totalSamplesReceived: 48000, codec: "audio/opus" });
    expect(d.verdict).toMatch(/frame source is broken/);
  });

  it("names an encoded transform when RTP arrives but nothing decodes", async () => {
    const d = await diagnoseSilentTrack(track, [pc(receiver("mainAudio-1", inbound("a", 500, 0), {}))], []);
    expect(d.receiverTransform).toBe(true);
    expect(d.verdict).toMatch(/encoded transform/);
  });

  it("spots audio arriving on another receiver", async () => {
    const d = await diagnoseSilentTrack(
      track,
      [pc(receiver("mainAudio-1", inbound("a", 0, 0)), receiver("other", inbound("b", 300, 9000)))],
      [],
    );
    expect(d.others).toHaveLength(1);
    expect(d.verdict).toMatch(/another receiver/);
  });

  it("says the far end is not WebRTC media when no receiver gets RTP audio", async () => {
    const d = await diagnoseSilentTrack(track, [pc(receiver("mainAudio-1", []))], []);
    expect(d.self).toBeNull();
    expect(d.verdict).toMatch(/not delivered as WebRTC media/);
  });

  it("counts media elements playing the track and survives a throwing getStats", async () => {
    const broken: ReceiverLike = { track: { id: "mainAudio-1" }, getStats: () => Promise.reject(new Error("x")) };
    const el = { srcObject: { getTracks: () => [{ id: "mainAudio-1" }] } };
    const d = await diagnoseSilentTrack(track, [pc(broken)], [el, { srcObject: null }]);
    expect(d.elementsWithTrack).toBe(1);
    expect(d.receiverFound).toBe(true);
  });

  it("reports no live peer connection", async () => {
    expect((await diagnoseSilentTrack(track, [], [])).verdict).toBe("no live peer connection");
  });
});
