// FFIShim.swift — pure Swift marshaling over the cactus_c.h surface.
//
// This file is the THIN layer of the two-layer cactus interop seam
// (architecture.md §B). It mirrors `cactus_c.h` 1-1 as free functions on an
// enum-namespace. It has:
//
//   - no policy
//   - no caching
//   - no logging
//   - no actor isolation
//   - no error mapping beyond surfacing the raw cactus_status_t
//
// Policy (lifetime, threading, residency, error mapping to AppError) lives
// one layer up in `CactusRuntime` (Story 3.1). Keeping this file dumb is the
// whole point of the seam.

import Foundation
#if canImport(CactusCore)
import CactusCore
#endif

/// Strongly-typed wrapper over `cactus_status_t`. Identity-only — the policy
/// layer maps these to `AppError` cases.
public struct CactusStatus: Equatable, Sendable {
    public let raw: Int32
    public init(_ raw: Int32) { self.raw = raw }
    public var isOK: Bool { raw == 0 }
}

/// Namespace for the pure-marshaling FFI entry points. Not an actor, not
/// `Sendable`-isolated — callers pin their own isolation domain.
public enum FFIShim {

    // MARK: Runtime lifecycle

    /// 1-1 with `cactus_runtime_init`.
    public static func runtimeInit() -> CactusStatus {
        #if canImport(CactusCore)
        return CactusStatus(cactus_runtime_init())
        #else
        return CactusStatus(3) // unimplemented
        #endif
    }

    /// 1-1 with `cactus_runtime_shutdown`.
    public static func runtimeShutdown() -> CactusStatus {
        #if canImport(CactusCore)
        return CactusStatus(cactus_runtime_shutdown())
        #else
        return CactusStatus(3)
        #endif
    }

    // MARK: Model loader

    public enum ModelType: Int32, Sendable {
        case whisper = 1
        case llm     = 2
        case onnx    = 3
    }

    /// 1-1 with `cactus_load_model`. Returns the opaque handle as an
    /// `OpaquePointer?` so no C++ type ever escapes Swift.
    public static func loadModel(path: String,
                                 type: ModelType) -> (CactusStatus, OpaquePointer?) {
        #if canImport(CactusCore)
        var handle: cactus_model_handle_t?
        let status = path.withCString { cstr in
            cactus_load_model(cstr, type.rawValue, &handle)
        }
        return (CactusStatus(status), OpaquePointer(handle))
        #else
        _ = path; _ = type
        return (CactusStatus(3), nil)
        #endif
    }

    /// 1-1 with `cactus_free_model`.
    public static func freeModel(_ handle: OpaquePointer?) -> CactusStatus {
        #if canImport(CactusCore)
        let h = cactus_model_handle_t(handle)
        return CactusStatus(cactus_free_model(h))
        #else
        _ = handle
        return CactusStatus(3)
        #endif
    }

    // MARK: Whisper session

    /// Plain Swift mirror of `cactus_whisper_opts_t`. Pure value type;
    /// `bridge(_:)` materializes the C struct only at call time.
    public struct WhisperOpts: Sendable {
        public var language: String?
        public var conditionOnPreviousText: Bool
        public var temperatureFallback: [Float]
        public var noRepeatNgramSize: UInt8
        public var logprobThreshold: Float
        public var compressionRatioThreshold: Float
        public var initialPrompt: String?

        public init(language: String? = nil,
                    conditionOnPreviousText: Bool = false,
                    temperatureFallback: [Float] = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0],
                    noRepeatNgramSize: UInt8 = 0,
                    logprobThreshold: Float = -1.0,
                    compressionRatioThreshold: Float = 2.4,
                    initialPrompt: String? = nil) {
            self.language = language
            self.conditionOnPreviousText = conditionOnPreviousText
            self.temperatureFallback = temperatureFallback
            self.noRepeatNgramSize = noRepeatNgramSize
            self.logprobThreshold = logprobThreshold
            self.compressionRatioThreshold = compressionRatioThreshold
            self.initialPrompt = initialPrompt
        }
    }

    /// Plain Swift mirror of one `cactus_whisper_hypothesis_t`.
    public struct WhisperHypothesis: Sendable {
        public let text: String
        public let tokenLogprobs: [Float]
        public let aggregateConfidence: Float
    }

    /// 1-1 with `cactus_whisper_create_session`.
    public static func whisperCreateSession(model: OpaquePointer?,
                                            opts: WhisperOpts,
                                            topK: UInt32 = 5)
        -> (CactusStatus, OpaquePointer?)
    {
        #if canImport(CactusCore)
        var session: cactus_whisper_session_t?
        let status = opts.language.withOptionalCString { langPtr in
            opts.initialPrompt.withOptionalCString { promptPtr in
                opts.temperatureFallback.withUnsafeBufferPointer { tempBuf in
                    var c = cactus_whisper_opts_t(
                        language: langPtr,
                        condition_on_previous_text: opts.conditionOnPreviousText,
                        temperature_fallback: tempBuf.baseAddress,
                        temperature_fallback_len: tempBuf.count,
                        no_repeat_ngram_size: opts.noRepeatNgramSize,
                        logprob_threshold: opts.logprobThreshold,
                        compression_ratio_threshold: opts.compressionRatioThreshold,
                        initial_prompt: promptPtr
                    )
                    return cactus_whisper_create_session(
                        cactus_model_handle_t(model),
                        &c,
                        topK,
                        &session
                    )
                }
            }
        }
        return (CactusStatus(status), OpaquePointer(session))
        #else
        _ = (model, opts, topK)
        return (CactusStatus(3), nil)
        #endif
    }

    /// 1-1 with `cactus_whisper_push_pcm`.
    public static func whisperPushPCM(session: OpaquePointer?,
                                      samples: UnsafePointer<Float>,
                                      count: Int) -> CactusStatus {
        #if canImport(CactusCore)
        return CactusStatus(cactus_whisper_push_pcm(
            cactus_whisper_session_t(session),
            samples,
            count
        ))
        #else
        _ = (session, samples, count)
        return CactusStatus(3)
        #endif
    }

    /// 1-1 with `cactus_whisper_pull_partial`. Marshals the runtime-owned
    /// top-K buffer into Swift value types; the C pointers are NOT retained.
    public static func whisperPullPartial(session: OpaquePointer?)
        -> (CactusStatus, [WhisperHypothesis])
    {
        #if canImport(CactusCore)
        var topk = cactus_whisper_topk_t(count: 0, hypotheses: nil)
        let status = cactus_whisper_pull_partial(
            cactus_whisper_session_t(session),
            &topk
        )
        var out: [WhisperHypothesis] = []
        if status == 0, let base = topk.hypotheses {
            for i in 0..<Int(topk.count) {
                let h = base[i]
                let text = h.text.map { String(cString: $0) } ?? ""
                var logprobs: [Float] = []
                if let lp = h.token_logprobs {
                    logprobs = Array(UnsafeBufferPointer(
                        start: lp, count: Int(h.token_logprobs_len)
                    ))
                }
                out.append(WhisperHypothesis(
                    text: text,
                    tokenLogprobs: logprobs,
                    aggregateConfidence: h.aggregate_confidence
                ))
            }
        }
        return (CactusStatus(status), out)
        #else
        _ = session
        return (CactusStatus(3), [])
        #endif
    }

    /// 1-1 with `cactus_whisper_close_session`.
    public static func whisperCloseSession(_ session: OpaquePointer?) -> CactusStatus {
        #if canImport(CactusCore)
        return CactusStatus(cactus_whisper_close_session(
            cactus_whisper_session_t(session)
        ))
        #else
        _ = session
        return CactusStatus(3)
        #endif
    }

    // MARK: LLM one-shot

    /// 1-1 with `cactus_llm_run`. Marshals the runtime-owned UTF-8 result
    /// into a Swift `String` value (caller owns the copy).
    public static func llmRun(model: OpaquePointer?,
                              prompt: String,
                              maxTokens: UInt32) -> (CactusStatus, String) {
        #if canImport(CactusCore)
        var out: UnsafePointer<CChar>?
        let status = prompt.withCString { p in
            cactus_llm_run(cactus_model_handle_t(model), p, maxTokens, &out)
        }
        let text = out.map { String(cString: $0) } ?? ""
        return (CactusStatus(status), text)
        #else
        _ = (model, prompt, maxTokens)
        return (CactusStatus(3), "")
        #endif
    }

    // MARK: ONNX one-shot

    /// 1-1 with `cactus_onnx_run`. Marshals the runtime-owned float output
    /// into a Swift `[Float]` value (caller owns the copy).
    public static func onnxRun(model: OpaquePointer?,
                               input: [Float]) -> (CactusStatus, [Float]) {
        #if canImport(CactusCore)
        var outPtr: UnsafePointer<Float>?
        var outLen: Int = 0
        let status = input.withUnsafeBufferPointer { inBuf in
            cactus_onnx_run(
                cactus_model_handle_t(model),
                inBuf.baseAddress,
                inBuf.count,
                &outPtr,
                &outLen
            )
        }
        var out: [Float] = []
        if status == 0, let p = outPtr {
            out = Array(UnsafeBufferPointer(start: p, count: outLen))
        }
        return (CactusStatus(status), out)
        #else
        _ = (model, input)
        return (CactusStatus(3), [])
        #endif
    }
}

// MARK: - Optional<String> cstring helper

private extension Optional where Wrapped == String {
    /// Calls `body` with a `const char *` view of the string, or `nil` if the
    /// optional is `nil`. Lifetime is bounded by `body`.
    func withOptionalCString<R>(_ body: (UnsafePointer<CChar>?) throws -> R) rethrows -> R {
        switch self {
        case .none:
            return try body(nil)
        case .some(let s):
            return try s.withCString { try body($0) }
        }
    }
}
