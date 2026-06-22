import SwiftUI

struct FinishWorkoutView: View {
    let workout: LiveWorkout
    var onCommitted: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case computing
        case preview(ReductionOutcome)
        case submitting
        case failed(String)
    }

    @State private var phase: Phase = .computing
    @State private var timestamp = LiveWorkout.timestamp()

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .computing:
                    ProgressView("Calculating effects…")
                case .preview(let outcome):
                    previewContent(outcome)
                case .submitting:
                    ProgressView("Saving…")
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't finish", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    }
                }
            }
            .navigationTitle("\(workout.session.displayName) Complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await compute() }
        }
    }

    private func previewContent(_ outcome: ReductionOutcome) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KnurledTheme.Spacing.l) {
                VStack(alignment: .leading, spacing: KnurledTheme.Spacing.s) {
                    Text("Effects").font(.headline)
                    ForEach(Array((outcome.result.event?.results ?? []).enumerated()), id: \.offset) { _, result in
                        EffectResultRow(result: result, title: title(forSlot: result.slotId))
                    }
                    if (outcome.result.event?.results ?? []).isEmpty {
                        Text("No progression changes.").foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Next").font(.headline)
                    Text(outcome.result.nextWorkout.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await submit(outcome) }
                } label: {
                    Label("Submit Workout", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
        }
    }

    private func title(forSlot slot: String) -> String {
        workout.session.items.first { $0.slotId == slot }?.display.title
            ?? WorkoutFormat.laneTitle(slot)
    }

    private func compute() async {
        guard case .computing = phase else { return }
        let input = workout.executionInput(status: ExecutionStatus.complete, timestamp: timestamp)
        do {
            let outcome = try await app.engine.reduce(dir: workout.repo.url, input: input)
            if outcome.result.validation.isValid {
                phase = .preview(outcome)
            } else {
                let message = outcome.result.validation.errors.map(\.message).joined(separator: "\n")
                phase = .failed(message.isEmpty ? "The workout could not be validated." : message)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func submit(_ outcome: ReductionOutcome) async {
        phase = .submitting
        do {
            try await app.commit(outcome: outcome, in: workout.repo, timestamp: timestamp)
            onCommitted()
            dismiss()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct EffectResultRow: View {
    let result: ExerciseResult
    let title: String

    private var symbol: (name: String, color: Color) {
        switch result.outcome {
        case "pass": ("checkmark.circle.fill", .green)
        case "fail": ("xmark.circle.fill", .red)
        case "adjusted_today": ("arrow.down.circle.fill", .orange)
        default: ("circle", .secondary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol.name)
                .foregroundStyle(symbol.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if result.effects.isEmpty {
                    Text(result.outcome == "adjusted_today" ? "Adjusted today · repeat next time" : "No change")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(result.effects.enumerated()), id: \.offset) { _, effect in
                        Text(WorkoutFormat.effectSummary(effect))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }
}
