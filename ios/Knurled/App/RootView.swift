import SwiftUI

enum AppTab: Hashable {
    case workout
    case history
    case plan
    case settings
}

struct RootView: View {
    @Environment(ThemeStore.self) private var theme
    @State private var selection: AppTab = .workout

    var body: some View {
        TabView(selection: $selection) {
            Tab("Workout", systemImage: "dumbbell.fill", value: AppTab.workout) {
                WorkoutHomeView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: AppTab.history) {
                HistoryHomeView()
            }
            Tab("Plan", systemImage: "list.bullet.rectangle", value: AppTab.plan) {
                PlanHomeView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsHomeView()
            }
        }
        .tint(theme.palette.accent)
        .environment(\.knurledPalette, theme.palette)
    }
}

#Preview {
    RootView()
        .environment(ThemeStore())
}
