// Hooks on sites the manifest doesn't list — the popup's "Enable hooks on this
// site" button. Meet, Zoom, Teams, Daily and hosted Jitsi get the two content
// scripts statically; any other call site (cal.com, a self-hosted Jitsi, …)
// gets the same two scripts registered at runtime, per origin, after the user
// grants that origin.
//
// Registration only takes effect on the next load: the hook has to run at
// document_start to wrap RTCPeerConnection before the page caches it, so the
// popup offers a reload rather than doing one — reloading leaves a live call.
//
// A call frequently lives in a cross-origin iframe (Cal Video embeds Daily), and
// `allFrames` only injects into frames whose own origin matches. The popup
// therefore collects the top page's iframe origins too and registers them all.
//
// This module is the pure half (tier-0): patterns, parsing, script definitions,
// platform naming. The browser-API calls live in background.ts and the popup.

import type { Platform } from "./protocol";

/** storage.local key: match patterns the user enabled hooks on. */
export const SITE_HOOKS_KEY = "siteHookPatterns";

/** Ids of the runtime-registered scripts, distinct from WXT's own. */
export const SITE_HOOK_SCRIPT_IDS = ["ears-site-relay", "ears-site-hook"] as const;

/** Hosts the manifest already injects into — registering them again would double-hook. */
export function isBuiltInHost(host: string): boolean {
  return (
    host === "meet.google.com" ||
    host.endsWith("zoom.us") ||
    host === "teams.microsoft.com" ||
    host === "daily.co" ||
    host.endsWith(".daily.co") ||
    host === "meet.jit.si" ||
    host === "8x8.vc"
  );
}

/**
 * The match pattern covering `url`'s origin, or null when hooks can't or
 * needn't go there (non-web schemes, built-in hosts, unparseable input).
 * Match patterns carry no port, so `http://localhost:3000` becomes
 * `http://localhost/*`.
 */
export function matchPatternForUrl(url: string): string | null {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  if (u.protocol !== "https:" && u.protocol !== "http:") return null;
  if (isBuiltInHost(u.hostname)) return null;
  return `${u.protocol}//${u.hostname}/*`;
}

/** Patterns for a tab: its top origin first, then each distinct iframe origin. */
export function patternsForFrames(topUrl: string, frameUrls: readonly string[]): string[] {
  const out: string[] = [];
  for (const url of [topUrl, ...frameUrls]) {
    const p = matchPatternForUrl(url);
    if (p && !out.includes(p)) out.push(p);
  }
  return out;
}

const PATTERN_RE = /^https?:\/\/[^/*]+\/\*$/;

/**
 * Tolerant deserializer: anything that isn't a well-formed origin pattern is
 * dropped, and so is a host that has since become built-in — a pattern saved
 * before that would otherwise inject the scripts a second time.
 */
export function parseSiteHookPatterns(raw: unknown): string[] {
  if (!Array.isArray(raw)) return [];
  const valid = raw.filter(
    (p): p is string => typeof p === "string" && PATTERN_RE.test(p) && !isBuiltInHost(hostOfPattern(p)),
  );
  return [...new Set(valid)];
}

/** Human-readable host for a pattern, for the popup note. */
export function hostOfPattern(pattern: string): string {
  return pattern.replace(/^https?:\/\//, "").replace(/\/\*$/, "");
}

/**
 * The two scripts, mirroring the manifest entries in content.ts and
 * hook.content.ts. Paths are WXT's build output names.
 */
export function siteHookScripts(patterns: string[]) {
  const common = {
    matches: patterns,
    allFrames: true,
    runAt: "document_start" as const,
    persistAcrossSessions: true,
  };
  return [
    { id: SITE_HOOK_SCRIPT_IDS[0], js: ["content-scripts/content.js"], ...common },
    { id: SITE_HOOK_SCRIPT_IDS[1], js: ["content-scripts/hook.js"], world: "MAIN" as const, ...common },
  ];
}

/**
 * Platform tag for a page. Localhost stays `teams` because the dev harness
 * (dev/phase7-verify.ts) asserts `browser:teams:` labels; any other unlisted
 * host is `web` — no identity adapter, no meeting watch, audio still flows.
 */
export function platformForHost(host: string, adapter: { platform: Platform } | null): Platform {
  if (adapter) return adapter.platform;
  if (host === "meet.google.com") return "meet";
  if (host.endsWith("zoom.us")) return "zoom";
  if (host === "teams.microsoft.com" || host === "localhost" || host === "127.0.0.1") return "teams";
  return "web";
}
