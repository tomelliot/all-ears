// Synthetic WebRTC loopback for Phase 1 verification. Runs in the page (MAIN
// world). Builds a local pc1→pc2 call carrying N oscillator audio tracks, so
// the extension's hook should fire one `track` event per track on pc2. Then it
// exercises mid-call add, track removal, and epoch re-injection.
//
// Crucially it uses the constructor CACHED AT HEAD TIME (window.__earsProbe.
// cachedCtor) — mimicking Zoom — so if the hook lost the injection race, no
// tracks are captured.

const logEl = document.getElementById("log");
function log(...a) {
  const line = a.join(" ");
  console.log("[harness]", line);
  if (logEl) logEl.textContent += line + "\n";
}

const RTC = window.__earsProbe.cachedCtor; // the Zoom-style cached constructor
const audioCtx = new AudioContext();
audioCtx.resume().then(() => log(`source audioCtx state=${audioCtx.state} rate=${audioCtx.sampleRate}`));

// Build one oscillator → MediaStreamTrack.
let freqBase = 220;
function makeAudioTrack(freq) {
  const osc = audioCtx.createOscillator();
  osc.frequency.value = freq;
  const dest = audioCtx.createMediaStreamDestination();
  osc.connect(dest);
  osc.start();
  return dest.stream.getAudioTracks()[0];
}

async function loopback(nTracks) {
  const pc1 = new RTC();
  const pc2 = new RTC();
  pc1.onicecandidate = (e) => e.candidate && pc2.addIceCandidate(e.candidate);
  pc2.onicecandidate = (e) => e.candidate && pc1.addIceCandidate(e.candidate);

  let received = 0;
  pc2.addEventListener("track", (e) => {
    received++;
    log(`pc2 received track ${received}/${nTracks} kind=${e.track.kind}`);
  });
  // Authoritative check: does RTP audio actually flow? getStats inbound-rtp.
  setTimeout(async () => {
    const stats = await pc2.getStats();
    let line = "pc2 conn=" + pc2.connectionState + " ice=" + pc2.iceConnectionState;
    stats.forEach((r) => {
      if (r.type === "inbound-rtp" && r.kind === "audio")
        line += ` | in-rtp bytes=${r.bytesReceived} audioLevel=${r.audioLevel ?? "n/a"}`;
    });
    log(line);
    const s1 = await pc1.getStats();
    let l2 = "pc1";
    s1.forEach((r) => {
      if (r.type === "outbound-rtp" && r.kind === "audio") l2 += ` | out-rtp bytes=${r.bytesSent}`;
      if (r.type === "media-source") l2 += ` | src audioLevel=${r.audioLevel ?? "n/a"}`;
    });
    log(l2);
  }, 2500);

  const senders = [];
  for (let i = 0; i < nTracks; i++) {
    const track = makeAudioTrack(freqBase + i * 110);
    senders.push(pc1.addTrack(track, new MediaStream([track])));
  }

  const offer = await pc1.createOffer();
  await pc1.setLocalDescription(offer);
  await pc2.setRemoteDescription(offer);
  const answer = await pc2.createAnswer();
  await pc2.setLocalDescription(answer);
  await pc1.setRemoteDescription(answer);

  return { pc1, pc2, senders };
}

async function renegotiate(a, b) {
  const offer = await a.createOffer();
  await a.setLocalDescription(offer);
  await b.setRemoteDescription(offer);
  const answer = await b.createAnswer();
  await b.setLocalDescription(answer);
  await a.setRemoteDescription(answer);
}

function reinject() {
  // Simulate a re-injection (new capture epoch in the same realm). The dev
  // build exposes __earsDevReinit; the epoch must supersede — tearing down the
  // old pipelines and re-adopting the live tracks — without doubling the count.
  const fn = window.__earsDevReinit;
  if (typeof fn !== "function") {
    log("REINJECT: __earsDevReinit not present (non-dev build)");
    return;
  }
  log("REINJECT: invoking __earsDevReinit — expect epoch handoff, live count unchanged");
  fn();
}

// Local-stream content test: feed distinct pure tones through the real capture
// graph (bypassing WebRTC, which a sandboxed browser can't loopback-connect).
// Verifies worklet downsample + PCM + isolation: each id → one frequency.
async function localToneTest() {
  const tones = [
    { id: "tone-220", hz: 220 },
    { id: "tone-330", hz: 330 },
    { id: "tone-440", hz: 440 },
  ];
  if (typeof window.__earsDevCapture !== "function") {
    log("LOCAL: __earsDevCapture missing (non-dev build)");
    return;
  }
  for (const t of tones) {
    const osc = audioCtx.createOscillator();
    osc.frequency.value = t.hz;
    const dest = audioCtx.createMediaStreamDestination();
    osc.connect(dest);
    osc.start();
    window.__earsDevCapture(dest.stream, t.id);
    log(`LOCAL: capturing ${t.id} (${t.hz} Hz)`);
  }
  await new Promise((r) => setTimeout(r, 4000));
  log("LOCAL: done");
}

(async () => {
  log(`TIMING: hook ${window.__earsProbe.wrappedAtHead ? "WON" : "LOST"} the head-time race (cached ctor is ${window.__earsProbe.wrappedAtHead ? "our wrapper" : "native"})`);

  await localToneTest();

  log("--- opening call with 3 audio tracks ---");
  const call = await loopback(3);

  await new Promise((r) => setTimeout(r, 1500));
  log("--- mid-call: adding a 4th track ---");
  const t4 = makeAudioTrack(660);
  call.pc1.addTrack(t4, new MediaStream([t4]));
  await renegotiate(call.pc1, call.pc2);

  await new Promise((r) => setTimeout(r, 1500));
  log("--- removing track 1 — expect participant-left ---");
  // Removing the sender + renegotiating drives the receiver track to 'ended',
  // which is what a real participant-leave looks like on the receive side.
  call.pc1.removeTrack(call.senders[0]);
  await renegotiate(call.pc1, call.pc2);

  await new Promise((r) => setTimeout(r, 1500));
  log("--- re-injecting to test capture epoch ---");
  reinject();

  await new Promise((r) => setTimeout(r, 1500));
  log("--- hanging up (pc1.close) — expect participant-left for remaining tracks ---");
  call.pc1.close();
  call.pc2.close();

  await new Promise((r) => setTimeout(r, 1500));
  log("--- DONE ---");
  window.__earsHarnessDone = true;
})();
