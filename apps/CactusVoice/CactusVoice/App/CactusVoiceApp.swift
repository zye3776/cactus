import SwiftUI

/// CactusVoice application entry point.
///
/// At this story (1.1) the app is intentionally headless: the SwiftUI body is
/// an empty `Settings` scene so the `.app` bundle launches and exits cleanly
/// without rendering user-visible UI. Subsequent stories add the menu-bar
/// surface, the floating capture window, and the real settings scene.
@main
struct CactusVoiceApp: App {
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
