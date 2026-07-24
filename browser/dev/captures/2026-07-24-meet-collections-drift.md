# Meet identity-path breakage — live capture, 2026-07-24

Console + daemon logs captured live during a monitored test call, preserved
here because Meet's post-call redirect to /landing wipes both the page's
`__earsNetLog` buffer and the tab console. Everything below is verbatim from
the call unless marked otherwise.

## Context

- **Test call**: https://meet.google.com/cxb-hxyp-wor, space `nN-Aql2-48gB`,
  meeting `4547a7bd-05bc-42a4-8d9b-254742a1bd78`, 2026-07-24 09:57–10:10 PDT
  (16:57:59Z–17:10:46Z). Participants: Tom Elliot (`devices/86`),
  aftab farooqi (`devices/87`).
- **Motivating failure**: the Brivo & Good2Go call that morning
  (meeting `26097592-2e01-47bc-b35c-b3bc7126d0e9`, space `qT5a1RUDKQEB`,
  9:00–9:22 PDT) produced a mic-only transcript — no `browser:meet:*` source
  ever opened, so the remote participant (Julian Fine) was never recorded.
  A 1-second false-start meeting (`69644079…`, space `y5Y2G7jYl9MB`) preceded
  it at 8:25.
- **Extension build**: rebuilt 2026-07-24 00:38 at commit `c82f4e6`
  (`fix(browser): join dead-track sources to named attendees via a rename
  message`). Last healthy per-participant capture: 23:29–23:58 PDT Jul 23
  (meeting `6950a4c3…`, before the rebuild).

## Findings (summary)

1. **Meet no longer streams per-turn speaking flags on the `collections`
   datachannel.** The only speaking-flag event in the entire test call was
   aftab's unmute at join (10:03:28). During ~7 minutes of conversation with
   clean turn-taking, zero further collections messages arrived (the tracer
   logs every message — no rate limit; verified in rtc-hook.ts). The
   2026-07-19 live verification (journal entries after #54) watched manual
   *unmutes*, so the `1.2.3.2.10.1` flag verified as a turn indicator when it
   is actually a mute-state edge. Consequence: `SpeakingCorrelator` gets at
   most one device onset per participant per call (their unmute), so identity
   confirmation is effectively dead — `speaker-N` never joins to a device id.
2. **Meet dropped the participant-id DOM attributes from tiles**
   (`data-participant-id`, `data-requested-participant-id`,
   `data-initial-participant-id`) — the tile-DOM identity path warned at join
   (message below). Both identity paths are now broken; roster *names* still
   resolve fine from the collections channel's space snapshot messages.
3. **The wire format itself still parses.** The per-device record with
   `1.2.3.2.6` (device id) and `1.2.3.2.10.1` (flag) decoded exactly as
   documented in meet-collections.ts on the one message that carried it (the
   unmute; full decode below). The schema didn't drift — the *event stream*
   went away.
4. **AudioDecoder decode-error bug (journal #45) reproduced** on aftab's track
   at 10:03:34 after 89 healthy frames; in-place rebuild recovered it. Leading
   (unproven — that tab's console is gone) suspect for the morning call's
   total absence of remote audio: a decoder dying at frame ~0 and exhausting
   its restart budget before any PCM flowed. The daemon saw the extension's
   control channel work all morning (meeting.start, roster names) with zero
   `ingest.open` — i.e. capture pipelines existed page-side or died silently;
   no browser source ever delivered a frame.
5. **MV3 service worker was evicted and respawned mid-test-call** (10:03:28);
   the content relay replayed state and capture recovered — that path works.
6. **Capture itself was fully healthy in the test call**: mic + one
   `browser:meet:speaker-1` source, real-time chunk delivery (~2s behind
   live), speech turns detected. End-of-call roster:
   `speaker-1(name=no,source=yes)` … `devices/87(name=yes,source=no)` — name
   and source stranded on different rows, exactly the shape commit `c82f4e6`'s
   rename path exists to fix, but the rename never fires because the
   correlator never confirms (finding 1).

## Console log — join through first minutes (verbatim)

Meet lobby → join at 09:57:47, extension id `ncfpjklefpdllmkefkhlamgiljclfgdi`:

```
[09:57:47] [ears][probe][webaudio] new AudioContext — sampleRate=48000
[09:57:47] [ears][probe][webaudio] new AudioWorkletNode — processor="audio-analyzer-processor" ch=?
[09:57:48] [ears][probe][webaudio] createMediaStreamSource(audioTracks=[49a3271b-13ce-4a71-8c3e-46f48293ac7e])
[09:57:48] [ears][probe][webaudio] createMediaStreamSource(audioTracks=[fe3d5581-4d55-4fe6-b70c-fbde26298e55])
[09:57:48] [ears][probe][webaudio] media.srcObject = audioTracks=[]
[09:57:48] [ears][probe][webaudio] createMediaStreamSource(audioTracks=[4f163f48-78cc-4e2a-a34d-2bc83e184c2f])
[09:57:48] [ears][hook] tee'd encoded audio stream for track b485e2d8-7a24-475b-b713-832a39c8c311 (1 total)
[09:57:48] [ears][hook] tee'd encoded audio stream for track 2610d612-fbc1-4654-9b02-d7f0d9c3d45d (2 total)
[09:57:48] [ears][hook] tee'd encoded audio stream for track 1b23ca83-eba0-4137-afa2-d925994471fc (3 total)
[09:57:48] WARNING [ears][identity] Meet DOM carries none of the expected participant-id attributes
           (data-participant-id, data-requested-participant-id, data-initial-participant-id) on any
           tile — identity degrades to speaker-<n>. The Meet build's tile DOM has likely changed;
           see lib/identity/meet.ts for the verification checklist and CSRC fallback notes.
[09:57:48] [ears][capture] +track → speaker-1 (gen 1) — 1 live
[09:57:48] [ears][capture] +track → speaker-2 (gen 1) — 2 live
[09:57:48] [ears][capture] +track → speaker-3 (gen 1) — 3 live
[09:57:48] [ears][relay] joined speaker-1 gen1 (meet)
[09:57:48] [ears][relay] joined speaker-2 gen1 (meet)
[09:57:48] [ears][relay] joined speaker-3 gen1 (meet)
[09:57:48] [ears][probe][webaudio] new AudioWorkletNode — processor="neteq-processor" ch=?
[09:57:49] [ears][probe][webaudio] new MediaStreamTrackGenerator — kind=video
[09:57:49] [ears][debug][net] datachannel (remote) label="collections" id=111 protocol="webrtc-datachannel" ordered=false
[09:57:59] [ears][hook] Meet meeting id resolved: nN-Aql2-48gB
[09:57:59] [ears][relay] meeting started: meet/nN-Aql2-48gB
[09:58:01] [ears][identity] Meet roster resolved: spaces/nN-Aql2-48gB/devices/86 → "Tom Elliot"
[09:58:01] [ears][relay] roster 1 name(s) (meet): spaces/nN-Aql2-48gB/devices/86="Tom Elliot"
```

Guest joins at 10:03:28 (note: worker respawn + first audio + the call's ONLY
speaking-flag message, all within the same second):

```
[10:03:28] [ears][capture] unmute → speaker-1
[10:03:28] [ears][capture] ✓ speaker-1 first audio frame — capture confirmed live
[10:03:28] [ears][relay] replayed to respawned worker: meeting=nN-Aql2-48gB, 3 participant(s), 1 roster name(s), 0 rename(s)
[10:03:31] [ears][identity] Meet roster resolved: spaces/nN-Aql2-48gB/devices/87 → "aftab farooqi"
[10:03:31] [ears][relay] roster 1 name(s) (meet): spaces/nN-Aql2-48gB/devices/87="aftab farooqi"
[10:03:34] ERROR [ears][capture] b485e2d8-7a24-475b-b713-832a39c8c311 AudioDecoder error: Decoding error.
           — decoder was healthy, 89 frame(s) decoded since rebuild; failing frame ~45B ts=701783598 toc=0xef
[10:03:34] WARNING [ears][capture] b485e2d8-7a24-475b-b713-832a39c8c311 decoder rebuilt in place after
           a healthy run — AudioDecoder error: Decoding error.
```

After 10:03:34: no further `[ears][identity]` or `DC[collections]` messages
for the remainder of the call, only `[ears][debug][audio]` speaking edges,
e.g.:

```
[10:04:41] [ears][debug][audio] 2026-07-24T17:04:41.228Z speaker-1 (track b485e2d8-…) speaking-start peak=0.0052
[10:04:41] [ears][debug][audio] speaker-1 rms=0.1399 peak=0.6951 (AUDIO)
[10:04:42] [ears][debug][audio] 2026-07-24T17:04:42.461Z speaker-1 (track b485e2d8-…) speaking-stop peak=0.0015
```

## Collections datachannel — every message observed (verbatim decodes)

All collections traffic arrived in one burst at guest-join (10:03:28–10:03:30);
nothing before or after. Decodes are from the built-in structure tracer
(rtc-hook.ts `logCollectionsStructure`).

### Message 1 — 37 bytes, complete raw capture

```
hex[1f 8b 08 00 00 00 00 00 00 00 e3 e2 17 e2 cd e2 ee 62 e4 e0 62 e2 60 14 60 94 60 04 00 4b 98 f6 d9 11 00 00 00]
```

Decoded (17B inflated) — note fields 13/17, NOT the per-device 1.2.3.2 shape:

```
1 (LEN len=15)
  2 (LEN len=13)
    13 (LEN len=11)
      17 (LEN len=8)
        1 (LEN len=2)
          1 (varint) = 1
        2 (varint) = 1
        3 (varint) = 1
```

### Message 2 — 179 bytes, complete raw capture — THE per-device speaking record

```
hex[1f 8b 08 00 00 00 00 00 00 00 e3 3a c2 28 74 90 51 6a 1f 23 17 07 47 e3 85 ed ff 2e 7c 4a 17 72 e1 60 14 60 54 e2 32 32 35 36 30 32 33 33 b1 30 30 92 2b 2e 48 4c 4e 2d d6 cf f3 d3 75 2c cc 31 d2 35 b1 48 77 d2 4f 49 2d cb 04 09 5a 98 3b b1 71 7c 98 75 78 1b a7 17 93 00 63 10 13 07 43 11 13 07 83 50 0e 07 a3 00 93 12 97 91 b1 91 b1 a1 99 85 81 a1 25 41 53 e4 39 26 7f 7b 74 99 83 63 df d7 a5 37 d9 85 04 b9 98 dd 3c 5d 04 c0 42 02 60 21 2f 26 01 06 90 f1 11 8c 20 0b 56 31 72 f1 32 30 48 d8 8b fe 5a c2 6f 0f 00 e1 4b 15 5e c7 00 00 00]
```

Decoded (199B inflated) — the documented paths still hold
(`1.2.3.2.6` device id, `1.2.3.2.10.1` flag=0 at unmute). Two per-device
records for the same device (two SSRCs — likely audio + video):

```
1 (LEN len=196)
  2 (LEN len=193)
    3 (LEN len=190)
      1 (LEN len=8)
        1 (varint) = 456937540806657
      2 (LEN len=68)
        1 (varint) = 1
        2 (varint) = 1
        4 (LEN len=10) STRING="2530266480"
        6 (LEN len=30) STRING="spaces/nN-Aql2-48gB/devices/87"
        8 (LEN len=6)
          1 (varint) = 2530266480
        9 (LEN len=2)
          2 (varint) = 1
        10 (LEN len=2)
          1 (varint) = 0
        14 (LEN len=2)
          1 (varint) = 0
      2 (LEN len=108)
        1 (varint) = 1
        2 (varint) = 2
        4 (LEN len=10) STRING="2323168019"
        6 (LEN len=30) STRING="spaces/nN-Aql2-48gB/devices/87"
        8 (LEN len=31)
          1 (varint) = 2323168019
          1 (varint) = 2066315966
          2 (LEN len=17)
            1 (LEN len=3) STRING="FID"
            2 (varint) = 2323168019
            2 (varint) = 2066315966
        9 (LEN len=2)
          2 (varint) = 0
        10 (LEN len=2)
          1 (varint) = 0
        11 (varint) = 1
        14 (LEN len=2)
          1 (varint) = 0
        21 (LEN len=10)
          1 (fixed32)
          2 (fixed32)
```

### Message 3 — 424 bytes (first 200 raw bytes captured), decoded 458B: roster/name record for Tom

Path `1.2.13.1.2`: device id + display name + avatar URL + given name — this
is where roster names come from (and why names still work):

```
1 (LEN len=455)
  2 (LEN len=452)
    13 (LEN len=449)
      1 (LEN len=446)
        1 (LEN len=2)
          1 (varint) = 44
        2 (LEN len=439)
          1 (LEN len=30) STRING="spaces/nN-Aql2-48gB/devices/86"
          2 (LEN len=10) STRING="Tom Elliot"
          3 (LEN len=104) STRING="https://lh3.googleusercontent.com/a/ACg8ocKbDTBbcCSnfZcW9fEu4CXqqkYkPeuFVi_8ntcrB98u11Acpwcemw=s192-c-mo"
          4 (varint) = 1
          5 (varint) = 1
          7 (LEN len=28) STRING="oOoUnkutithQrgoKAAiKYigCIAEQ"
          ... (session tokens, capability flags)
          29 (LEN len=3) STRING="Tom"
          43 (LEN len=44) STRING="OHuHVfYuM2YYL-lmbNkND1ey0SId_J7EgGdhXD4F7ak="
          ...
```

### Messages 4–5 — 776/789 bytes, decoded 1070/1084B: space snapshot

Path `1.2.13.2.2`: space id, meeting code, join URLs, dial-in, per-guest
records (`…6.4 = "Aftab Farooqi"`, `…6.16.1 = "aftab farooqi"` + avatar),
Gemini session, caption languages. Full decodes preserved in the conversation
that produced this file; structurally identical between the two messages
(sequence numbers 45 → 46 in `…2.1.1`).

## Daemon log — key lines (earsd.err.log, verbatim)

Morning Brivo call — control channel fine, no audio ingest ever:

```
16:00:43.198Z meeting.start: meeting=26097592-… identity=meet:qT5a1RUDKQEB trigger=browser-extension sources=mic superseded=0
16:00:43.519Z capture.input_rate_changed {source: mic, from: 0, to: 16000, target: 48000, action: baseline}
16:00:45.196Z meeting.attendee upsert: … attendee=spaces/qT5a1RUDKQEB/devices/513 recv_display_name="Julian Fine" recv_source=-
16:00:45.201Z meeting.attendee upsert: … attendee=spaces/qT5a1RUDKQEB/devices/514 recv_display_name="Tom Elliot" recv_source=-
(no ingest.open, no browser capture actor, zero errors for the entire 21-min call)
```

Last healthy call for comparison (Jul 23 11:29pm, meeting 6950a4c3…):

```
06:29:11.017Z meeting.start: … sources=mic
06:30:12.282Z capture actor built: source=browser:meet:speaker-1 …
06:30:12.285Z grace cancelled: … cause=ingest.open source=browser:meet:speaker-1 …
```

Test call — ingest opened the moment the guest's first audio frame flowed:

```
17:03:29.912Z capture actor built: source=browser:meet:speaker-1 meeting=4547a7bd-…
17:03:29.914Z grace cancelled: … cause=ingest.open source=browser:meet:speaker-1 generation=1
17:03:29.917Z meeting.attendee upsert: … attendee=speaker-1 recv_source="browser:meet:speaker-1"
17:03:31.270Z meeting.attendee upsert: … attendee=spaces/nN-Aql2-48gB/devices/87 recv_display_name="aftab farooqi" recv_source=-
17:10:46.584Z meeting.end roster summary: … attendees=5 with_name=2 with_source=1
              unresolved=speaker-1(name=no,source=yes),speaker-2(name=no,source=no),
              speaker-3(name=no,source=no),spaces/nN-Aql2-48gB/devices/86(name=yes,source=no),
              spaces/nN-Aql2-48gB/devices/87(name=yes,source=no)
17:10:46.631Z meeting-end on_end: spawning transcribe --meeting 4547a7bd-…
17:10:52.166Z meeting-end on_end: transcribe succeeded
```

## Controlled experiment — second test call (10:26–10:39 PDT)

Meeting `umq-cyjt-mob`, space `KGtf2n-bR-gB`, daemon meeting
`8d475235-62d2-4bcd-836d-1983cfe9702d`. Tom Elliot (`devices/104`, host) +
"Tom E" (`devices/105`, same person from a second account). Scripted: ~1 min
normal conversation, then deliberate mute/unmute toggles ~5s apart.

### Result 1 — speaking turns produce NO collections traffic

`window.__earsNetLog` sampled repeatedly during continuous conversation:
zero collections messages between 17:27:55 and 17:31:49 (the first mute
toggle). Speaking-onset correlation is impossible on this Meet build — the
per-turn events are gone, not renumbered.

### Result 2 — mute toggles DO produce per-device flag messages, old format intact

Each toggle emitted a 105-byte gzip'd collections message. Decoded offline
(full hex preserved below): documented paths hold exactly —
`1.2.3.2.6` = device id, `1.2.3.2.10.1` = flag, **0 = mic open / unmute,
1 = mute**. It is a mute-state edge, not a speaking indicator.

```
17:27:49.618  devices/105  flag=0   (guest joined unmuted)
17:31:49.909  devices/105  flag=0   (unmute toggle — same second as the
                                     track-level "unmute → speaker-4" edge)
17:31:58.822  devices/105  flag=1   (mute toggle)
17:32:04.342  devices/105  ~flag=0  (unmute; CRC-truncated in transfer)
17:32:09.839  devices/105  flag=1   (mute)
```

Raw hex, toggle 1 (unmute, complete):

```
1f8b0800000000000000e30a110a920ae0e2e068dfb3e2e2a54fe9422e1c8c028c4a9c16a666a62686c616c646f2c50589c9a9c5fadeee25694679ba4941bae94efa29a96599204143035327368ee313b7cf60f66212600c62e2602862e26000003da8738156000000
```

Raw hex, toggle 2 (mute, complete):

```
1f8b0800000000000000e30a110a920ae0e2e0e8d8b3e2e2a54fe9422e1c8c028c4a9c16a666a62686c616c646f2c50589c9a9c5fadeee25694679ba4941bae94efa29a96599204143035327368ee313b7cf60f66212600c62e2602c62e26000009df1c32d56000000
```

**Fix implication**: correlate the collections mute-flag edge (`flag=0`)
against the track-level `unmute` event (audio-tap already observes it) —
in this call they landed within the same second, twice. One-shot per
participant per unmute, but reliable and available at join for anyone who
joins muted then unmutes.

### Result 3 — the morning no-audio failure REPRODUCED, and it isn't the decoder

The remote participant's audio recorded for exactly 4 seconds
(17:27:49–17:27:53), then a `delivery-stall` gap and nothing further, silently
— no AudioDecoder error, no capture-failed, pipelines never touched again:

```
sources/browser_meet_speaker-1/chunks.jsonl:
{"start":"…17:27:49.666Z","end":"…17:27:53.466Z","frames":60800,"file":"asr/…"}
{"t":"gap","start":"…17:27:53.466Z","end":"…17:27:55.598Z","reason":"delivery-stall"}
(nothing after; mic source kept chunking normally the whole call)
```

Live probes while the call audio was working fine for the humans:

- All 4 tee'd receiver tracks: `readyState=live`, two with `muted=false` —
  but an 8-second counter wrapped around `__earsEncodedAudioListeners`
  measured **0 encoded frames on every track** while a participant spoke.
- A WebAudio analyser attached directly to the same receiver tracks
  measured **0.0 peak on all 4** over 8 seconds — the browser-decoded side
  is equally silent. The RTP receiver path carries no audio at all.
- No audio on any datachannel (netLog: only the 10 collections messages).
- Join-time console shows Meet building its own page-side audio pipeline:
  `AudioWorkletNode processor="neteq-processor"` (WebRTC's jitter buffer in
  JS/WASM), media elements attached with **empty** audio track lists, and
  `createMediaStreamSource()` on six track ids that never appeared on any
  hooked receiver.

Conclusion: Meet is migrating call audio off the RTCPeerConnection receiver
path a few seconds into the call (or before first frame — the morning case)
to a transport the hook doesn't see, with its own NetEQ+worklet decode
pipeline. The old path stays up as vestigial, live-but-silent tracks. The
aftab call (same day, ~30 min earlier) delivered full audio through the old
path for its entire 7 minutes — so this is a staged rollout / per-call
experiment flag, which also explains the morning Brivo call losing remote
audio entirely while the previous night's call was fine.

`createEncodedStreams()` tee'ing is a dead end on affected calls. Candidate
re-taps, in rough order of promise: the `createMediaStreamSource()` inputs
(Meet hands its decoded per-something tracks to WebAudio — hook
`AudioContext.prototype.createMediaStreamSource` and fingerprint the
tracks), `MediaStreamTrackGenerator` (kind=audio) writables, or the worklet
node's port traffic. Needs a dedicated instrumented call.

## Open questions / next steps

- **[Answered by experiment]** There is no per-turn speaking signal on the
  collections channel anymore — only mute edges. Speaking-onset correlation
  is dead; unmute-edge correlation (flag=0 ↔ track unmute event) is the
  viable replacement and paired within the same second twice in the
  controlled test.
  **[Implemented same day]**: MeetAdapter now runs a second
  SpeakingCorrelator (2s window) pairing the collections mic-open edge with
  the track-level unmute event (adapter.onTrackUnmute, fed by audio-tap);
  the event type is renamed CollectionsMuteEvent to match reality.
- **[Reproduced, cause narrowed]** The no-remote-audio failure is Meet
  migrating audio off the hooked RTP receiver path (see Result 3) — not the
  AudioDecoder bug. Still open: where decoded per-participant audio actually
  surfaces on the new path, and whether it is per-participant at all.
  **[Instrumented same day]**: the webaudio probe now registers every track
  Meet routes through WebAudio in `window.__earsWebAudioTracks` (real track
  objects, reachable live — the gap that blocked measurement during this
  capture) and, with `localStorage.__earsDebugAudio = "1"`, attaches a
  throttled per-track peak meter (`[ears][probe][webaudio] energy …`) to
  createMediaStreamSource inputs and audio MediaStreamTrackGenerator
  outputs. The next affected call answers the per-participant question.
- **[Implemented same day]** Watchdogs: daemon-side, MeetingRegistry logs
  `⚠ meeting.browser_audio_missing` when a browser-triggered meeting has ≥2
  named attendees but no `browser:*` source (armed at start, re-armed per
  attendee upsert), and CaptureActor logs `capture.push_source_dry` once per
  episode when a browser source delivers nothing for 2 minutes — the exact
  shapes of the morning failure and this test call's mid-call death. The
  never-a-first-frame page-side case was already covered by
  SilentCaptureWatchdog (journal #72).
- The extension's existing zero-streams warning (rtc-hook.ts
  `installMeetEncodedAudioTee`) never fired because Meet still *calls*
  createEncodedStreams and frames *do* flow briefly — the "channel live but
  nothing parsing" heuristic needs a mid-call continuation check, not just a
  startup check. (The daemon's push_source_dry watchdog now provides the
  equivalent signal from the receiving end.)
