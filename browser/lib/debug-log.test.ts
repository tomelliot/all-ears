import { afterEach, describe, expect, it, vi } from "vitest";
import {
  createBatcher,
  installConsoleTap,
  serializeArg,
  serializeArgs,
  toJsonl,
  type ConsoleLike,
  type LogEntry,
} from "./debug-log";

function fakeConsole(): ConsoleLike & { out: string[] } {
  const out: string[] = [];
  const mk =
    (level: string) =>
    (...args: unknown[]) =>
      out.push(`${level}:${args.join(" ")}`);
  return { out, debug: mk("debug"), log: mk("log"), info: mk("info"), warn: mk("warn"), error: mk("error") };
}

describe("serializeArg", () => {
  it("passes strings through and stringifies primitives", () => {
    expect(serializeArg("hi")).toBe("hi");
    expect(serializeArg(42)).toBe("42");
    expect(serializeArg(true)).toBe("true");
    expect(serializeArg(null)).toBe("null");
    expect(serializeArg(undefined)).toBe("undefined");
  });

  it("keeps an Error's stack", () => {
    const err = new Error("boom");
    expect(serializeArg(err)).toContain("boom");
  });

  it("serializes objects and survives circular references", () => {
    expect(serializeArg({ a: 1 })).toBe('{"a":1}');
    const cyclic: Record<string, unknown> = { name: "x" };
    cyclic.self = cyclic;
    const out = serializeArg(cyclic);
    expect(out).toContain('"name":"x"');
    expect(out).toContain("[Circular]");
  });

  it("joins multiple args with spaces", () => {
    expect(serializeArgs(["[ears]", "count", 3])).toBe("[ears] count 3");
  });
});

describe("installConsoleTap", () => {
  it("still logs, and emits a structured entry per call", () => {
    const con = fakeConsole();
    const entries: LogEntry[] = [];
    installConsoleTap("test", (e) => entries.push(e), con);

    con.debug("[ears] hello", 1);
    con.warn("[ears] uh oh");

    expect(con.out).toEqual(["debug:[ears] hello 1", "warn:[ears] uh oh"]);
    expect(entries).toHaveLength(2);
    expect(entries[0]).toMatchObject({ ctx: "test", level: "debug", msg: "[ears] hello 1" });
    expect(entries[1]).toMatchObject({ ctx: "test", level: "warn", msg: "[ears] uh oh" });
    expect(typeof entries[0]!.t).toBe("number");
  });

  it("does not recurse when the sink itself logs", () => {
    const con = fakeConsole();
    let count = 0;
    installConsoleTap("test", () => {
      count += 1;
      con.log("sink is logging"); // must not re-enter the tap
    }, con);

    con.log("trigger");
    expect(count).toBe(1);
  });

  it("is idempotent and restores the originals on uninstall", () => {
    const con = fakeConsole();
    const original = con.log;
    const entries: LogEntry[] = [];
    const off1 = installConsoleTap("a", (e) => entries.push(e), con);
    const off2 = installConsoleTap("b", (e) => entries.push(e), con);
    expect(off2).toBe(off1); // second install is a no-op

    con.log("[ears] one");
    expect(entries).toHaveLength(1);
    expect(entries[0]!.ctx).toBe("a"); // first sink wins

    off1();
    expect(con.log).toBe(original);
    con.log("[ears] two");
    expect(entries).toHaveLength(1); // no longer tapped
  });
});

describe("createBatcher", () => {
  afterEach(() => vi.useRealTimers());

  const entry = (msg: string): LogEntry => ({ t: 0, ctx: "x", level: "log", msg });

  it("flushes when it reaches maxSize", () => {
    const batches: LogEntry[][] = [];
    const b = createBatcher((e) => batches.push(e), { maxSize: 2, maxDelayMs: 1000 });
    b.push(entry("a"));
    expect(batches).toHaveLength(0);
    b.push(entry("b"));
    expect(batches).toHaveLength(1);
    expect(batches[0]!.map((e) => e.msg)).toEqual(["a", "b"]);
  });

  it("flushes on the timer when under maxSize", () => {
    vi.useFakeTimers();
    const batches: LogEntry[][] = [];
    const b = createBatcher((e) => batches.push(e), { maxSize: 50, maxDelayMs: 1000 });
    b.push(entry("a"));
    expect(batches).toHaveLength(0);
    vi.advanceTimersByTime(1000);
    expect(batches).toHaveLength(1);
    expect(batches[0]!.map((e) => e.msg)).toEqual(["a"]);
  });

  it("stop() drops the buffer without shipping", () => {
    vi.useFakeTimers();
    const batches: LogEntry[][] = [];
    const b = createBatcher((e) => batches.push(e), { maxDelayMs: 1000 });
    b.push(entry("a"));
    b.stop();
    vi.advanceTimersByTime(5000);
    expect(batches).toHaveLength(0);
  });
});

describe("toJsonl", () => {
  it("is empty for no entries and newline-delimited otherwise", () => {
    expect(toJsonl([])).toBe("");
    const out = toJsonl([
      { t: 1, ctx: "bg", level: "log", msg: "one" },
      { t: 2, ctx: "hook", level: "warn", msg: "two" },
    ]);
    expect(out).toBe('{"t":1,"ctx":"bg","level":"log","msg":"one"}\n{"t":2,"ctx":"hook","level":"warn","msg":"two"}\n');
  });
});
