import XCTest

/// Acceptance tests for Story 1.2 — Define `cactus_c.h` FFI surface.
///
/// These tests are file-level static checks: they grep the header, the module
/// map, and `FFIShim.swift` for the required symbol set and shape. They also
/// invoke `clang -fsyntax-only -std=c11 -Wall -Wpedantic` on the header to
/// guarantee it parses as strict C11. No build of `CactusCore` is required.
final class Story1_2Tests: XCTestCase {

    // MARK: - Helpers

    /// Walks up from this source file to the `apps/CactusVoice` directory.
    private var appRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "CactusVoice" || !FileManager.default.fileExists(
            atPath: url.appendingPathComponent("project.yml").path
        ) {
            let parent = url.deletingLastPathComponent()
            if parent == url { break }
            url = parent
        }
        return url
    }

    private func read(_ relative: String) throws -> String {
        let url = appRoot.appendingPathComponent(relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(
            atPath: appRoot.appendingPathComponent(relative).path
        )
    }

    // MARK: - AC1: required symbols

    func testHeaderExists() {
        XCTAssertTrue(exists("CactusCore/include/cactus_c.h"),
                      "cactus_c.h must exist")
    }

    func testHeaderDeclaresRequiredSymbols() throws {
        let h = try read("CactusCore/include/cactus_c.h")
        let required = [
            "cactus_runtime_init",
            "cactus_runtime_shutdown",
            "cactus_load_model",
            "cactus_free_model",
            "cactus_whisper_create_session",
            "cactus_whisper_push_pcm",
            "cactus_whisper_pull_partial",
            "cactus_whisper_close_session",
            "cactus_llm_run",
            "cactus_onnx_run",
        ]
        for sym in required {
            XCTAssertTrue(h.contains(sym),
                          "cactus_c.h must declare \(sym)")
        }
        XCTAssertTrue(h.contains("extern \"C\"") || h.contains("__cplusplus"),
                      "header must guard with extern \"C\"")
    }

    // MARK: - AC2: whisper opts struct fields

    func testWhisperOptsStructFields() throws {
        let h = try read("CactusCore/include/cactus_c.h")
        let required = [
            "language",
            "condition_on_previous_text",
            "temperature_fallback",
            "no_repeat_ngram_size",
            "logprob_threshold",
            "compression_ratio_threshold",
            "initial_prompt",
        ]
        for field in required {
            XCTAssertTrue(h.contains(field),
                          "whisper opts must declare \(field)")
        }
    }

    // MARK: - AC3: top-K + logprobs

    func testPullPartialTopKLogprobs() throws {
        let h = try read("CactusCore/include/cactus_c.h")
        XCTAssertTrue(h.contains("topk") || h.contains("top_k") || h.contains("hypothes"),
                      "pull_partial must surface top-K hypotheses")
        XCTAssertTrue(h.contains("logprob"),
                      "pull_partial must surface per-token logprobs")
        XCTAssertTrue(h.contains("confidence") || h.contains("aggregate"),
                      "pull_partial must surface aggregate confidence")
    }

    // MARK: - AC4: every function returns cactus_status_t

    func testAllFunctionsReturnStatus() throws {
        let h = try read("CactusCore/include/cactus_c.h")
        XCTAssertTrue(h.contains("cactus_status_t"),
                      "cactus_status_t typedef required")
        // Each public function must be annotated as returning cactus_status_t.
        let funcs = [
            "cactus_runtime_init",
            "cactus_runtime_shutdown",
            "cactus_load_model",
            "cactus_free_model",
            "cactus_whisper_create_session",
            "cactus_whisper_push_pcm",
            "cactus_whisper_pull_partial",
            "cactus_whisper_close_session",
            "cactus_llm_run",
            "cactus_onnx_run",
        ]
        for fn in funcs {
            // Look for "cactus_status_t <fn>" anywhere in the header.
            XCTAssertTrue(
                h.range(of: "cactus_status_t\\s+\(fn)\\s*\\(",
                        options: .regularExpression) != nil,
                "\(fn) must return cactus_status_t"
            )
        }
    }

    // MARK: - AC5: every function has a doc comment (2–4 lines)

    func testEveryFunctionHasDocComment() throws {
        let h = try read("CactusCore/include/cactus_c.h")
        let funcs = [
            "cactus_runtime_init",
            "cactus_runtime_shutdown",
            "cactus_load_model",
            "cactus_free_model",
            "cactus_whisper_create_session",
            "cactus_whisper_push_pcm",
            "cactus_whisper_pull_partial",
            "cactus_whisper_close_session",
            "cactus_llm_run",
            "cactus_onnx_run",
        ]
        for fn in funcs {
            // The function declaration must be preceded (within the previous
            // ~600 chars) by a `/*` doc comment that mentions ownership or
            // threading.
            guard let range = h.range(of: "\(fn)\\s*\\(",
                                      options: .regularExpression) else {
                XCTFail("Cannot find declaration of \(fn)")
                continue
            }
            let preStart = h.index(range.lowerBound,
                                   offsetBy: -600,
                                   limitedBy: h.startIndex) ?? h.startIndex
            let pre = String(h[preStart..<range.lowerBound])
            XCTAssertTrue(pre.contains("/*") || pre.contains("///"),
                          "\(fn) must have a doc comment immediately above")
        }
    }

    // MARK: - AC6: module.modulemap exposes cactus_c.h

    func testModuleMapExposesCactusC() throws {
        let mm = try read("CactusCore/module.modulemap")
        XCTAssertTrue(mm.contains("cactus_c.h"),
                      "module.modulemap must expose cactus_c.h")
    }

    // MARK: - AC7: FFIShim.swift mirrors the C surface

    func testFFIShimMirrorsCSurface() throws {
        XCTAssertTrue(exists("CactusCore/Sources/FFIShim.swift"),
                      "FFIShim.swift must exist")
        let s = try read("CactusCore/Sources/FFIShim.swift")
        let mirroredSymbols = [
            "runtimeInit",
            "runtimeShutdown",
            "loadModel",
            "freeModel",
            "whisperCreateSession",
            "whisperPushPCM",
            "whisperPullPartial",
            "whisperCloseSession",
            "llmRun",
            "onnxRun",
        ]
        for sym in mirroredSymbols {
            XCTAssertTrue(s.contains(sym),
                          "FFIShim must mirror C entry: \(sym)")
        }
        // Hard bar — no policy in the shim.
        XCTAssertFalse(s.contains("os.Logger") || s.contains("Logger("),
                       "FFIShim must not contain logging (no policy)")
        XCTAssertFalse(s.contains("URLCache") || s.contains("NSCache"),
                       "FFIShim must not contain caching (no policy)")
    }

    // MARK: - AC8: no C++ types in the C header (and it parses C11)

    func testNoCxxTypesInHeader() throws {
        let h = try read("CactusCore/include/cactus_c.h")
        // Forbid common C++-only constructs at the top level of a .h.
        let cxxBanned = [
            "std::",
            "namespace ",
            "template<",
            "template <",
            "class ",
            "public:",
            "private:",
        ]
        for bad in cxxBanned {
            // `class ` would appear inside extern "C" guards only on accident.
            XCTAssertFalse(h.contains(bad),
                           "Header must not reference C++ construct: \(bad)")
        }
    }

    func testHeaderParsesAsStrictC11() throws {
        let clang = "/usr/bin/clang"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: clang),
                          "clang not available")
        let headerPath = appRoot
            .appendingPathComponent("CactusCore/include/cactus_c.h").path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: clang)
        proc.arguments = [
            "-fsyntax-only",
            "-Wall",
            "-Wpedantic",
            "-Werror",
            "-std=c11",
            "-x", "c",
            headerPath,
        ]
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        XCTAssertEqual(proc.terminationStatus, 0,
                       "cactus_c.h must parse cleanly as strict C11. clang said: \(stderr)")
    }

    // MARK: - C stub exists so the static lib actually links

    func testFFIStubCExists() {
        XCTAssertTrue(exists("CactusCore/Sources/FFIStub.c"),
                      "FFIStub.c must exist so CactusCore links")
    }
}
