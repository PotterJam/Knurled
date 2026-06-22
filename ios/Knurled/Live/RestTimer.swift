import ActivityKit
import Foundation
import Observation

@MainActor
@Observable
final class RestTimer {
    let workoutName: String

    private(set) var endDate: Date?
    private(set) var exerciseTitle = ""
    private var now: Date = .now
    private var tickTask: Task<Void, Never>?
    private var activity: Activity<RestActivityAttributes>?

    init(workoutName: String) {
        self.workoutName = workoutName
    }

    var isRunning: Bool { remaining > 0 }

    var remaining: TimeInterval {
        guard let endDate else { return 0 }
        return max(0, endDate.timeIntervalSince(now))
    }

    var remainingText: String {
        let total = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func start(seconds: Int, exercise: String) {
        exerciseTitle = exercise
        now = .now
        endDate = now.addingTimeInterval(TimeInterval(seconds))
        startTicker()
        startActivity()
    }

    func add(_ seconds: Int) {
        guard let endDate else { return }
        let updated = max(now, endDate.addingTimeInterval(TimeInterval(seconds)))
        self.endDate = updated
        if remaining <= 0 { finish() } else { updateActivity() }
    }

    func skip() { finish() }

    private func finish() {
        tickTask?.cancel()
        tickTask = nil
        endDate = nil
        endActivity()
    }

    private func startTicker() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.endDate != nil else { return }
                self.now = .now
                if self.remaining <= 0 { self.finish() }
            }
        }
    }

    // MARK: - Live Activity

    private func startActivity() {
        endActivity()
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let endDate else { return }
        let attributes = RestActivityAttributes(workoutName: workoutName)
        let state = RestActivityAttributes.ContentState(endDate: endDate, exerciseTitle: exerciseTitle)
        activity = try? Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: endDate)
        )
    }

    private func updateActivity() {
        guard let activity, let endDate else { return }
        let state = RestActivityAttributes.ContentState(endDate: endDate, exerciseTitle: exerciseTitle)
        Task { await activity.update(.init(state: state, staleDate: endDate)) }
    }

    private func endActivity() {
        guard let current = activity else { return }
        Task { await current.end(nil, dismissalPolicy: .immediate) }
        activity = nil
    }
}
