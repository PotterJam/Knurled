import SwiftUI

@main
struct KnurledApp: App {
    @State private var app = AppModel()
    @State private var theme = ThemeStore()
    @State private var bodyMetrics = BodyMetricsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(theme)
                .environment(bodyMetrics)
                .task { await app.bootstrap() }
        }
    }
}
