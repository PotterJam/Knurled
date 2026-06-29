import SwiftUI

enum HistoryFilter: CaseIterable, Hashable {
    case all
    case workouts
    case programs

    var title: String {
        switch self {
        case .all: "All"
        case .workouts: "Workouts"
        case .programs: "Programs"
        }
    }
}

struct HistoryItem: Identifiable, Hashable {
    enum Kind { case workout, program }

    let id: String
    let title: String
    let detail: String
    let status: String
    let statusStyle: StatusChip.Style
    let kind: Kind
    let record: TrainingRecord

    var canContinue: Bool {
        record.status == ExecutionStatus.partial && record.sessionId != nil
    }
}

enum HistoryBuilder {
    static func items(from records: [TrainingRecord]) -> [HistoryItem] {
        var activeProgram: String?
        return records
            .compactMap { record -> HistoryItem? in
                // Program markers set the context that following workouts inherit, so a workout
                // row can be labelled with the program it belongs to.
                if let program = record.program { activeProgram = program }
                return item(from: record, activeProgram: activeProgram)
            }
            .reversed()
    }

    private static func item(from record: TrainingRecord, activeProgram: String?) -> HistoryItem? {
        let date = WorkoutFormat.relativeDay(fromISO: record.date) ?? record.date
        if !record.lifts.isEmpty {
            let isPartial = record.status == ExecutionStatus.partial
            return HistoryItem(
                id: record.id,
                title: title(for: record, activeProgram: activeProgram),
                detail: date,
                status: isPartial ? "Partial" : "Recorded",
                statusStyle: isPartial ? .warn : .ok,
                kind: .workout,
                record: record
            )
        }
        if let program = record.program {
            return HistoryItem(
                id: record.id,
                title: programShorthand(program),
                detail: date,
                status: "Program",
                statusStyle: .neutral,
                kind: .program,
                record: record
            )
        }
        return nil
    }

    private static func title(for record: TrainingRecord, activeProgram: String?) -> String {
        // Prefer the program shorthand plus the cycle/session (e.g. "GZCLP · A1") over a raw lift
        // count, which warm-ups and accessories inflate misleadingly.
        let program = activeProgram.map(programShorthand)
        let cycle = record.sessionId?.uppercased()
        let label = [program, cycle].compactMap { $0 }.joined(separator: " · ")
        if !label.isEmpty { return label }

        if record.lifts.count == 1, let lift = record.lifts.first {
            return lift.exercise.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return "\(record.lifts.count) lifts"
    }

    /// "gzcl.gzclp" → "GZCLP": the last dotted component, upper-cased, as a compact label.
    static func programShorthand(_ program: String) -> String {
        (program.split(separator: ".").last.map(String.init) ?? program).uppercased()
    }
}

struct HistoryRow: View {
    let item: HistoryItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.headline)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            StatusChip(text: item.status, style: item.statusStyle)
        }
        .padding(.vertical, 2)
    }
}

struct HistoryDetailView: View {
    let item: HistoryItem
    @Environment(AppModel.self) private var app
    @State private var record: TrainingRecord
    @State private var setTarget: LiftRecord?
    @State private var showsAddExercise = false
    @State private var amendmentError: String?

    init(item: HistoryItem) {
        self.item = item
        _record = State(initialValue: item.record)
    }

    private var canAmend: Bool {
        item.kind == .workout && record.status != ExecutionStatus.partial && record.completedAt != nil
    }

    var body: some View {
        if canAmend {
            EditableHistoryWorkoutView(record: $record, title: item.title)
        } else {
            readOnlyBody
        }
    }

    private var readOnlyBody: some View {
        List {
            if item.canContinue {
                Section {
                    NavigationLink {
                        ContinueWorkoutView(record: item.record)
                    } label: {
                        Label("Continue Workout", systemImage: "play.fill")
                    }
                }
            }

            Section {
                LabeledContent("Date", value: WorkoutFormat.relativeDay(fromISO: record.date) ?? record.date)
                LabeledContent("Type", value: item.kind == .workout ? "Workout" : "Program")
                if let sessionId = record.sessionId {
                    LabeledContent("Session", value: sessionId.uppercased())
                }
                if let program = record.program {
                    LabeledContent("Program", value: program)
                }
                if let note = record.note {
                    Text(note)
                }
            }

            if !record.lifts.isEmpty {
                Section("Lifts") {
                    ForEach(record.lifts) { lift in
                        HistoryLiftRow(lift: lift)
                        if canAmend {
                            Button("Add Set", systemImage: "plus.circle") { setTarget = lift }
                        }
                    }
                }
            }

            if canAmend {
                Section {
                    Button("Add Exercise", systemImage: "plus") { showsAddExercise = true }
                } footer: {
                    Text("Amendments update history only. Your progression and next workout do not change.")
                }
            }
        }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $setTarget) { lift in
            AddMissedSetSheet(lift: lift) { load, reps, metrics in
                amend(.addSet(liftId: lift.liftId, load: load, reps: reps, metrics: metrics))
            }
        }
        .sheet(isPresented: $showsAddExercise) {
            if let repo = app.activeRepo {
                AddExerciseSheet(repo: repo, catalog: app.exerciseCatalog) { exercise, load, count, reps in
                    let sets = (1...count).map { ActualSet(set: $0, load: load, reps: reps) }
                    amend(.addExercise(exercise: exercise, weight: load, note: nil, sets: sets))
                }
            }
        }
        .alert("Couldn't amend workout", isPresented: Binding(
            get: { amendmentError != nil },
            set: { if !$0 { amendmentError = nil } }
        )) {
            Button("OK", role: .cancel) { amendmentError = nil }
        } message: {
            Text(amendmentError ?? "Unknown error")
        }
    }

    private func amend(_ amendment: RecordAmendment) {
        guard let repo = app.activeRepo else { return }
        Task {
            do {
                let outcome = try await app.amendRecord(record, amendment: amendment, in: repo)
                record = outcome.record
            } catch {
                amendmentError = error.localizedDescription
            }
        }
    }
}

private struct EditableHistoryWorkoutView: View {
    @Binding var record: TrainingRecord
    let title: String

    @Environment(AppModel.self) private var app
    @State private var workout: LiveWorkout?
    @State private var baseline: [DraftItem] = []
    @State private var isSaving = false
    @State private var showsAddExercise = false
    @State private var message: String?
    @State private var errorMessage: String?

    private let controller = WorkoutLiveController.shared

    var body: some View {
        Group {
            if let workout {
                ScrollView {
                    LazyVStack(spacing: KnurledTheme.Spacing.s) {
                        ForEach(workout.items) { item in
                            LiveExerciseCard(
                                live: item,
                                controller: controller,
                                onDelete: item.isTrackingOnlyExtra ? {
                                    workout.removeItem(item)
                                } : nil
                            )
                        }
                        Button {
                            showsAddExercise = true
                        } label: {
                            Label("Add Exercise", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 6) {
                        if let message {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                        Button {
                            save(workout)
                        } label: {
                            if isSaving {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text("Save changes").frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isSaving || workout.draftItems() == baseline)
                    }
                    .padding()
                    .background(.bar)
                }
                .sheet(isPresented: $showsAddExercise) {
                    if let repo = app.activeRepo {
                        AddExerciseSheet(repo: repo, catalog: app.exerciseCatalog) { exercise, load, sets, reps in
                            _ = workout.addExtraExercise(exercise: exercise, load: load, setCount: sets, reps: reps)
                        }
                    }
                }
            } else if let errorMessage {
                ContentUnavailableView("Couldn't edit workout", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                ProgressView("Loading workout…")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("Couldn't save changes", isPresented: Binding(
            get: { errorMessage != nil && workout != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func load() async {
        guard workout == nil, let repo = app.activeRepo, let sessionId = record.sessionId else { return }
        do {
            let session = try await app.engine.renderSession(dir: repo.url, sessionId: sessionId)
            let loaded = LiveWorkout(repo: repo, session: session, restoring: record)
            workout = loaded
            baseline = loaded.draftItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save(_ workout: LiveWorkout) {
        guard let repo = app.activeRepo else { return }
        isSaving = true
        message = nil
        Task {
            do {
                let lifts = workout.replacementLifts(from: record)
                let outcome = try await app.amendRecord(record, amendment: .replaceLifts(lifts), in: repo)
                record = outcome.record
                baseline = workout.draftItems()
                message = outcome.recomputedLanes.isEmpty
                    ? "History updated; progression was already superseded."
                    : "History and \(outcome.recomputedLanes.count) current progression lane(s) updated."
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

private struct AddMissedSetSheet: View {
    let lift: LiftRecord
    var onAdd: (String?, Int, [String: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var load: String
    @State private var reps = 5
    @State private var rpe = ""

    init(lift: LiftRecord, onAdd: @escaping (String?, Int, [String: String]) -> Void) {
        self.lift = lift
        self.onAdd = onAdd
        _load = State(initialValue: lift.weight ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Missed set") {
                    TextField("Load", text: $load)
                    Stepper("Reps: \(reps)", value: $reps, in: 1...100)
                    TextField("RPE (optional)", text: $rpe)
                        .keyboardType(.decimalPad)
                }
                Section {
                    Text("This changes the historical record only. Progression is not recalculated.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Set")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let metrics = rpe.isEmpty ? [:] : ["rpe": rpe]
                        onAdd(load.isEmpty ? nil : load, reps, metrics)
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ContinueWorkoutView: View {
    let record: TrainingRecord

    @Environment(AppModel.self) private var app
    @State private var phase: Phase = .loading

    private enum Phase {
        case loading
        case loaded(RenderedSession)
        case failed(String)
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Loading workout…")
            case .loaded(let session):
                if let repo = app.activeRepo {
                    ActiveWorkoutView(repo: repo, session: session, restoring: record)
                } else {
                    ContentUnavailableView("No Repository", systemImage: "folder.badge.questionmark")
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't continue", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard case .loading = phase else { return }
        guard let repo = app.activeRepo else {
            phase = .failed("Connect a repository before continuing a workout.")
            return
        }
        guard let sessionId = record.sessionId else {
            phase = .failed("This record does not include a session id.")
            return
        }

        do {
            phase = .loaded(try await app.engine.renderSession(dir: repo.url, sessionId: sessionId))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

private struct HistoryLiftRow: View {
    let lift: LiftRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                if let weight = lift.weight {
                    Text(weight)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if !lift.sets.isEmpty {
                Label(lift.sets.map(String.init).joined(separator: " / "), systemImage: "repeat")
                    .font(.callout.monospaced())
            }

            if !lift.metrics.isEmpty {
                Text(metrics)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let note = lift.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var title: String {
        lift.exercise.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var metrics: String {
        lift.metrics
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: " · ")
    }
}
