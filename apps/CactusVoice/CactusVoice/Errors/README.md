# Errors & Logging Conventions

One canonical error type, one canonical logger. Per architecture §G, §4, §5.

## `AppError`

The only `Error` type that crosses an actor boundary or reaches the UI.

- Map underlying errors to an `AppError` case **at the seam where they
  leave their owning actor**. Internal helpers throw whatever's natural.
- `AppError` is logged at `.error` **exactly once**, at the creation site.
  Never re-log on re-throw.
- `errorDescription` is the UX banner string (UX-DR6: declarative,
  ≤ 8 words, no exclamation marks). `ErrorBanner` switches exhaustively.

## `os.Logger`

Every source file that logs declares one logger at file scope:

```swift
import os
private let log = Logger(subsystem: "com.cactusvoice", category: "audio")
```

- Subsystem is always `com.cactusvoice`. Category is the component name
  in lowerCamel (`audio`, `whisper`, `vad`, `llm`, `runtime`, etc.).
- Levels: `.debug` (verbose), `.info` (state transitions), `.error`
  (`AppError` creation). `.fault` / `.notice` unused.
- User-content interpolations (PCM pointers, model paths, transcript
  text) must use `privacy: .private`:

  ```swift
  log.error("model load failed: \(path, privacy: .private)")
  ```

- Clipboard contents are **never** logged, at any privacy level.

## Linting

No `.swiftformat` / SwiftLint config is checked in for v1
(architecture §10). The `privacy: .private` rule is enforced by review;
linter wiring is deferred to a future story.
