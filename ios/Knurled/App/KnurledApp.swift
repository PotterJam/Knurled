import SwiftUI

@main
struct KnurledApp: App {
    @State private var app = AppModel()
    @State private var theme = ThemeStore()
    @State private var bodyMetrics = BodyMetricsStore()
    @State private var workoutSettings = WorkoutSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(theme)
                .environment(bodyMetrics)
                .environment(workoutSettings)
                .task { await app.bootstrap() }
        }
    }
}
