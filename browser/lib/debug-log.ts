// Debug logging plumbing shared by every extension context.
//
// There is no logger abstraction in this codebase — ~100 call sites log
// straight to `console.*` with an `[ears]…` prefix. Rather than rewrite them,
// debug mode *taps* the global console: each method is wrapped to still log as
// before, then hand a structured entry to a sink. Each context ships its
// entries to the background service worker, which persists them to a capped
// IndexedDB ring (log-store.ts) the popup can export as a file.
//
// Off by default (DEBUG_LOG_KEY in capture-toggle.ts). Nothing here runs, and
// the console is left untouched, unless the user turns debug logging on.

/** Console methods tapped, in severity order. */
export type LogLevel = "debug" | "log" | "info" | "warn" | "error";

/** One captured console call. `t` is epoch ms; `ctx` names the origin realm
 * ("bg" | "relay" | "hook"); `msg` is the joined, stringified arguments. */
export interface LogEntry {
  t: number;
  ctx: string;
  level: LogLevel;
  msg: string;
}

const LEVELS: LogLevel[] = ["debug", "log", "info", "warn", "error"];

/** Cap per-entry text so one pathological object dump can't bloat the ring. */
const MAX_MSG_LEN = 8192;

/** Circular-safe JSON, falling back to String() if even that throws. */
function safeStringify(v: unknown): string {
  const seen = new WeakSet<object>();
  try {
    return (
      JSON.stringify(v, (_k, val) => {
        if (typeof val === "bigint") return `${val}n`;
        if (typeof val === "object" && val !== null) {
          if (seen.has(val)) return "[Circular]";
          seen.add(val);
        }
        return val;
      }) ?? String(v)
    );
  } catch {
    return String(v);
  }
}

/** Render one console argument the way it reads in devtools (Errors keep their
 * stack; objects serialize; primitives stringify). */
export function serializeArg(v: unknown): string {
  if (typeof v === "string") return v;
  if (v instanceof Error) return v.stack ?? `${v.name}: ${v.message}`;
  if (v === null) return "null";
  if (v === undefined) return "undefined";
  if (typeof v === "object") return safeStringify(v);
  return String(v);
}

export function serializeArgs(args: unknown[]): string {
  return args.map(serializeArg).join(" ").slice(0, MAX_MSG_LEN);
}

/** The subset of `console` the tap wraps — real `console` in production, a
 * fake in tests. */
export type ConsoleLike = Record<LogLevel, (...args: unknown[]) => void>;

const TAP = Symbol.for("ears.consoleTap");

/**
 * Wrap `target`'s console methods so each call still logs as before, then
 * emits a {@link LogEntry} to `sink`. Idempotent (a second call returns the
 * first uninstall). Re-entrancy guarded: a sink that itself logs can't recurse.
 * Returns an uninstall function that restores the original methods.
 */
export function installConsoleTap(
  ctx: string,
  sink: (entry: LogEntry) => void,
  target: ConsoleLike = globalThis.console as unknown as ConsoleLike,
): () => void {
  const t = target as ConsoleLike & { [TAP]?: () => void };
  if (t[TAP]) return t[TAP];

  const originals = {} as Record<LogLevel, ConsoleLike[LogLevel]>;
  let inSink = false;
  for (const level of LEVELS) {
    const orig = t[level]?.bind(t) ?? (() => {});
    originals[level] = t[level];
    t[level] = (...args: unknown[]) => {
      orig(...args);
      if (inSink) return; // a logging sink must not tap its own output
      inSink = true;
      try {
        sink({ t: Date.now(), ctx, level, msg: serializeArgs(args) });
      } catch {
        // Logging must never break the app it observes.
      } finally {
        inSink = false;
      }
    };
  }

  const uninstall = (): void => {
    for (const level of LEVELS) t[level] = originals[level];
    delete t[TAP];
  };
  t[TAP] = uninstall;
  return uninstall;
}

/** Coalesces entries so a busy context ships one message per batch, not per
 * line. Flushes when it fills or after a short delay, whichever comes first. */
export interface Batcher {
  push(entry: LogEntry): void;
  /** Ship whatever is buffered now (also cancels the pending timer). */
  flush(): void;
  /** Drop the buffer and cancel the timer without shipping. */
  stop(): void;
}

export function createBatcher(
  ship: (entries: LogEntry[]) => void,
  { maxSize = 50, maxDelayMs = 1000 }: { maxSize?: number; maxDelayMs?: number } = {},
): Batcher {
  let buf: LogEntry[] = [];
  let timer: ReturnType<typeof setTimeout> | null = null;

  const flush = (): void => {
    if (timer !== null) {
      clearTimeout(timer);
      timer = null;
    }
    if (buf.length === 0) return;
    const batch = buf;
    buf = [];
    ship(batch);
  };

  return {
    push(entry: LogEntry): void {
      buf.push(entry);
      if (buf.length >= maxSize) {
        flush();
        return;
      }
      if (timer === null) timer = setTimeout(flush, maxDelayMs);
    },
    flush,
    stop(): void {
      if (timer !== null) {
        clearTimeout(timer);
        timer = null;
      }
      buf = [];
    },
  };
}

/** Serialize entries to newline-delimited JSON for file export. */
export function toJsonl(entries: LogEntry[]): string {
  if (entries.length === 0) return "";
  return entries.map((e) => JSON.stringify(e)).join("\n") + "\n";
}
