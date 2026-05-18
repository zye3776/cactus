/* FFIStub.c — weak stub implementations of the cactus_c.h surface.
 *
 * The real cactus C++ runtime is NOT yet linked into this Swift target.
 * Until Story 3.1 wires it, every entry point returns
 * `cactus_status_err_unimplemented` so the static library still links and
 * the FFI seam is end-to-end testable for shape (not behavior).
 *
 * TODO(real-cactus): wire to libcactus.
 */

#include "cactus_c.h"

cactus_status_t cactus_runtime_init(void) {
    /* TODO(real-cactus): wire to libcactus. */
    return cactus_status_err_unimplemented;
}

cactus_status_t cactus_runtime_shutdown(void) {
    /* TODO(real-cactus): wire to libcactus. */
    return cactus_status_err_unimplemented;
}

cactus_status_t cactus_load_model(const char* path,
                                  cactus_model_type_t type,
                                  cactus_model_handle_t* out_handle) {
    (void)path;
    (void)type;
    if (out_handle != NULL) {
        *out_handle = NULL;
    }
    /* TODO(real-cactus): wire to libcactus. */
    return cactus_status_err_unimplemented;
}

cactus_status_t cactus_free_model(cactus_model_handle_t handle) {
    (void)handle;
    /* TODO(real-cactus): wire to libcactus. */
    return cactus_status_ok;
}

cactus_status_t cactus_whisper_create_session(cactus_model_handle_t model,
                                              const cactus_whisper_opts_t* opts,
                                              uint32_t top_k,
                                              cactus_whisper_session_t* out_session) {
    (void)model;
    (void)opts;
    (void)top_k;
    if (out_session != NULL) {
        *out_session = NULL;
    }
    /* TODO(real-cactus): wire to libcactus. */
    return cactus_status_err_unimplemented;
}

cactus_status_t cactus_whisper_push_pcm(cactus_whisper_session_t session,
                                        const float* samples,
                                        size_t count) {
    (void)session;
    (void)samples;
    (void)count;
    /* TODO(real-cactus): wire to libcactus. */
    return cactus_status_err_unimplemented;
}

cactus_status_t cactus_whisper_pull_partial(cactus_whisper_session_t session,
                                            cactus_whisper_topk_t* out_topk) {
    (void)session;
    if (out_topk != NULL) {
        out_topk->count = 0;
        out_topk->hypotheses = NULL;
    }
    /* TODO(real-cactus): wire to libcactus. */
    return cactus_status_err_unimplemented;
}

cactus_status_t cactus_whisper_close_session(cactus_whisper_session_t session) {
    (void)session;
    /* TODO(real-cactus): wire to libcactus. */
    return cactus_status_ok;
}

cactus_status_t cactus_llm_run(cactus_model_handle_t model,
                               const char* prompt,
                               uint32_t max_tokens,
                               const char** out_text) {
    (void)model;
    (void)prompt;
    (void)max_tokens;
    if (out_text != NULL) {
        *out_text = NULL;
    }
    /* TODO(real-cactus): wire to libcactus. */
    return cactus_status_err_unimplemented;
}

cactus_status_t cactus_onnx_run(cactus_model_handle_t model,
                                const float* input,
                                size_t input_len,
                                const float** out_output,
                                size_t* out_output_len) {
    (void)model;
    (void)input;
    (void)input_len;
    if (out_output != NULL) {
        *out_output = NULL;
    }
    if (out_output_len != NULL) {
        *out_output_len = 0;
    }
    /* TODO(real-cactus): wire to libcactus. */
    return cactus_status_err_unimplemented;
}
