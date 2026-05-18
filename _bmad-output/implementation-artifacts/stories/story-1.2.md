# Story 1.2: Define cactus_c.h FFI surface (widened for accuracy pipeline)

**Epic:** 1 — Project Foundation & FFI Seam
**Status:** done
**Owner:** story-executor-1.2

## User Story

As the **runtime engineer**,
I want **a single `extern "C"` header that exposes only the cactus operations CactusVoice needs**,
So that **the Swift compile graph never sees C++ headers and the ABI seam is captured in one file**.

## Acceptance Criteria

1. `CactusCore/include/cactus_c.h` exposes exactly the required functions:
   - `cactus_runtime_init` / `cactus_runtime_shutdown`
   - `cactus_load_model(path, type, out_handle)` / `cactus_free_model(handle)`
   - `cactus_whisper_create_session(model, opts, out_session)` / `cactus_whisper_push_pcm(session, samples, count)` / `cactus_whisper_pull_partial(session, out_topk, out_logprobs)` / `cactus_whisper_close_session`
   - `cactus_llm_run(model, prompt, max_tokens, out_text)`
   - `cactus_onnx_run(model, input, out_output)` (used by Silero VAD)
2. Whisper-session opts struct accepts: `language` (utf8), `condition_on_previous_text` (bool), `temperature_fallback` (float* + length), `no_repeat_ngram_size` (uint8), `logprob_threshold` (float), `compression_ratio_threshold` (float), and `initial_prompt` (utf8, nullable).
3. `pull_partial` returns top-K hypotheses (K default 5, configurable) with per-token logprobs + aggregate confidence.
4. Every function returns `cactus_status_t` and writes outputs through out-parameters; no exceptions cross the seam.
5. Ownership and threading conventions are documented in 2–4 lines of C comments per function.
6. `module.modulemap` exposes `cactus_c.h`; `import CactusCore` works from Swift.
7. `FFIShim.swift` in `CactusCore` mirrors the C surface as pure marshaling Swift functions — no policy, no caching, no logging.
8. Zero C++ types visible above the static-library boundary.

## Tasks

- [x] T1 — Author `apps/CactusVoice/CactusCore/include/cactus_c.h` with the exact symbol set.
- [x] T2 — Update `apps/CactusVoice/CactusCore/module.modulemap` to expose `cactus_c.h` (additionally to the existing `CactusCore.h`).
- [x] T3 — Author `apps/CactusVoice/CactusCore/Sources/FFIShim.swift` mirroring the C surface 1-1 as pure marshaling.
- [x] T4 — Author `apps/CactusVoice/CactusCore/Sources/FFIStub.c` returning `cactus_status_err_unimplemented` for every entry point so the static lib links.
- [x] T5 — Write Story 1.2 acceptance tests (red), grep + clang-syntax checks.
- [x] T6 — Run `clang -fsyntax-only -Wall -Wpedantic -std=c11` on the header.
- [x] T7 — Regenerate xcodeproj via XcodeGen.

## Dev Notes

- Architecture refs: `architecture.md §B` (Cactus Interop, two-layer seam: thin FFI shim with zero policy + thick `CactusRuntime`); `§G` (no exceptions across the seam → `cactus_status_t`).
- Real cactus C++ runtime is **not** linked into this target yet; `FFIStub.c` is a placeholder so the static library links. Implementations return `cactus_status_err_unimplemented` and are marked with `// TODO(real-cactus): wire to libcactus`.
- The header is flat C11 (no clever macros, no nested unions). Opaque handles are forward-declared `struct` typedefs.
- The Swift `FFIShim` is *not* an actor and *not* `Sendable`. It is a struct of free functions that import the C symbols. Policy (threading, caching, lifetime) lives in `CactusRuntime` in a later story.
- The existing umbrella header `CactusCore.h` stays in place so prior tests that look for it still pass. The modulemap now exposes both via `header` directives.
- The accuracy-pipeline widening (top-K, logprobs, decoding flags) is baked in now because re-cutting the ABI later would be expensive.

## Validation

| AC | Covered by |
|----|------------|
| 1 (symbol set) | `Story1_2Tests.testHeaderDeclaresRequiredSymbols` |
| 2 (whisper opts) | `Story1_2Tests.testWhisperOptsStructFields` |
| 3 (top-K + logprobs) | `Story1_2Tests.testPullPartialTopKLogprobs` |
| 4 (status_t + out-params) | `Story1_2Tests.testAllFunctionsReturnStatus` |
| 5 (per-function docs) | `Story1_2Tests.testEveryFunctionHasDocComment` |
| 6 (modulemap exposure) | `Story1_2Tests.testModuleMapExposesCactusC` |
| 7 (FFIShim mirrors C) | `Story1_2Tests.testFFIShimMirrorsCSurface` |
| 8 (no C++ types) | `Story1_2Tests.testNoCxxTypesInHeader` + clang -std=c11 -fsyntax-only |

## Change Log

- 2026-05-18 — Initial story file authored by story-executor-1.2.
