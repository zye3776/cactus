# CactusVoiceTests / Fixtures

This directory hosts fixtures consumed by `CactusVoiceTests`. The Story 3.5
end-to-end baseline pipeline test (`Inference/BaselinePipelineTests.swift`)
expects two files here.

## Expected files

### `baseline_10s.wav`

A ~10 second WAV recording of clean English speech.

- **Format:** WAV / RIFF, 16 kHz mono PCM (Float32 or PCM-16 — the test's
  `wavReader` helper resamples and re-encodes via `AVAudioConverter` to
  the canonical 16 kHz mono Float32 non-interleaved format used elsewhere
  in the pipeline).
- **Source:** any clean English speech recording (a single speaker,
  minimal background noise, normal conversational pace).
- **Length:** ~10 s (the WER bound is a loose 15 % baseline — see below).

The path defaults to `apps/CactusVoice/CactusVoiceTests/Fixtures/baseline_10s.wav`
and can be overridden via the `CACTUSVOICE_BASELINE_WAV` env var.

### `baseline_10s.transcript.txt`

The ground-truth transcript of `baseline_10s.wav`, used as the WER reference.

- **Encoding:** UTF-8.
- **Normalization:** lowercase, no punctuation, single spaces between words,
  trailing newline OK.
- **Path:** alongside the WAV at
  `apps/CactusVoice/CactusVoiceTests/Fixtures/baseline_10s.transcript.txt`.

## WER computation

The test computes Word Error Rate via Levenshtein edit distance on
whitespace-tokenized words after the same normalization the reference
transcript is stored in (lowercased, punctuation stripped, single-space).

  WER = Levenshtein(reference_words, hypothesis_words) / reference_words.count

The bound is `WER ≤ 0.15` (15 %). This is the **bare Whisper baseline**, not
the full pipeline — the Story 9.x correction pipeline is expected to push
this down materially.

## Env-var gating

The integration test is `XCTSkipUnless`-gated on three env vars so it can be
authored and pushed without local execution on Command-Line-Tools-only hosts:

  * `CACTUSVOICE_WHISPER_PATH` — absolute path to a Whisper model file.
  * `CACTUSVOICE_VAD_PATH` — absolute path to the Silero VAD ONNX file.
  * `CACTUSVOICE_BASELINE_WAV` — absolute path to the baseline WAV
    (optional; defaults to `Fixtures/baseline_10s.wav`).

On a developer / CI host with Xcode.app and the models + WAV available,
export the three vars and run the `CactusVoice` scheme's test action. On
the bootstrap CLT-only host this test is skipped.

## Host limitation

The bootstrap host (Command Line Tools only, no Xcode.app, no real model
files, no recorded WAV) cannot execute this test. The Story 3.5 contract
is enforced by `StoryAcceptance/Story3_5Tests.swift` (static greps on the
test file + this README). Full runtime verification runs on a developer /
CI host with everything wired.
