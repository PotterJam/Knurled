import Foundation
import Testing
@testable import Knurled

@MainActor
@Suite struct WorkoutSettingsTests {
    @Test func restTimersDefaultOnAndPersist() {
        let suiteName = "WorkoutSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = WorkoutSettings(defaults: defaults)
        #expect(initial.restTimersEnabled)

        initial.restTimersEnabled = false

        let restored = WorkoutSettings(defaults: defaults)
        #expect(!restored.restTimersEnabled)
    }

    @Test func disablingRestTimersSuppressesCountdowns() async throws {
        let dir = try SampleRepo.makeWorkingCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = RustWorkoutEngine()
        let repo = ActiveRepo(displayName: "Test", url: dir, isSample: true)
        let session = try #require(try await engine.build(dir: dir, write: false).nextWorkout)
        let workout = LiveWorkout(repo: repo, session: session)
        let controller = WorkoutLiveController.shared
        controller.begin(workout, restTimersEnabled: false)
        defer { controller.end() }

        let item = try #require(workout.items.first)
        controller.didLogSetInApp(item: item)

        #expect(!controller.isResting)
        #expect(controller.restEndDate == nil)
    }
}
