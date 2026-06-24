import SwiftUI

enum AppTab: Hashable {
    case workout
    case history
    case data
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
            Tab("Data", systemImage: "chart.xyaxis.line", value: AppTab.data) {
                DataHomeView()
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
