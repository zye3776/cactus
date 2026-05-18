/* cactus_c.h — CactusVoice FFI surface to the cactus C++ runtime.
 *
 * This is the SINGLE seam between Swift and cactus C++. Every entry point is
 * `extern "C"`, returns `cactus_status_t`, writes outputs through out-params,
 * and lets NO C++ types leak above the static-library boundary.
 *
 * Architecture refs: architecture.md §B (Cactus Interop & Concurrency Model).
 * The widened surface (top-K hypotheses, per-token logprobs, decoding flags,
 * initial_prompt, ONNX for Silero VAD) is intentional and based on the
 * 2026-05-18 ASR research note in the architecture doc.
 */

#ifndef CACTUS_C_H
#define CACTUS_C_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
 * Status codes
 * -------------------------------------------------------------------------*/

/* Status returned by every cactus_c entry point. 0 == OK. Stable ABI.
 * New error codes append to the end; values never reused or reordered. */
typedef int32_t cactus_status_t;

#define cactus_status_ok                  ((cactus_status_t)0)
#define cactus_status_err_unknown         ((cactus_status_t)1)
#define cactus_status_err_invalid_arg     ((cactus_status_t)2)
#define cactus_status_err_unimplemented   ((cactus_status_t)3)
#define cactus_status_err_model_load      ((cactus_status_t)4)
#define cactus_status_err_inference       ((cactus_status_t)5)
#define cactus_status_err_session_closed  ((cactus_status_t)6)

/* ---------------------------------------------------------------------------
 * Opaque handles
 * -------------------------------------------------------------------------*/

/* Opaque model handle. Created by cactus_load_model, freed by
 * cactus_free_model. Threading: any thread may use a handle, but the caller
 * must serialize calls that mutate the same handle's session state. */
typedef struct cactus_model_s* cactus_model_handle_t;

/* Opaque whisper streaming session. One session per logical capture window.
 * Threading: a session is bound to its creating thread/actor — push_pcm and
 * pull_partial must be called from the same isolation domain. */
typedef struct cactus_whisper_session_s* cactus_whisper_session_t;

/* ---------------------------------------------------------------------------
 * Model loader
 * -------------------------------------------------------------------------*/

/* Model kind discriminator passed to cactus_load_model. Stable ABI. */
typedef int32_t cactus_model_type_t;
#define cactus_model_type_whisper  ((cactus_model_type_t)1)
#define cactus_model_type_llm      ((cactus_model_type_t)2)
#define cactus_model_type_onnx     ((cactus_model_type_t)3)

/* Initialize the cactus runtime once per process. Idempotent.
 * Ownership: no resources transferred. Threading: must be called before
 * any other entry point; safe to call from any thread; not reentrant. */
cactus_status_t cactus_runtime_init(void);

/* Tear down the cactus runtime. After this returns, no other entry point
 * may be called until cactus_runtime_init is invoked again.
 * Ownership: caller must have freed all model handles first.
 * Threading: not reentrant; must be the last call. */
cactus_status_t cactus_runtime_shutdown(void);

/* Load a model file from disk into a new opaque handle.
 * Ownership: on success, `*out_handle` is owned by the caller and must be
 * freed with cactus_free_model. On failure, `*out_handle` is set to NULL.
 * Threading: blocking; safe to call from any thread; not cancellable. */
cactus_status_t cactus_load_model(const char* path,
                                  cactus_model_type_t type,
                                  cactus_model_handle_t* out_handle);

/* Free a model handle previously returned by cactus_load_model. Passing NULL
 * is a no-op and returns cactus_status_ok.
 * Ownership: invalidates `handle` for the caller.
 * Threading: caller must guarantee no in-flight session uses the handle. */
cactus_status_t cactus_free_model(cactus_model_handle_t handle);

/* ---------------------------------------------------------------------------
 * Whisper streaming session
 * -------------------------------------------------------------------------*/

/* Per-session decoding options. All fields are owned by the caller for the
 * duration of cactus_whisper_create_session; the implementation must copy
 * any data it needs. Strings are NUL-terminated UTF-8. */
typedef struct cactus_whisper_opts_s {
    /* BCP-47 / ISO-639-1 language tag, e.g. "en". May be NULL for auto. */
    const char* language;

    /* Whisper "condition_on_previous_text" flag. True replays committed text
     * as prefix; false resets per segment. */
    bool condition_on_previous_text;

    /* Temperature fallback ladder, e.g. {0.0, 0.2, 0.4, 0.6, 0.8, 1.0}.
     * `temperature_fallback` may be NULL iff `temperature_fallback_len == 0`. */
    const float* temperature_fallback;
    size_t       temperature_fallback_len;

    /* Suppress n-gram repetitions of this size. 0 disables. */
    uint8_t no_repeat_ngram_size;

    /* Reject hypotheses whose mean per-token logprob falls below this. */
    float logprob_threshold;

    /* Reject hypotheses whose gzip compression ratio exceeds this (drift /
     * looping detector). */
    float compression_ratio_threshold;

    /* Optional UTF-8 initial prompt biasing decoding (proper nouns, terms).
     * May be NULL. */
    const char* initial_prompt;
} cactus_whisper_opts_t;

/* One n-best hypothesis returned by cactus_whisper_pull_partial.
 * Ownership: `text` and `token_logprobs` are owned by the cactus runtime and
 * remain valid only until the next pull_partial / close_session call on
 * this session. The caller must copy out anything it intends to keep. */
typedef struct cactus_whisper_hypothesis_s {
    /* NUL-terminated UTF-8 transcription text. */
    const char* text;

    /* Per-token logprobs aligned with the decoded tokens of `text`. */
    const float* token_logprobs;
    size_t       token_logprobs_len;

    /* Aggregate confidence in [0.0, 1.0] (typically mean exp(logprob)). */
    float aggregate_confidence;
} cactus_whisper_hypothesis_t;

/* Result struct for cactus_whisper_pull_partial. Ownership matches the
 * embedded hypotheses: valid only until the next pull/close call. The
 * caller-owned `hypotheses` array is allocated by the runtime and remains
 * valid for the same window. */
typedef struct cactus_whisper_topk_s {
    /* Number of valid hypotheses in `hypotheses` (<= capacity, <= K). */
    size_t count;

    /* Pointer to `count` hypotheses, top-1 first, descending by score. */
    const cactus_whisper_hypothesis_t* hypotheses;
} cactus_whisper_topk_t;

/* Create a new streaming whisper session bound to the given model.
 * Top-K width is supplied via `top_k` (default callers should pass 5).
 * Ownership: on success `*out_session` is owned by the caller and must be
 * closed with cactus_whisper_close_session.
 * Threading: not thread-safe; bind the returned session to one actor. */
cactus_status_t cactus_whisper_create_session(cactus_model_handle_t model,
                                              const cactus_whisper_opts_t* opts,
                                              uint32_t top_k,
                                              cactus_whisper_session_t* out_session);

/* Push 16 kHz mono float PCM samples into the session's stream.
 * Ownership: samples are read during the call; the caller retains the buffer.
 * Threading: must be called from the session's owning isolation domain. */
cactus_status_t cactus_whisper_push_pcm(cactus_whisper_session_t session,
                                        const float* samples,
                                        size_t count);

/* Pull the latest top-K partial hypotheses with per-token logprobs.
 * Ownership: the returned `out_topk` (and everything it points at) is owned
 * by the runtime and valid only until the next pull_partial or close call.
 * Threading: must be called from the session's owning isolation domain. */
cactus_status_t cactus_whisper_pull_partial(cactus_whisper_session_t session,
                                            cactus_whisper_topk_t* out_topk);

/* Close a whisper session and free its resources. Passing NULL is a no-op.
 * Ownership: invalidates `session` and any previously returned pointers.
 * Threading: must be called from the session's owning isolation domain. */
cactus_status_t cactus_whisper_close_session(cactus_whisper_session_t session);

/* ---------------------------------------------------------------------------
 * LLM one-shot
 * -------------------------------------------------------------------------*/

/* Run a one-shot LLM generation. Used by the rewrite + correction pipelines.
 * Ownership: on success `*out_text` points at a NUL-terminated UTF-8 string
 * owned by the runtime; the caller must release it via cactus_free_string
 * (cactus_free_model handles its own kind; strings get a dedicated call
 * once cactus_runtime_shutdown is not yet invoked). For the v1 stub the
 * string lifetime is implementation-defined and callers should copy out.
 * Threading: blocking; safe from any thread; one call per model at a time. */
cactus_status_t cactus_llm_run(cactus_model_handle_t model,
                               const char* prompt,
                               uint32_t max_tokens,
                               const char** out_text);

/* ---------------------------------------------------------------------------
 * ONNX one-shot (Silero VAD)
 * -------------------------------------------------------------------------*/

/* Run a one-shot ONNX inference. Input/output are flat float buffers; shape
 * is implied by the loaded model (Silero VAD is a single 1xN -> 1x1 op).
 * Ownership: `input` is read during the call; `*out_output` points to a
 * runtime-owned buffer valid until the next onnx_run / free_model call.
 * Threading: blocking; safe from any thread; one call per model at a time. */
cactus_status_t cactus_onnx_run(cactus_model_handle_t model,
                                const float* input,
                                size_t input_len,
                                const float** out_output,
                                size_t* out_output_len);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* CACTUS_C_H */
