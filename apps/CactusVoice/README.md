# CactusVoice

Privacy-first, on-device speech-to-text utility for macOS 14+ (Apple Silicon),
powered by the cactus C++ inference library. See
`../../_bmad-output/planning-artifacts/{prd,architecture,epics}.md` for the
full design.

## Layout

Two targets live in one workspace (`CactusVoice.xcworkspace`):

- **CactusVoice** — SwiftUI macOS app (`com.cactusvoice`, macOS 14+, arm64).
- **CactusCore** — static library that owns the `extern "C"` seam to cactus.

Folder map (per `architecture.md` §Project Structure):

```
CactusVoice/App         CactusVoice/Hotkey       CactusVoice/Permissions
CactusVoice/Audio       CactusVoice/Inference    CactusVoice/Persistence
CactusVoice/Errors      CactusVoice/Resources    CactusVoice/UI
CactusVoice/Transcript
CactusCore/include      CactusCore/Sources       CactusCore/module.modulemap
CactusVoiceTests/...
```

## Regenerating the Xcode project

The `.xcodeproj` is **generated** from `project.yml` via
[XcodeGen](https://github.com/yonaskolb/XcodeGen). It is git-ignored.

```sh
brew install xcodegen          # one-time
cd apps/CactusVoice
xcodegen generate              # produces CactusVoice.xcodeproj
open CactusVoice.xcworkspace   # opens app + CactusCore in Xcode
```

## Build & test from CLI

```sh
xcodebuild -workspace CactusVoice.xcworkspace \
           -scheme CactusVoice \
           -configuration Debug build
xcodebuild -workspace CactusVoice.xcworkspace \
           -scheme CactusVoice \
           test
```

## Dependencies

The only third-party Swift package is
[`KeyboardShortcuts`](https://github.com/sindresorhus/KeyboardShortcuts)
(`~> 2.4`). No network entitlement; no analytics; no auto-update.
