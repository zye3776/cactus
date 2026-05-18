# Errors & Logging Conventions

One canonical error type, one canonical logger. Per architecture §G, §4, §5.

## `AppError`

`AppError` is the only `Error` type that crosses an actor boundary or reaches the UI.

- Map underlying errors (`NSError`, FFI status codes, thrown Swift errors)
  to an `AppError` case **at the seam where they leave their owning actor**.
- Internal helpers throw whatever's natural; the boundary translates.
- `AppError` is logged at `.error` **exactly once**, at the creation site.
  Never re-log on re-throw.
- `errorDescription` is the UX banner string (UX-DR6: declarative, ≤ 8 words,
  no exclamation marks). `ErrorBanner` switches exhaustively on the case.

## `os.Logger`

Every source file that logs declares one logger at file scope:

```swift
import os
private let log = Logger(subsystem: "com.cactusvoice", category: "audio")
```

- Subsystem is always `com.cactusvoice`.
- Category is the component name in lowerCamel (`audio`, `whisper`, `vad`,
  `llm`, `runtime`, `transcript`, `hotkey`, `permissions`, `settings`,
  `errors`, `ui`).
- Levels: `.debug` (verbose tracing), `.info` (state transitions), `.error`
  (`AppError` creation). `.fault` / `.notice` unused.
- Interpolations of user content — PCM buffer pointers, model paths,
  transcript text — must use `privacy: .private`:

  ```swift
  log.error("model load failed: \(path, privacy: .private)")
  ```

- Clipboard contents are **never** logged, at any privacy level.

## Linting

No `.swiftformat` / SwiftLint config is checked in for v1 (architecture §10).
The "always use `privacy: .private` for user content" rule is enforced by
review, not by an automated linter. Wiring a linter is deferred to a future
story.
