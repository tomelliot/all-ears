// Tiny static server for the Phase 1 synthetic harness. Serves harness.html and
// harness.js from this directory on http://localhost:<port>.
//   bun dev/harness-server.ts [port]
import { file } from "bun";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const port = Number(process.argv[2] ?? 8899);

Bun.serve({
  port,
  hostname: "127.0.0.1",
  async fetch(req) {
    const url = new URL(req.url);
    const path = url.pathname === "/" ? "/harness.html" : url.pathname;
    const f = file(join(here, path));
    if (await f.exists()) {
      const type = path.endsWith(".js") ? "text/javascript" : "text/html";
      return new Response(f, { headers: { "content-type": type } });
    }
    return new Response("not found", { status: 404 });
  },
});

console.log(`harness server on http://localhost:${port}`);
