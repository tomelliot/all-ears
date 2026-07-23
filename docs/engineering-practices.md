# Engineering practices

Two rules are mandatory across the suite: **test-driven development** and **small, incremental commits**.

## Test-driven development

The default loop for all product code is red → green → refactor: write a failing test that names the behaviour, make it pass with the simplest change, refactor with the test as a safety net.

### The pure-core split makes TDD cheap

All logic with no I/O lives in the pure `EarsCore` library: VAD-index reading and range reconstruction, segment merging, streaming-delta emission, frontmatter serialisation, config layering. These are deterministic functions tested in isolation — no daemon, no device, no model. This is the single largest maintainability lever in the codebase.

### Layered test strategy

| Tier | Scope | Rule |
|------|-------|------|
| **0 — pure units** | `EarsCore` logic, no I/O | Strict test-first. No behaviour ships without a failing test first. |
| **1 — integration** | Tools against a **fixture audio store** on disk, no daemon running | Test-first for the contract: given these chunks + index, `transcribe` produces this transcript. |
| **2 — hardware/model shims** | Core Audio capture, Core ML/ANE inference, process taps | The only place test-first is relaxed — a device IO-proc can't be meaningfully unit-tested. Test the protocol with a mock; keep the real shim thin and verify it end-to-end (some tap tests are opt-in and need real hardware + permission). |
| **3 — end-to-end** | `capture → transcribe → cleanup → summarize` over real audio fixtures | Smoke-level; asserts the pipeline wires together and outputs are well-formed. |

### Non-negotiable testing rules

- **No wall-clock time in tests.** Inject clocks; never call `Date()`/timers in test paths.
- **Every bug fix ships a regression test**, shown failing-then-passing. A fix without a test that would have caught it is incomplete.
- **Dependency-inject backends as protocols** so hardware/model backends stay unit-testable with mocks.
- **CI runs the suite on every commit** (`.github/workflows/ci.yml`: `swift format lint --strict`, build, full tests). Model-accuracy benchmarks (WER for ASR, DER for diarization) should gate model-path changes the same way; they are not wired into CI yet.
- Claims no automated test can establish (multi-day memory flatness, real sleep/wake) get a manual runbook instead — see [operations](./operations/capture-soak-runbook.md) — and are never described as automated.

## Small, incremental commits

Work proceeds in small, self-contained commits, each of which builds, passes the full test suite, and represents one coherent step.

- **One logical change per commit.** A behaviour with its tests together; a refactor separate from the behaviour change it enables.
- **Every commit is green** — the history is bisectable.
- **Conventional Commits:** `type(scope): summary` (`feat(earsd): evict chunks past time cap`, `fix(transcribe): pad trailing silence before TDT decode`). Scope is the tool or package.
- **Commit at every green.** Many small commits beat a few large ones.
- **No dead or duplicated code in a commit.** No `_old`/`_v2` parallel implementations, no unwired capability presented as shipped. Delete, don't park.

## Docs discipline

- Formatting is enforced by `.swift-format` in CI; style is not reviewed by humans.
- `docs/` describes design and contracts; doc comments next to the code record what a subsystem actually does and the sharp edges found.
- **Trust code over docs, and keep the docs honest.** When code and a doc disagree, that is a bug in one of them to be fixed, not tolerated.
