# EarsLogging

I/O half of the logging system specified in `docs/logging.md`. The pure
schema and encoders (`LogRecord`, `LogValue`, `LogField`,
`LogRecordJSONEncoder`, `LogRecordPrettyRenderer`) live in
`Sources/EarsCore/Logging/` — this target adds the parts that touch disk,
stderr, and `os.Logger`:

| Type | Role |
|---|---|
| `FileLogWriter` | Actor. Appends JSON Lines to a file, rotates by size/count. |
| `LogSink` | Actor. Fans one `LogRecord` out to the file, stderr, and the unified-logging mirror. |
| `UnifiedLogging` / `OSLogUnifiedLogging` | Mockable seam over `os.Logger`. |
| `StderrWriting` / `RealStderrWriter` | Mockable seam over the stderr write syscall. |
| `TTYDetecting` / `RealTTYDetector` | Mockable seam over `isatty(STDERR_FILENO)`. |
| `RunSummary` | Builds the one-shot tools' final `run.summary` record. |

## Rotation scheme

`docs/logging.md` requires rotation by size and count but leaves the exact
algorithm unspecified, so it's documented here rather than left to whoever
next reads `FileLogWriter`'s source.

`FileLogWriter.RotationPolicy` has two fields, named after the doc's config
keys:

- `rotateMaxBytes` — rotate before a write would push the active file past
  this many bytes.
- `rotateMaxFiles` — the **total** number of files kept at once, active file
  included: `tool.jsonl` (active) plus `tool.jsonl.1` … `tool.jsonl.<N-1>`
  (oldest-last, numbered backups). This is the conventional logrotate
  numbered-suffix scheme, `rotate <N-1>` in logrotate's own terms.

On rotation (`FileLogWriter.rotate()`):

1. If `rotateMaxFiles <= 1`: no backups are kept. The active file is
   truncated in place (recreated empty) — this is the one case where
   rotating loses data rather than archiving it, and it exists so
   `rotateMaxFiles: 1` is a legal, if degenerate, configuration rather than
   a special error case callers must avoid.
2. Otherwise, classic logrotate shifting, oldest-first deletion:
   - Delete `tool.jsonl.<rotateMaxFiles - 1>` if present (it would overflow
     the budget once everything shifts up).
   - For `i` from `rotateMaxFiles - 2` down to `1`: if `tool.jsonl.<i>`
     exists, rename it to `tool.jsonl.<i+1>`.
   - Rename the active `tool.jsonl` to `tool.jsonl.1`.
   - Create a fresh, empty `tool.jsonl`.
3. Append a `log.rotated` `LogRecord` (see below) to the fresh active file —
   it is always the new file's first line, a marker for anyone tailing the
   file that a rotation just happened and where the prior content went.

The `log.rotated` record's fields:

| Field | Meaning |
|---|---|
| `file` | The active file's base name (e.g. `earsd.jsonl`), not the rotated-to name — the mirror image of what a `jq` filter selecting `event == "log.rotated"` across multiple tools' logs would key on. |
| `bytes` | Size in bytes of the file *before* this rotation. |
| `rotate_max_bytes` | The threshold that triggered rotation, for context without cross-referencing config. |
| `rotate_max_files` | The retention count in effect at rotation time. |

### Edge cases, by design

- **Rotation check happens before the triggering write, not after.** A
  record is only rotated *ahead of* if the file already has content
  (`currentSize > 0`) and appending would exceed `rotateMaxBytes`. This
  means a single record larger than `rotateMaxBytes` on its own is still
  written whole, immediately after rotating — it is never split, and it does
  not loop rotating forever trying (and failing) to make it fit. The file
  may therefore transiently exceed `rotateMaxBytes` by up to one record's
  size; the alternative (truncating a record) would make the JSON Lines
  file unparseable, which is worse.
- **Size accounting survives a restart.** `FileLogWriter.init` stats the
  existing file (if any) and resumes `currentSize` from its actual on-disk
  size, rather than assuming a fresh process starts a fresh file. A daemon
  restarting mid-file won't over- or under-rotate relative to where it left
  off.
- **Appends are plain `FileHandle` seek-to-end-and-write, not atomic.**
  Per `docs/logging.md`, this isn't the chunk-write atomicity the capture
  daemon spec requires elsewhere — a simple append that never corrupts the
  file is sufficient. Rotation's renames go through
  `FileManager.moveItem`, which is atomic per-operation on the same volume.

## TTY-aware stderr

`LogSink` reads `TTYDetecting.isStderrATTY` once, at construction, and
keeps a plain `Bool` from then on — the real check
(`RealTTYDetector`, wrapping `isatty(STDERR_FILENO)`) is the one piece of
this target that's environment glue rather than logic, and keeping it to a
single read at construction is what lets every other decision in
`LogSink.log(_:)` be exercised in tests against a fixed fake.

- TTY: stderr gets `LogRecordPrettyRenderer.render(record)`; the file still
  gets the full JSON line.
- Not a TTY (piped, under launchd): stderr and the file both get
  `LogRecordJSONEncoder.encode(record)`.

The unified-logging mirror (`UnifiedLogging.log`) is always called,
independent of the TTY check.

## Why the file write can throw but the mirror can't

`LogSink.log(_:)` calls `unified.log(record)` first (best-effort, no
failure mode worth modeling — `os.Logger` has no error return), then
`try await file.append(record)`. A file write failure propagates to the
caller rather than being swallowed, per
`docs/engineering-practices.md`'s "no silent catches" — a tool whose disk
is full should find out, not keep running as if logging were still
working.
