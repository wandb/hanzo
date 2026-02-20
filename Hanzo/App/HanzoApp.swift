import SwiftUI

@main
struct HanzoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings window is managed manually in AppDelegate
        // because SwiftUI's Settings scene doesn't work with LSUIElement apps
        Settings {
            EmptyView()
        }
    }
}
