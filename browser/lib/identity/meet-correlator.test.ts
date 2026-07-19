import { describe, expect, it } from "vitest";
import { SpeakingCorrelator } from "./meet-correlator";

describe("SpeakingCorrelator", () => {
  it("matches a device onset to the one audio onset within the window (audio first)", () => {
    const c = new SpeakingCorrelator(200);
    expect(c.recordAudioOnset("track-a", 1000)).toBeNull();
    const match = c.recordDeviceOnset("device-377", 1042);
    expect(match).toEqual({ trackKey: "track-a", deviceId: "device-377", confirmations: 1 });
  });

  it("matches a device onset to the one audio onset within the window (device first)", () => {
    const c = new SpeakingCorrelator(200);
    expect(c.recordDeviceOnset("device-378", 2000)).toBeNull();
    const match = c.recordAudioOnset("track-b", 2015);
    expect(match).toEqual({ trackKey: "track-b", deviceId: "device-378", confirmations: 1 });
  });

  it("does not match when zero audio onsets are within the window", () => {
    const c = new SpeakingCorrelator(200);
    c.recordAudioOnset("track-a", 1000);
    const match = c.recordDeviceOnset("device-377", 5000); // 4s away, way outside window
    expect(match).toBeNull();
  });

  it("does not match when multiple audio onsets are within the window (ambiguous)", () => {
    const c = new SpeakingCorrelator(200);
    c.recordAudioOnset("track-a", 1000);
    c.recordAudioOnset("track-b", 1050);
    const match = c.recordDeviceOnset("device-377", 1030);
    expect(match).toBeNull();
  });

  it("accumulates confirmations across repeated turns for the same pairing", () => {
    const c = new SpeakingCorrelator(200);
    let t = 0;
    let last = null as ReturnType<SpeakingCorrelator["recordDeviceOnset"]>;
    for (let turn = 0; turn < 3; turn++) {
      t += 1000;
      c.recordAudioOnset("track-a", t);
      last = c.recordDeviceOnset("device-377", t + 20);
    }
    expect(last).toEqual({ trackKey: "track-a", deviceId: "device-377", confirmations: 3 });
  });

  it("resets confirmations when a different track matches the same device id", () => {
    const c = new SpeakingCorrelator(200);
    c.recordAudioOnset("track-a", 1000);
    expect(c.recordDeviceOnset("device-377", 1020)).toEqual({ trackKey: "track-a", deviceId: "device-377", confirmations: 1 });

    c.recordAudioOnset("track-b", 2000);
    expect(c.recordDeviceOnset("device-377", 2020)).toEqual({ trackKey: "track-b", deviceId: "device-377", confirmations: 1 });
  });

  it("tracks independent confidence per device id", () => {
    const c = new SpeakingCorrelator(200);
    c.recordAudioOnset("track-a", 1000);
    c.recordDeviceOnset("device-377", 1010);
    c.recordAudioOnset("track-b", 2000);
    c.recordDeviceOnset("device-378", 2010);

    c.recordAudioOnset("track-a", 3000);
    const match = c.recordDeviceOnset("device-377", 3010);
    expect(match).toEqual({ trackKey: "track-a", deviceId: "device-377", confirmations: 2 });
  });

  it("expires stale onsets outside the history window instead of matching them later", () => {
    const c = new SpeakingCorrelator(200, 1000); // 1s history
    c.recordAudioOnset("track-a", 1000);
    // Device onset arrives 5s later — long past both the correlation window and history — no match.
    const match = c.recordDeviceOnset("device-377", 6000);
    expect(match).toBeNull();
  });

  it("consumes matched events so they can't be reused by a later onset", () => {
    const c = new SpeakingCorrelator(200);
    c.recordAudioOnset("track-a", 1000);
    c.recordDeviceOnset("device-377", 1010); // consumes both
    // A second, unrelated device onset close in time to the first audio onset
    // must not re-match it — it was already consumed.
    const match = c.recordDeviceOnset("device-999", 1015);
    expect(match).toBeNull();
  });
});
