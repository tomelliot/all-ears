import type { BadgeState } from "./meeting-tracker";

// Toolbar action badge: mirrors the popup's status badge onto the extension's
// toolbar icon so the current state is visible without opening the popup.
//
// The tooltip (setTitle) updates for every state. A badge glyph only shows for
// the meeting-active states (recording/paused/transcribing) — the plain
// transport states (connected/connecting/disconnected) clear the badge so an
// idle toolbar stays uncluttered; the popup carries the connection detail.
//
// Colours track the popup palette (entrypoints/popup/index.html :root), with
// one deliberate exception: recording uses the dark ink instead of red, so the
// live-recording badge reads as a solid dark chip on the icon.

const INK = "#1c1b1a"; // dark — recording
const AMBER = "#e0a03c"; // --accent — paused
const GREEN = "#4a7c59"; // --ok — transcribing
const TEXT = "#ffffff"; // glyph colour; readable on all of the above

interface BadgeStyle {
  /** Badge glyph, or "" to clear the badge for this state. */
  text: string;
  /** Badge background; unused when text is "". */
  color: string;
  /** Native tooltip on the toolbar icon. */
  title: string;
}

const STYLES: Record<BadgeState, BadgeStyle> = {
  disconnected: { text: "", color: INK, title: "All Ears — earsd not reachable" },
  connecting: { text: "", color: AMBER, title: "All Ears — connecting to earsd…" },
  connected: { text: "", color: GREEN, title: "All Ears — connected to earsd" },
  recording: { text: "●", color: INK, title: "All Ears — recording" },
  paused: { text: "‖", color: AMBER, title: "All Ears — transcription paused" },
  transcribing: { text: "…", color: GREEN, title: "All Ears — transcribing" },
};

/** The subset of chrome.action / browser.action this drives — the real
 * `browser.action` in the background, a fake in tests. Each call may be sync
 * (fakes) or return a promise (the browser); both are tolerated. */
export interface ActionSurface {
  setBadgeText(details: { text: string }): unknown;
  setBadgeBackgroundColor(details: { color: string }): unknown;
  setBadgeTextColor?(details: { color: string }): unknown;
  setTitle(details: { title: string }): unknown;
}

/** Reflect `state` onto the toolbar icon. Best-effort: swallows the promise
 * rejection a suspended/absent action surface can throw. */
export function applyActionBadge(action: ActionSurface, state: BadgeState): void {
  const style = STYLES[state] ?? STYLES.disconnected;
  const swallow = (r: unknown): void => {
    if (r && typeof (r as Promise<unknown>).catch === "function") {
      (r as Promise<unknown>).catch(() => {});
    }
  };
  swallow(action.setTitle({ title: style.title }));
  swallow(action.setBadgeText({ text: style.text }));
  if (style.text) {
    swallow(action.setBadgeBackgroundColor({ color: style.color }));
    swallow(action.setBadgeTextColor?.({ color: TEXT }));
  }
}
