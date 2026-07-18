# Engineering practices

How the code is written is a binding constraint, not a matter of taste. Two rules are mandatory across the whole suite: **test-driven development** and **small, incremental commits**. Both are grounded in what the strongest reference codebases in the survey actually do (see `research/analysis/implementation-patterns.md` §8) and in the failure modes of the ones that skipped them.

## Test-driven development

The default loop for all product code is **red → green → refactor**: write a failing test that names the behaviour, make it pass with the simplest change, then refactor with the test as a safety net. This is enforced, with one pragmatic split by layer.

### The pure-core split makes TDD cheap

Factor all logic with no I/O into a pure Swift package (`EarsCore`-style SPM library): ring-buffer/time-cap math, VAD-index reading and range reconstruction, segment/word-timing merging, SentencePiece token→word reconstruction, streaming-delta emission, frontmatter serialisation, config layering. These are **tier-0** units — deterministic functions tested in isolation with no daemon, no device, no model. This is the single largest maintainability lever available to us; the reference codebases that did it (Hex's `HexCore`, localvoxtral's isolated `StreamingDelta`/`TextMergingAlgorithms`) are the most testable in the corpus.

### Layered test strategy

| Tier | Scope | Rule |
|------|-------|------|
| **0 — pure units** | `EarsCore` logic, no I/O | Strict test-first. No behaviour ships without a failing test first. |
| **1 — integration** | Tools against a **fixture ring buffer** on disk (no daemon running) | Test-first for the contract (given these chunks + index, `transcribe` produces this transcript). Fixtures are the disk-as-API in action. |
| **2 — hardware/model shims** | Core Audio capture, Core ML/ANE inference, process taps | Behaviour-verified, not unit-tested at the syscall. Isolate the shim behind its protocol; test the protocol with a mock, and verify the real shim by driving it end-to-end. |
| **3 — end-to-end** | `capture → transcribe → cleanup → summarize` over real audio fixtures | Smoke-level; asserts the pipeline wires together and outputs are well-formed. |

The thin hardware/model shims (tier 2) are the **only** place test-first is relaxed, because a device IO-proc or an ANE inference can't be meaningfully unit-tested. Everything reachable from a protocol boundary is mocked and tested; the shim behind it is kept as thin as possible precisely so little logic escapes coverage.

### Non-negotiable testing rules (from the corpus)

- **No wall-clock time in tests, anywhere.** Inject clocks; never call `Date()`/`Date.now`/timers in test paths. localvoxtral SIGTRAP'd its own suite by arming a real timer in session code under test — we don't repeat that.
- **Every bug fix ships a regression test, shown failing-then-passing.** A fix without a test that would have caught it is incomplete. ("Proof culture," localvoxtral.)
- **Dependency-inject backends as protocols/closures** so C/dylib/model backends stay unit-testable with mocks (voxt, pindrop, FluidAudio `inout` state).
- **Benchmark-as-CI for the model path.** Accuracy metrics (WER for ASR, DER for diarization, RTFx for speed) are gated in CI against fixtures, so a FluidAudio/Parakeet bump can't silently regress quality (FluidAudio's model-gated Actions).
- **CI runs the tests from commit one.** A suite CI never runs is worthless (Hex, ghost-pepper were docked for exactly this). Wire CI before the daemon loop exists.

## Small, incremental commits

Work proceeds in **small, self-contained commits**, each of which builds, passes the full test suite, and represents one coherent step. A commit that needs a paragraph of caveats, or that mixes a refactor with a behaviour change, is too big — split it.

### Rules

- **One logical change per commit.** A behaviour + its tests together; a refactor separately from the behaviour change it enables.
- **Every commit is green.** Each commit compiles and passes tests on its own — the history is bisectable, and no commit is a known-broken intermediate.
- **Test-first shows in the history.** Because of red→green, a behaviour commit contains its tests. Bug-fix commits contain the regression test alongside the fix.
- **Conventional Commits** for the message: `type(scope): summary` (`feat(earsd): evict chunks past time cap`, `fix(transcribe): pad trailing silence before TDT decode`, `test(core): cover VAD span reconstruction across gaps`, `refactor`, `docs`, `chore`, `ci`). Scope is the tool or package.
- **Commit at every green.** Prefer many small commits over a few large ones; the roadmap phases are milestones, not commit boundaries.
- **No dead or duplicated code in a commit.** Don't commit `*_old`, `_v2` parallel implementations, or unwired capability behind a flag as if shipped — the survey repeatedly couldn't distinguish shipped code from abandoned code (meetily, hyprnote), and that ambiguity is the maintainability tax we most want to avoid. Delete, don't park.

## Repo hygiene and docs discipline

- **Enforce formatting via `.swift-format` + a pre-commit hook** (FluidAudio). Style is not reviewed by humans.
- **Subsystem READMEs live next to the code and record bug history inline** (macparakeet's `Audio/README.md`, `STT/README.md`). Top-level/product docs describe intent; the authoritative record of what a subsystem actually does — and the sharp edges found — sits with the code.
- **Trust code over docs, and keep ours honest.** The most repeated finding in the survey is READMEs that lie about the code. Our `docs/` set describes the design; when code and a doc disagree, that is a bug in one of them to be fixed, not tolerated. Don't let the spec drift.

## Relationship to the roadmap

Every roadmap phase's exit criteria are expressed as tests: a phase is done when its behaviours are covered by green tests at the appropriate tier and CI enforces them. The cross-cutting requirements (logging, `--help`, atomic writes, schema versioning) each get their own coverage rather than being assumed.
