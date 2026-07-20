# Configuration

## Model

Layered, highest wins:

1. **Built-in defaults** — every setting has one; the suite runs with no config file.
2. **Config file** — TOML at a standard path.
3. **Environment variables** — prefix `EARS_`, nested keys joined by `__` (e.g. `EARS_LOG__LEVEL`).
4. **CLI flags** — per-invocation overrides.

Example for the data root: default `~/Library/Application Support/ears` → `data_root` in TOML → `EARS_DATA_ROOT` → `--data-root`.

## File location

Resolved in order:

1. `--config <path>` flag.
2. `EARS_CONFIG` env var.
3. `$XDG_CONFIG_HOME/ears/config.toml` if set.
4. `~/.config/ears/config.toml`.

All tools read the same file. Tool-specific settings live in their own tables.

## Reference

```toml
schema = 1

# --- Shared paths ---
data_root   = "~/Library/Application Support/ears"  # ring buffer, sessions, meetings, vocab, runtime
output_root = "~/Documents/Transcripts"             # transcripts, summaries
socket_path = ""   # empty => <data_root>/runtime/earsd.sock

# --- Logging (see logging.md) ---
[log]
level     = "info"        # debug | info | notice | error
file      = ""            # JSON Lines sink (primary); empty => <data_root>/logs/<tool>.jsonl
format    = "auto"        # auto | json | pretty  (auto: pretty on a TTY, json otherwise)
oslog     = true          # also mirror events into Apple unified logging
subsystem = "net.tomelliot.ears"
rotate_max_bytes = 52428800   # rotate the JSON log at ~50MB
rotate_max_files = 5

# --- Capture daemon ---
[earsd]
default_time_cap_seconds = 7200   # 2h ring-buffer window per source
hard_total_cap_bytes     = 0      # 0 => unlimited; else evict oldest across sources to stay under
chunk_seconds            = 30
codec                    = "aac"  # aac | opus
bitrate                  = 64000
native_sample_rate       = 48000  # listenable chunks/ feed
asr_sample_rate          = 16000  # derived asr/ feed for transcription
store_native             = true   # keep the listenable copy alongside the ASR feed
channels                 = 1

[earsd.vad]
backend        = "energy"  # currently ignored: an energy-threshold VAD is always used
speech_pad_ms  = 300       # pad around detected speech spans
min_silence_ms = 700       # gap before declaring silence

[earsd.meetings]
# How long a browser meeting's last ingest stream may stay closed before the
# daemon ends the meeting on its own (events.jsonl reason "ingest-idle").
# Manual meetings are never auto-ended.
ingest_close_grace_s = 120
# Locally-captured sources folded into every browser meeting, so your own side
# is transcribed alongside the extension's per-participant streams. Each id is
# included only if the daemon is actually capturing it. Set to [] to disable.
local_sources = ["mic"]

# Audio ingestion from the browser extension (binary PCM). Off by default.
[earsd.ingest_ws]
enabled         = false
port            = 47811   # loopback only
allowed_origins = []      # e.g. ["chrome-extension://<id>", "moz-extension://<uuid>"];
                          # empty rejects every connection (fail closed)

# Control plane for the browser extension (sessions, meetings, status). Off by default.
[earsd.control_ws]
enabled         = false
port            = 47812   # loopback only
allowed_origins = []      # same fail-closed allowlist as ingest_ws

# Sources enabled at startup. Each may override capture params.
[[earsd.source]]
id    = "mic"
class = "mic"
device_uid = ""           # empty => default input

[[earsd.source]]
id    = "system"
class = "system"
enabled = false           # opt-in: needs the system-audio-recording permission

[[earsd.source]]
id    = "app:us.zoom.xos"
class = "app"
label = "Zoom"
time_cap_seconds = 14400  # keep meetings longer

# --- Auto-triggers ---
[triggers]
enabled = true
transcribe_on_browser_session_close = true  # transcribe when a browser meeting ends (default: true; set false to disable)

[[triggers.rule]]
name = "meetings"
on   = "app-audio-active"           # fires on genuine audio activity (the matched app's
                                    # own source VAD going speech), not app launch
apps = ["us.zoom.xos", "com.microsoft.teams2"]      # exact bundle ids
open_session = true
sources = ["mic", "app:us.zoom.xos"]
on_close = ["transcribe", "cleanup", "summarize"]   # pipeline to run when the session closes
pre_roll_seconds = 15               # widen transcribe's read range backward by this many
                                    # seconds of already-buffered audio

# --- LLM stages ---
[llm]
backend = "llm-cli"           # llm-cli | command — both run a subprocess:
model   = "claude-sonnet-5"   #   llm-cli runs `llm -m <model>`; command runs the line below
# command = "my-llm-wrapper --fast"   # prompt on stdin, completion on stdout

[cleanup]
prompt_file = ""              # empty => built-in cleanup prompt
use_vocab   = true

[[summarize.preset]]
name = "brief"
prompt_file = "prompts/brief.md"
[[summarize.preset]]
name = "actions"
prompt_file = "prompts/action-items.md"

# --- Vocabulary ---
[vocab]
global = "vocab/global.txt"   # relative to data_root
```

Transcription itself has no config table yet: `transcribe` always uses Parakeet via FluidAudio on the Apple Neural Engine, with VAD silence-skipping on. Model, backend, and diarization settings will get a `[transcribe]` table when there is more than one choice to make.

## Conventions

- **Paths** support `~` expansion and resolve relative to `data_root` when not absolute (except `data_root`/`output_root` themselves).
- **Zero-config:** with no file present, the daemon captures `mic` with the defaults above and the LLM stages use the `llm` CLI.
- **Validation:** each tool validates its config at startup and exits non-zero with a precise message (key path + reason) on any unknown key or invalid value. No silent fallback.
- **Discovery:** every tool prints the resolved, merged config and reports which file was loaded. The single-purpose tools spell it `--print-config` / `--config-path`; `ears` spells it `ears config show` / `ears config path`.
