import AppIntents

// These LiveActivityIntents are compiled into both the app and the widget extension so the
// widget can construct the buttons. Their `perform()` runs in the app process, where the
// shared WorkoutLiveController lives — guarded by KNURLED_APP so the extension build (which
// has no access to app-only types) still compiles.

struct LogSetIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Log set"

    func perform() async throws -> some IntentResult {
        #if KNURLED_APP
        await WorkoutLiveController.shared.logCurrentSet()
        #endif
        return .result()
    }
}

struct SkipRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Skip rest"

    func perform() async throws -> some IntentResult {
        #if KNURLED_APP
        await WorkoutLiveController.shared.skipRest()
        #endif
        return .result()
    }
}

struct AddRestIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Add 30 seconds"

    func perform() async throws -> some IntentResult {
        #if KNURLED_APP
        await WorkoutLiveController.shared.addRest(30)
        #endif
        return .result()
    }
}

struct AmrapStepIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Adjust reps"

    @Parameter(title: "Delta") var delta: Int

    init() {}
    init(delta: Int) { self.delta = delta }

    func perform() async throws -> some IntentResult {
        #if KNURLED_APP
        await WorkoutLiveController.shared.adjustAmrap(delta: delta)
        #endif
        return .result()
    }
}
