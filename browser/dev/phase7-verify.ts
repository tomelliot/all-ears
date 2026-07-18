// Phase 7 lifecycle verification: drives the dev-built extension through the
// capture-toggle and service-worker-respawn scenarios in real Chromium,
// asserting against the stub server's log — the far end of the real wire.
//
// Prereqs (three terminals, or background the servers):
//   WXT_DEV_LOCALHOST=1 bun run build     # extension with localhost matches
//   bun dev/stub-server.ts 47811 ./stub-wavs > stub.log 2>&1
//   bun dev/harness-server.ts 8899
//   STUB_LOG=./stub.log bun dev/phase7-verify.ts
//
// Env:
//   STUB_LOG          path to the stub server's captured stdout (required)
//   PHASE7_CHROMIUM   chromium binary (default: playwright-core's own registry)
//   SOAK_MINUTES      extra endurance phase: keep the call up N minutes and
//                     assert stream count stays exactly 2 (no leak/double) and
//                     PCM never stalls (default 0 = skip)
//
// Scenarios (all previously verified green, 24/24 — see roadmap Phase 7 status):
//   A  stock harness: injection race, capture, epoch reinject, tab-close cleanup
//   B1 PCM flows; keepalive alarm armed; session state persisted
//   B2 toggle OFF mid-call: pipelines torn down, streams ingest.closed, no wakes
//   B3 toggle ON mid-call: live tracks re-adopted, PCM resumes
//   B4 service worker force-killed (CDP Target.closeTarget — the scriptable
//      equivalent of chrome://serviceworker-internals "Stop"): port lazily
//      reconnects, worker respawns, PCM resumes with NO tab reload
//   B5 hangup: alarm + session state cleared, streams closed
//
// Remote tracks get an <audio> sink on the page: without playback Chromium's
// receive pipeline never decodes and MediaStreamTrackProcessor delivers zero
// frames (verified empirically — inbound-rtp bytes climb, audioLevel stays 0).
// Real meeting pages always play remote audio, so the sink mirrors reality.
import { readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { chromium } from "playwright-core";

const EXT = resolve(import.meta.dirname, "../.output/chrome-mv3");
const STUB_LOG = process.env.STUB_LOG;
if (!STUB_LOG) {
  console.error("STUB_LOG env var required (path to stub-server stdout)");
  process.exit(2);
}
const SOAK_MINUTES = Number(process.env.SOAK_MINUTES ?? 0);

const results: [string, boolean, string][] = [];
function check(name: string, ok: boolean, detail = "") {
  results.push([name, ok, detail]);
  console.log(`${ok ? "PASS" : "FAIL"}  ${name}${detail ? ` — ${detail}` : ""}`);
}
const step = (s: string) => console.log(`>> ${s}`);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

let stubOffset = 0;
function stubSince(): string {
  const all = readFileSync(STUB_LOG!, "utf8");
  const out = all.slice(stubOffset);
  stubOffset = all.length;
  return out;
}
const count = (s: string, needle: string) => s.split(needle).length - 1;

const watchdog = setTimeout(() => {
  console.log("WATCHDOG: timed out, aborting");
  process.exit(2);
}, 240_000 + SOAK_MINUTES * 65_000);

const ctx = await chromium.launchPersistentContext(join(tmpdir(), `ears-phase7-${process.pid}`), {
  executablePath: process.env.PHASE7_CHROMIUM,
  headless: true,
  args: [
    `--disable-extensions-except=${EXT}`,
    `--load-extension=${EXT}`,
    "--autoplay-policy=no-user-gesture-required",
    "--no-sandbox",
  ],
});

step("waiting for service worker");
if (ctx.serviceWorkers().length === 0) await ctx.waitForEvent("serviceworker", { timeout: 15000 });
const extId = ctx.serviceWorkers()[0]!.url().split("/")[2];
console.log("service worker:", ctx.serviceWorkers()[0]!.url());

/** Evaluate in the CURRENT worker target, bounded — a stopped worker's stale
 * handle would otherwise hang the protocol call forever. */
async function swEval(js: string): Promise<unknown> {
  const w = ctx.serviceWorkers().at(-1);
  if (!w) return "NO_WORKER";
  return Promise.race([w.evaluate(js), sleep(5000).then(() => "EVAL_TIMEOUT")]);
}

// ── Popup: renders as a real extension page ─────────────────────────────────
const pop = await ctx.newPage();
await pop.goto(`chrome-extension://${extId}/popup.html`);
await sleep(1500);
const popState = (await pop.evaluate(
  "({checked: document.getElementById('toggle').checked, disabled: document.getElementById('toggle').disabled, status: document.getElementById('status-text').textContent})",
)) as { checked: boolean; disabled: boolean; status: string };
check("popup: toggle live and defaulted ON", popState.checked && !popState.disabled, JSON.stringify(popState));
check("popup: transport status rendered", /earsd/.test(popState.status), popState.status);
await pop.close();

// ── Phase A: stock harness scenario ─────────────────────────────────────────
step("phase A: stock harness scenario");
const pageLogs: string[] = [];
const page = await ctx.newPage();
page.on("console", (m) => pageLogs.push(m.text()));
stubSince();
await page.goto("http://localhost:8899/");
await page.waitForFunction("window.__earsHarnessDone === true", { timeout: 60000 });

check("A: hook won head-time race", pageLogs.some((l) => l.includes("hook already installed = true")));
check("A: 3 initial + 1 mid-call tracks captured", pageLogs.filter((l) => l.includes("[ears] +track")).length >= 4,
  `${pageLogs.filter((l) => l.includes("[ears] +track")).length} +track events`);
check("A: participant-left seen", pageLogs.some((l) => l.includes("[ears] -track")));
check("A: epoch reinject handed off", pageLogs.some((l) => l.includes("capture epoch 2 active")));
const aStub = stubSince();
check("A: tone PCM reached the stub over the real wire", count(aStub, "ingest.open browser:") >= 3,
  `${count(aStub, "ingest.open browser:")} opens`);
await page.close();
await sleep(1500);
check("A: page close closed its streams (no leak)", count(stubSince(), "ingest.close") >= 3);

// ── Phase B: controlled long-lived call ─────────────────────────────────────
step("phase B: quiet page + long-lived 2-track call with playback sinks");
const logs: string[] = [];
const quiet = await ctx.newPage();
quiet.on("console", (m) => logs.push(m.text()));
await quiet.route("**/quiet.html", (r) =>
  r.fulfill({ contentType: "text/html", body: "<!doctype html><title>quiet</title><p>quiet</p>" }),
);
await quiet.goto("http://localhost:8899/quiet.html");
const since = () => logs.splice(0, logs.length);

await quiet.evaluate(`(async () => {
  const audioCtx = new AudioContext();
  await audioCtx.resume();
  const mkTrack = (hz) => {
    const osc = audioCtx.createOscillator();
    osc.frequency.value = hz;
    const dest = audioCtx.createMediaStreamDestination();
    osc.connect(dest);
    osc.start();
    return dest.stream.getAudioTracks()[0];
  };
  const pc1 = new RTCPeerConnection();
  const pc2 = new RTCPeerConnection();
  window.__call = { pc1, pc2 };
  pc1.onicecandidate = (e) => e.candidate && pc2.addIceCandidate(e.candidate);
  pc2.onicecandidate = (e) => e.candidate && pc1.addIceCandidate(e.candidate);
  pc2.addEventListener("track", (e) => {
    const el = document.createElement("audio");
    el.autoplay = true;
    el.srcObject = new MediaStream([e.track]);
    document.body.appendChild(el);
    el.play().catch(() => {});
  });
  for (const hz of [250, 470]) {
    const t = mkTrack(hz);
    pc1.addTrack(t, new MediaStream([t]));
  }
  const offer = await pc1.createOffer();
  await pc1.setLocalDescription(offer);
  await pc2.setRemoteDescription(offer);
  const answer = await pc2.createAnswer();
  await pc2.setLocalDescription(answer);
  await pc1.setRemoteDescription(answer);
})()`);
await sleep(5000);

let drained = since();
let stub = stubSince();
check("B1: capture started on both tracks", drained.filter((l) => l.includes("[ears] +track")).length === 2);
check("B1: PCM for both participants reached the stub", count(stub, "ingest.open browser:teams:speaker-") === 2,
  `${count(stub, "ingest.open browser:teams:speaker-")} opens`);
const alarmsDuring = (await swEval("chrome.alarms.getAll()")) as { name: string }[];
check("B1: keepalive alarm armed during call",
  Array.isArray(alarmsDuring) && alarmsDuring.some((a) => a.name === "ears-capture-keepalive"),
  JSON.stringify(alarmsDuring));
const sessDuring = (await swEval("chrome.storage.session.get('captureSession')")) as
  | { captureSession?: { active?: boolean } }
  | string;
check("B1: session state persisted", typeof sessDuring === "object" && sessDuring?.captureSession?.active === true,
  JSON.stringify(sessDuring));

step("toggling capture OFF");
await swEval("chrome.storage.local.set({ captureEnabled: false })");
await sleep(3000);
drained = since();
stub = stubSince();
check("B2: toggle OFF tears down pipelines", drained.some((l) => l.includes("capture disabled")));
check("B2: both streams closed on earsd side", count(stub, "ingest.close") === 2, `${count(stub, "ingest.close")} closes`);
const sessOff = (await swEval("chrome.storage.session.get('captureSession')")) as Record<string, unknown> | string;
check("B2: session state cleared after OFF", typeof sessOff === "object" && sessOff.captureSession === undefined,
  JSON.stringify(sessOff));
const alarmsOff = (await swEval("chrome.alarms.getAll()")) as { name: string }[];
check("B2: alarm cleared after OFF", Array.isArray(alarmsOff) && !alarmsOff.some((a) => a.name === "ears-capture-keepalive"));
await sleep(2000);
check("B2: no PCM while off", count(stubSince(), "ingest.open") === 0);

step("toggling capture ON mid-call");
await swEval("chrome.storage.local.set({ captureEnabled: true })");
await sleep(5000);
drained = since();
stub = stubSince();
check("B3: toggle ON re-adopts live tracks", drained.filter((l) => l.includes("[ears] +track")).length === 2);
check("B3: PCM resumed to the stub", count(stub, "ingest.open browser:teams:speaker-") === 2,
  `${count(stub, "ingest.open browser:teams:speaker-")} opens`);

step("force-stopping service worker (Target.closeTarget)");
const browser = ctx.browser();
let killed = false;
if (browser) {
  const bcdp = await browser.newBrowserCDPSession();
  const { targetInfos } = (await bcdp.send("Target.getTargets")) as {
    targetInfos: { type: string; url: string; targetId: string }[];
  };
  const swT = targetInfos.find((t) => t.type === "service_worker" && t.url.includes("background.js"));
  if (swT) {
    await bcdp.send("Target.closeTarget", { targetId: swT.targetId });
    killed = true;
  }
}
check("B4: service worker force-stopped", killed);
step("waiting for recovery (content port reconnect must respawn the worker)");
await sleep(7000);
stub = stubSince();
check("B4: transport reconnected after respawn", count(stub, "upgrade from origin") >= 1);
check("B4: PCM resumed after respawn without tab reload", count(stub, "ingest.open browser:teams:speaker-") === 2,
  `${count(stub, "ingest.open browser:teams:speaker-")} opens`);
const alarmsResp = (await swEval("chrome.alarms.getAll()")) as { name: string }[];
check("B4: keepalive armed after respawn", Array.isArray(alarmsResp) && alarmsResp.some((a) => a.name === "ears-capture-keepalive"),
  JSON.stringify(alarmsResp));

// ── Optional soak: no leak, no double, no drop over N minutes ───────────────
if (SOAK_MINUTES > 0) {
  step(`soak: holding the call for ${SOAK_MINUTES} min`);
  const wavPath = process.env.SOAK_WAV; // e.g. ./stub-wavs/browser_teams_speaker-1.wav
  let lastWav = 0;
  let stalls = 0;
  let extraOpens = 0;
  for (let min = 1; min <= SOAK_MINUTES; min++) {
    await sleep(60_000);
    extraOpens += count(stubSince(), "ingest.open");
    let wavSize = lastWav + 1;
    if (wavPath) {
      try {
        wavSize = statSync(wavPath).size;
      } catch {
        wavSize = 0;
      }
      if (wavSize <= lastWav) stalls++;
    }
    console.log(`soak ${min}/${SOAK_MINUTES}: extraOpens=${extraOpens} wav=${(wavSize / 32000).toFixed(1)}s`);
    lastWav = wavSize;
  }
  check("soak: no stream doubling or re-open churn", extraOpens === 0, `${extraOpens} extra opens`);
  if (wavPath) check("soak: PCM never stalled", stalls === 0, `${stalls} stalled minute(s)`);
}

step("hanging up");
await quiet.evaluate("window.__call.pc1.close(); window.__call.pc2.close();");
await sleep(3500);
const alarmsEnd = (await swEval("chrome.alarms.getAll()")) as { name: string }[];
check("B5: alarm cleared after hangup", Array.isArray(alarmsEnd) && !alarmsEnd.some((a) => a.name === "ears-capture-keepalive"),
  JSON.stringify(alarmsEnd));
const sessEnd = (await swEval("chrome.storage.session.get('captureSession')")) as Record<string, unknown> | string;
check("B5: session state cleared after hangup", typeof sessEnd === "object" && !sessEnd.captureSession,
  JSON.stringify(sessEnd));
check("B5: hangup closed both streams", count(stubSince(), "ingest.close") >= 2);

await ctx.close();
clearTimeout(watchdog);

console.log("\n=== RESULT ===");
const failed = results.filter(([, ok]) => !ok);
console.log(`${results.length - failed.length}/${results.length} checks passed`);
process.exit(failed.length ? 1 : 0);
