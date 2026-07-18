# Configuration

## Model

Layered, highest wins:

1. **Built-in defaults** — every setting has a sensible default; the suite runs with no config file.
2. **Config file** — TOML at a standard path.
3. **Environment variables** — prefix `EARS_`, nested keys joined by `__`.
4. **CLI flags** — per-invocation overrides.

Example resolution for the data root: default `~/Library/Application Support/ears` → `data_root` in TOML → `EARS_DATA_ROOT` → `--data-root`.

## File location

Resolved in order:

1. `--config <path>` flag.
2. `EARS_CONFIG` env var.
3. `$XDG_CONFIG_HOME/ears/config.toml` if set.
4. `~/.config/ears/config.toml`.

All tools read the same config file. Tool-specific settings live under a `[tools.<name>]` table.

## Reference

```toml
schema = 1

# --- Shared paths ---
data_root   = "~/Library/Application Support/ears"  # ring buffer, sessions, vocab, runtime
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
hard_total_cap_bytes     = 0      # 0 => unlimited backstop; else evict to stay under
chunk_seconds            = 30
codec                    = "aac"  # aac | opus
bitrate                  = 64000
native_sample_rate       = 48000  # listenable chunks/ feed
asr_sample_rate          = 16000  # derived asr/ feed for transcription
store_native             = true   # keep the listenable copy alongside the ASR feed
channels                 = 1

[earsd.vad]
backend      = "silero"   # pluggable; not yet honored -- Phase 1 always uses
                           # the pure energy-threshold EnergyVAD regardless of
                           # this value. A Silero-class model is deferred to a
                           # later phase (see EnergyVAD's doc comment).
speech_pad_ms = 300       # pad around detected speech spans
min_silence_ms = 700      # gap before declaring silence

# Sources enabled at startup. Each may override capture params.
[[earsd.source]]
id    = "mic"
class = "mic"
device_uid = ""           # empty => default input

[[earsd.source]]
id    = "system"
class = "system"
enabled = false           # opt-in: needs system-audio permission

[[earsd.source]]
id    = "app:us.zoom.xos"
class = "app"
label = "Zoom"
time_cap_seconds = 14400  # keep meetings longer

# --- Auto-triggers ---
[triggers]
enabled = true

[[triggers.rule]]
name = "meetings"
on   = "app-audio-active"           # fires while an app is producing/consuming audio
apps = ["us.zoom.xos", "com.microsoft.teams2", "Google Chrome"]
open_session = true
sources = ["mic", "app:us.zoom.xos"]
on_close = ["transcribe", "cleanup", "summarize"]   # pipeline to run when the session closes

# --- Transcription ---
[transcribe]
model        = "parakeet"
backend      = "fluidaudio"   # native ANE/Metal; or "subprocess"
compute      = "ane"          # ane | gpu | cpu
diarize      = true
diarize_backend = "pyannote"
skip_silence = true           # use the VAD index to skip silence spans

# --- LLM stages ---
[llm]
backend = "llm-cli"           # llm-cli | (future) anthropic-sdk | command
model   = "claude-sonnet-5"   # passed to `llm -m`
# For backend = "command", a shell template taking prompt on stdin, completion on stdout:
# command = "llm -m claude-sonnet-5"

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

## Conventions

- **Paths** support `~` expansion and are resolved relative to `data_root` when not absolute (except `data_root`/`output_root` themselves).
- **Zero-config:** with no file present, the daemon captures `mic` with the defaults above; transcription uses Parakeet on the ANE; LLM stages use the `llm` CLI with its default model.
- **Validation:** each tool validates its config at startup and exits non-zero with a precise message (key path + reason) on any unknown key or invalid value. No silent fallback.
- **Discovery:** every tool supports `--print-config` (resolved, merged config as TOML) and `--config-path` (which file was loaded), for debugging the layering.
