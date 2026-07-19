import { defineConfig } from "wxt";

// EARS_DEV_LOCALHOST=1 adds a localhost match so the synthetic WebRTC test
// harness in dev/ runs through the real content-script injection path. Never
// set in a shipping build.
const devHosts = process.env.WXT_DEV_LOCALHOST
  ? ["http://localhost/*", "http://127.0.0.1/*"]
  : [];

// Manifest surface per docs/specs/extension.md §WXT project layout.
export default defineConfig({
  manifest: ({ browser }) => ({
    name: "All Ears",
    // Firefox MV3 requires an explicit extension ID.
    ...(browser === "firefox"
      ? { browser_specific_settings: { gecko: { id: "ears-capture@tomelliot.net" } } }
      : {}),
    permissions: ["storage", "alarms"],
    host_permissions: [
      "https://meet.google.com/*",
      "https://*.zoom.us/*",
      "https://teams.microsoft.com/*",
      // Background WebSocket to loopback earsd. Some browsers (notably Brave,
      // with stricter localhost handling than Chrome) require this for the SW
      // to open ws://127.0.0.1. Harmless on browsers that don't.
      "ws://127.0.0.1/*",
      "http://127.0.0.1/*",
      ...devHosts,
    ],
    web_accessible_resources: [
      {
        // The MAIN-world hook ships as a content script (see hook.content.ts),
        // not a web-accessible asset. Only the AudioWorklet needs a public URL.
        resources: ["pcm-worklet.js"],
        matches: ["<all_urls>"],
      },
    ],
  }),
});
