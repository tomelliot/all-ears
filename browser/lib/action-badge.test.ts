import { describe, expect, it } from "vitest";
import { applyActionBadge, type ActionSurface } from "./action-badge";
import type { BadgeState } from "./meeting-tracker";

// A recording fake for the browser.action surface. Every setter resolves (the
// real API returns promises); we just capture the last-applied values.
function fakeAction() {
  const calls = { text: "", bgColor: "", textColor: "", title: "" };
  const surface: ActionSurface = {
    setBadgeText: ({ text }) => {
      calls.text = text;
      return Promise.resolve();
    },
    setBadgeBackgroundColor: ({ color }) => {
      calls.bgColor = color;
      return Promise.resolve();
    },
    setBadgeTextColor: ({ color }) => {
      calls.textColor = color;
      return Promise.resolve();
    },
    setTitle: ({ title }) => {
      calls.title = title;
      return Promise.resolve();
    },
  };
  return { surface, calls };
}

describe("applyActionBadge", () => {
  it("shows a dark badge glyph while recording", () => {
    const { surface, calls } = fakeAction();
    applyActionBadge(surface, "recording");
    expect(calls.text).toBe("●");
    expect(calls.bgColor.toLowerCase()).toBe("#1c1b1a"); // dark ink
    expect(calls.title).toMatch(/recording/i);
  });

  it("badges paused and transcribing with their own glyphs", () => {
    const paused = fakeAction();
    applyActionBadge(paused.surface, "paused");
    expect(paused.calls.text).toBe("‖");

    const transcribing = fakeAction();
    applyActionBadge(transcribing.surface, "transcribing");
    expect(transcribing.calls.text).toBe("…");
  });

  it.each<BadgeState>(["connected", "connecting", "disconnected"])(
    "clears the badge for the transport state %s but still sets a tooltip",
    (state) => {
      const { surface, calls } = fakeAction();
      applyActionBadge(surface, state);
      expect(calls.text).toBe("");
      expect(calls.title).toMatch(/All Ears/);
    },
  );

  it("tolerates a surface without setBadgeTextColor and rejected promises", () => {
    const surface: ActionSurface = {
      setBadgeText: () => Promise.reject(new Error("suspended")),
      setBadgeBackgroundColor: () => Promise.reject(new Error("suspended")),
      setTitle: () => Promise.reject(new Error("suspended")),
    };
    expect(() => applyActionBadge(surface, "recording")).not.toThrow();
  });
});
