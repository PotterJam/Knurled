import SwiftUI

enum AppTab: Hashable {
    case workout
    case history
    case data
    case settings
}

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(ThemeStore.self) private var theme
    @State private var selection: AppTab = .workout

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                ProgressView("Loading…")
            case .onboarding:
                OnboardingWizardView()
            case .ready:
                tabs
            }
        }
        .tint(theme.palette.accent)
        .environment(\.knurledPalette, theme.palette)
    }

    private var tabs: some View {
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
    }
}

#Preview {
    RootView()
        .environment(AppModel())
        .environment(ThemeStore())
        .environment(WorkoutSettings())
}
