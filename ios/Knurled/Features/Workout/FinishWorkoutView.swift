import SwiftUI

struct FinishWorkoutView: View {
    let workout: LiveWorkout
    var onCommitted: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case computing
        case preview(ReductionResult)
        case submitting
        case failed(String)
    }

    @State private var phase: Phase = .computing
    @State private var timestamp = LiveWorkout.timestamp()
    @State private var mode: SubmitMode = .advance

    private var isComplete: Bool {
        workout.finishStatus == ExecutionStatus.complete
    }

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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .navigationTitle(navigationTitle)
            .task { await compute() }
        }
    }

    private var navigationTitle: String {
        isComplete ? "\(workout.session.displayName) Complete" : "Save \(workout.session.displayName)"
    }

    private var submitTitle: String {
        isComplete ? "Submit Workout" : "Save Progress"
    }

    private func previewContent(_ outcome: ReductionResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: KnurledTheme.Spacing.l) {
                if isComplete {
                    Picker("Submit mode", selection: $mode) {
                        ForEach(SubmitMode.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(mode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Logged sets will be saved without applying progression.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: KnurledTheme.Spacing.s) {
                    Text("Effects").font(.headline)
                    if !isComplete {
                        Text("No progression changes.").foregroundStyle(.secondary)
                    } else if mode == .advance {
                        ForEach(Array(outcome.results.enumerated()), id: \.offset) { _, result in
                            EffectResultRow(result: result, title: title(forSlot: result.slotId))
                        }
                    } else if mode == .offDay {
                        Text("No progression changes.").foregroundStyle(.secondary)
                    } else {
                        Text("Baselines will be reset from the performed loads.").foregroundStyle(.secondary)
                    }
                    if mode == .advance && outcome.results.isEmpty {
                        Text("No progression changes.").foregroundStyle(.secondary)
                    }
                }

                if isComplete {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next").font(.headline)
                        Text(outcome.nextWorkout.displayName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await submit(outcome) }
                } label: {
                    Label(submitTitle, systemImage: "arrow.up.circle.fill")
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
        let input = workout.finishInput(timestamp: timestamp)
        do {
            let outcome = try await app.engine.reduce(dir: workout.repo.url, session: workout.session, input: input)
            if outcome.validation.isValid {
                phase = .preview(outcome)
            } else {
                let message = outcome.validation.errors.map(\.message).joined(separator: "\n")
                phase = .failed(message.isEmpty ? "The workout could not be validated." : message)
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func submit(_ outcome: ReductionResult) async {
        phase = .submitting
        do {
            let input = workout.finishInput(timestamp: timestamp)
            let submitted = try await app.submit(
                session: workout.session,
                input: input,
                mode: mode,
                in: workout.repo,
                timestamp: timestamp
            )
            guard submitted.validation.isValid else {
                let message = submitted.validation.errors.map(\.message).joined(separator: "\n")
                phase = .failed(message.isEmpty ? "The workout could not be submitted." : message)
                return
            }
            onCommitted()
            dismiss()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct SavedResultRow: View {
    let result: ExerciseResult
    let title: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text("\(result.actual.count) \(result.actual.count == 1 ? "set" : "sets") logged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
