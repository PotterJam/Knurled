import SwiftUI

struct HistoryDetailView: View {
    let repo: ActiveRepo
    let event: TrainingEvent

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var edits: [String: Int] = [:]
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Text("Edit what actually happened. Corrections are recorded as new events and the plan is recomputed — your original log is never rewritten.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(event.workoutResults.enumerated()), id: \.offset) { _, result in
                Section {
                    ForEach(Array(result.actual.enumerated()), id: \.offset) { index, set in
                        repsRow(slot: result.slotId, index: index, set: set)
                    }
                } header: {
                    Text(exerciseName(result))
                }
            }

            if !pendingChanges.isEmpty {
                Section {
                    Button {
                        Task { await save() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSaving { ProgressView() } else { Text("Save Correction") }
                            Spacer()
                        }
                    }
                    .disabled(isSaving)
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle((event.sessionId ?? "Session").uppercased())
        .navigationBarTitleDisplayMode(.inline)
    }

    private func repsRow(slot: String, index: Int, set: ActualSet) -> some View {
        let key = "\(slot)#\(index)"
        let base = effectiveReps(slot: slot, index: index, original: set.reps)
        let value = edits[key] ?? base
        return Stepper(
            value: Binding(get: { edits[key] ?? base }, set: { edits[key] = $0 }),
            in: 0...99
        ) {
            HStack {
                Text("Set \(set.set)")
                if let load = set.load {
                    Text(load).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(value) reps")
                    .monospacedDigit()
                    .foregroundStyle(value != base ? .orange : .primary)
            }
        }
    }

    private func exerciseName(_ result: ExerciseResult) -> String {
        (result.performedExercise ?? result.slotId)
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    /// Applies any prior corrections targeting this event so the editor shows current values (§20).
    private func effectiveReps(slot: String, index: Int, original: Int) -> Int {
        let path = "results[\(slot)].actual[\(index)].reps"
        var value = original
        for correction in repo.events
        where correction.type == "session_corrected" && correction.correctsEventId == event.id {
            for change in correction.changes where change.path == path {
                if let after = change.after.intValue { value = after }
            }
        }
        return value
    }

    private var pendingChanges: [CorrectionChange] {
        event.workoutResults.flatMap { result in
            result.actual.enumerated().compactMap { index, set -> CorrectionChange? in
                let key = "\(result.slotId)#\(index)"
                let base = effectiveReps(slot: result.slotId, index: index, original: set.reps)
                guard let newReps = edits[key], newReps != base else { return nil }
                return CorrectionChange(
                    path: "results[\(result.slotId)].actual[\(index)].reps",
                    before: .int(base),
                    after: .int(newReps)
                )
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await app.correct(event: event, changes: pendingChanges, in: repo)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
