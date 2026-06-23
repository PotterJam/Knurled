import SwiftUI

@main
struct KnurledApp: App {
    @State private var app = AppModel()
    @State private var theme = ThemeStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(theme)
                .task { await app.bootstrap() }
        }
    }
}
