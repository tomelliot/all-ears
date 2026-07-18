import { describe, expect, it } from "vitest";
import { resolveCaptureToggleState } from "./capture-toggle";

describe("resolveCaptureToggleState", () => {
  it("defaults to enabled when the key is missing (fresh install)", () => {
    expect(resolveCaptureToggleState(undefined)).toBe(true);
  });

  it("respects an explicit stored false", () => {
    expect(resolveCaptureToggleState(false)).toBe(false);
  });

  it("respects an explicit stored true", () => {
    expect(resolveCaptureToggleState(true)).toBe(true);
  });

  it("treats corrupt values as enabled — never silently kills capture", () => {
    expect(resolveCaptureToggleState(null)).toBe(true);
    expect(resolveCaptureToggleState("false")).toBe(true);
    expect(resolveCaptureToggleState(0)).toBe(true);
    expect(resolveCaptureToggleState({})).toBe(true);
  });
});
