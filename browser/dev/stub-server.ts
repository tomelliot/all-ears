// Throwaway earsd ingest stub for Phase 3. Speaks the transport.md wire
// protocol: accepts ws://127.0.0.1:<port>/ingest, replies to ingest.open text
// frames with {"ok":true,"data":{"stream_id":"sN"}}, acks ingest.close, drains
// binary PCM frames ([u8 idLen][stream_id][pcm_s16le]) and dumps each source to
// a .wav so isolation is checkable by ear (or by tone).
//
//   bun dev/stub-server.ts [port] [outDir]
// env STUB_ALLOWED_ORIGINS="a,b"  → Origin allowlist (empty ⇒ allow all, for
//                                    dev; earsd itself fails closed on empty).
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const port = Number(process.argv[2] ?? 47811);
const outDir = process.argv[3] ?? "./stub-wavs";
mkdirSync(outDir, { recursive: true });

const allowlist = (process.env.STUB_ALLOWED_ORIGINS ?? "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

interface Stream {
  source: string;
  chunks: Buffer[];
  bytes: number;
}
// stream_id → stream. Also per-connection so ids reset on reconnect.
interface ConnData {
  streams: Map<string, Stream>;
  nextId: number;
}

let totalOpens = 0;
const activeStreams = new Set<Stream>();

function wavFromPcm(pcm: Buffer, rate = 16000): Buffer {
  const header = Buffer.alloc(44);
  const dataLen = pcm.length;
  header.write("RIFF", 0); header.writeUInt32LE(36 + dataLen, 4); header.write("WAVE", 8);
  header.write("fmt ", 12); header.writeUInt32LE(16, 16); header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22); header.writeUInt32LE(rate, 24); header.writeUInt32LE(rate * 2, 28);
  header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34);
  header.write("data", 36); header.writeUInt32LE(dataLen, 40);
  return Buffer.concat([header, pcm]);
}

function dumpStream(s: Stream): void {
  if (s.bytes === 0) return;
  const safe = s.source.replace(/[^A-Za-z0-9._-]/g, "_");
  const path = join(outDir, `${safe}.wav`);
  writeFileSync(path, wavFromPcm(Buffer.concat(s.chunks)));
  console.log(`[stub] dumped ${s.source} → ${path} (${(s.bytes / 32000).toFixed(2)}s)`);
}

const server = Bun.serve<ConnData, string>({
  port,
  hostname: "127.0.0.1",
  fetch(req, srv) {
    const url = new URL(req.url);
    if (url.pathname !== "/ingest") return new Response("not found", { status: 404 });

    const origin = req.headers.get("origin");
    if (allowlist.length && (!origin || !allowlist.includes(origin))) {
      console.log(`[stub] 403 rejected origin: ${origin ?? "(none)"}`);
      return new Response("forbidden", { status: 403 });
    }
    console.log(`[stub] upgrade from origin: ${origin ?? "(none)"}`);
    if (srv.upgrade(req, { data: { streams: new Map(), nextId: 0 } })) return undefined;
    return new Response("upgrade failed", { status: 400 });
  },
  websocket: {
    message(ws, message) {
      const data = ws.data;
      if (typeof message === "string") {
        let req: { cmd?: string; source?: string; stream_id?: string };
        try {
          req = JSON.parse(message);
        } catch {
          ws.send(JSON.stringify({ ok: false, error: "bad json" }));
          return;
        }
        if (req.cmd === "ingest.open") {
          const streamId = `s${++data.nextId}`;
          const stream: Stream = { source: req.source ?? "unknown", chunks: [], bytes: 0 };
          data.streams.set(streamId, stream);
          activeStreams.add(stream);
          totalOpens++;
          console.log(`[stub] ingest.open ${req.source} → ${streamId}`);
          ws.send(JSON.stringify({ ok: true, data: { stream_id: streamId } }));
        } else if (req.cmd === "ingest.close") {
          const s = req.stream_id ? data.streams.get(req.stream_id) : undefined;
          if (s) { dumpStream(s); activeStreams.delete(s); data.streams.delete(req.stream_id!); }
          console.log(`[stub] ingest.close ${req.stream_id}`);
          ws.send(JSON.stringify({ ok: true, data: {} }));
        } else {
          // Ingest-only: reject any other cmd (mirrors earsd).
          ws.send(JSON.stringify({ ok: false, error: `unsupported cmd: ${req.cmd}` }));
        }
        return;
      }
      // Binary PCM frame: [u8 idLen][stream_id][pcm_s16le]
      const buf = message as Buffer;
      if (buf.length < 1) return;
      const idLen = buf[0]!;
      if (buf.length < 1 + idLen) return; // malformed header — drop, don't crash
      const streamId = buf.toString("ascii", 1, 1 + idLen);
      const pcm = buf.subarray(1 + idLen);
      const s = data.streams.get(streamId);
      if (!s) { console.warn(`[stub] pcm for unknown stream ${streamId}`); return; }
      s.chunks.push(Buffer.from(pcm));
      s.bytes += pcm.length;
    },
    close(ws) {
      for (const s of ws.data.streams.values()) { dumpStream(s); activeStreams.delete(s); }
      console.log("[stub] connection closed");
    },
  },
});

console.log(`[stub] earsd ingest stub on ws://127.0.0.1:${server.port}/ingest`);
console.log(`[stub] allowlist: ${allowlist.length ? allowlist.join(", ") : "(all origins allowed)"}`);
console.log(`[stub] wav out: ${outDir}`);
// Periodically flush active streams so WAVs are available while running (tones
// in the harness never "leave", so they'd otherwise only dump on disconnect).
setInterval(() => {
  for (const s of activeStreams) dumpStream(s);
}, 2000);

