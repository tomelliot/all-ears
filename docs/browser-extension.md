# Browser extension

The extension captures meeting audio from inside a call you've already joined — Google Meet, Zoom (web), or Teams in Chrome or Firefox — and streams each remote participant's audio to `earsd` as its own source. Because each participant arrives as a separate stream *before* the page mixes them for playback, transcripts get true per-speaker separation without diarization guesswork.

It does nothing else: no meeting-joining bots, no tab capture, no caption scraping, no transcription in the browser, no cloud. The user joins; the extension listens; `earsd` and the pipeline do the rest.

## What you get per platform

| Platform | Separation | Identity |
|----------|-----------|----------|
| Google Meet | One stream per remote participant | Real display names, attached from the first time each person speaks |
| Zoom (web) | One stream per remote participant | Participant id parsed from the track itself — stable across mute/rejoin |
| Teams | One mixed far-end stream | `Speaker N` attribution from the dominant-speaker signal — honest, but degraded |

Each speaking participant shows up in `ears sources list` as `browser:<platform>:<participant>` and is recorded, indexed, and transcribed like any other source. On Meet, the extension also registers the call with the daemon so every attendance of the same meeting correlates to one meeting id.

## Setup

1. Enable the two loopback endpoints in your `earsd` config and allowlist the extension's origin:

   ```toml
   [earsd.ingest_ws]
   enabled = true
   allowed_origins = ["chrome-extension://<your-extension-id>"]

   [earsd.control_ws]
   enabled = true
   allowed_origins = ["chrome-extension://<your-extension-id>"]
   ```

   An empty allowlist rejects every connection, so this step is required. Both endpoints bind to `127.0.0.1` only.

2. Build and load the extension from [`browser/`](../browser/):

   ```sh
   cd browser
   bun install
   bun run build          # Chrome → .output/chrome-mv3
   bun run build:firefox  # Firefox → .output/firefox-mv3
   ```

   Load the output directory as an unpacked extension (`chrome://extensions` → Load unpacked, or `about:debugging` in Firefox).

3. Join a call. Capture is on by default; the popup has the on/off toggle, a connection indicator, and a pause-transcription toggle for the current meeting. Turning capture off persists across browser restarts.

## Limitations

- Firefox builds compile and load, but the full path hasn't been live-verified there, and the Meet capture mechanism relies on a Chrome API (`createEncodedStreams`) Firefox doesn't implement — Meet-on-Firefox doesn't work yet.
- Teams is attribution, not isolation: overlapping speakers can be misattributed, and the UI never claims otherwise.
- Meet identity resolves on a participant's first speaking turn — someone who never speaks stays `speaker-<n>` (and produces no audio worth naming anyway).
- Any local process can present an allowed `Origin` and connect to the loopback ports; the threat model is a single-user machine. See the [transport spec](./specs/browser/transport.md#security).

Internals are specified in [specs/browser/extension.md](./specs/browser/extension.md) (capture, identity, messaging) and [specs/browser/transport.md](./specs/browser/transport.md) (the wire protocol to `earsd`).
