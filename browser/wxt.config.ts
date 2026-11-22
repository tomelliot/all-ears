import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig } from "wxt";

// EARS_DEV_LOCALHOST=1 adds a localhost match so the synthetic WebRTC test
// harness in dev/ runs through the real content-script injection path. Never
// set in a shipping build.
const devHosts = process.env.WXT_DEV_LOCALHOST
  ? ["http://localhost/*", "http://127.0.0.1/*"]
  : [];

// `version` is Chrome's own format, not semver: one to four dot-separated
// integers, each 0–65535, no leading zeros and no `-pre`/`+build` suffix — a
// timestamp doesn't fit, and WXT derives it from package.json anyway. The
// build stamp therefore rides on `version_name`, a free-form display string
// that update comparison ignores.
//
// Which build is loaded is worth showing, because loading the wrong one fails
// *silently*: `wxt build` writes static content_scripts into the manifest,
// while a `wxt` dev build registers them at runtime and needs the dev server
// on :3000. Without it the service worker still starts and still holds its
// earsd sockets, so every surface looks healthy while nothing is ever injected
// into a meeting tab (diagnosed 2026-09-04, after it cost two days of calls).
// The extensions management page (chrome://extensions, brave://extensions)
// shows version_name in place of version, so it now names the build outright.
const pkgVersion = JSON.parse(
  readFileSync(fileURLToPath(new URL("./package.json", import.meta.url)), "utf8"),
).version as string;

const buildStamp = new Date().toISOString().slice(0, 16).replace("T", " ");

// Manifest surface per docs/specs/browser/extension.md §WXT project layout.
export default defineConfig({
  manifest: ({ browser, command }) => ({
    name: "All Ears",
    // `command` is "serve" for `wxt` (dev) and "build" for `wxt build`/`zip`.
    version_name:
      command === "serve"
        ? `${pkgVersion} DEV BUILD — needs wxt dev server (${buildStamp}Z)`
        : `${pkgVersion} (built ${buildStamp}Z)`,
    // Firefox MV3 requires an explicit extension ID.
    ...(browser === "firefox"
      ? { browser_specific_settings: { gecko: { id: "ears-capture@tomelliot.net" } } }
      : {}),
    // scripting + activeTab + optional hosts: the popup's "Enable hooks on this
    // site" button (lib/site-hooks.ts). Each origin is granted on click, never
    // up front.
    permissions: ["storage", "alarms", "scripting", "activeTab"],
    optional_host_permissions: ["https://*/*", "http://*/*"],
    host_permissions: [
      "https://meet.google.com/*",
      "https://*.zoom.us/*",
      "https://teams.microsoft.com/*",
      "https://*.daily.co/*",
      // Hosted Jitsi Meet (identity/jitsi.ts). Self-hosted Jitsi goes through
      // the popup's per-site enable instead.
      "https://meet.jit.si/*",
      "https://8x8.vc/*",
      // Background WebSocket to loopback earsd. Some browsers (notably Brave,
      // with stricter localhost handling than Chrome) require this for the SW
      // to open ws://127.0.0.1. Harmless on browsers that don't.
      "ws://127.0.0.1/*",
      "http://127.0.0.1/*",
      ...devHosts,
    ],
  }),
});
