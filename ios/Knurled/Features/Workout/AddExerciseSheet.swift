import SwiftUI

struct AddExerciseSheet: View {
    let repo: ActiveRepo
    let catalog: [ExerciseCatalogEntry]
    var onAdd: (String, String?, Int, Int) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var selected: ExerciseCatalogEntry?
    @State private var loadText = ""
    @State private var setCount = 3
    @State private var reps = 10

    private var repoExercises: [ExerciseCatalogEntry] {
        (repo.plan?.exercises ?? [:])
            .map { id, exercise in
                ExerciseCatalogEntry(
                    id: id,
                    label: exercise.label,
                    pattern: exercise.pattern ?? "custom",
                    implement: exercise.implement,
                    custom: true
                )
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
    }

    private var allExercises: [ExerciseCatalogEntry] {
        var seen = Set<String>()
        return (repoExercises + catalog).filter { entry in
            seen.insert(entry.id).inserted
        }
    }

    private var normalizedSearch: String {
        LiveItem.normalized(search)
    }

    private var matches: [ExerciseCatalogEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Array(allExercises.prefix(24)) }
        return allExercises
            .filter {
                $0.label.localizedCaseInsensitiveContains(query)
                    || $0.id.localizedCaseInsensitiveContains(normalizedSearch)
            }
            .prefix(24)
            .map { $0 }
    }

    private var exactMatch: ExerciseCatalogEntry? {
        allExercises.first {
            $0.id == normalizedSearch || $0.label.caseInsensitiveCompare(search) == .orderedSame
        }
    }

    private var canAdd: Bool {
        selected != nil || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Exercise") {
                    TextField("Search or create", text: $search)
                        .textInputAutocapitalization(.words)
                    ForEach(matches) { exercise in
                        Button {
                            selected = exercise
                            search = exercise.label
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(exercise.label)
                                    Text(exercise.pattern)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected?.id == exercise.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    if exactMatch == nil && !normalizedSearch.isEmpty {
                        Button {
                            selected = ExerciseCatalogEntry(
                                id: normalizedSearch,
                                label: Self.titleCase(normalizedSearch),
                                pattern: "custom",
                                custom: true
                            )
                        } label: {
                            Label("Create \"\(Self.titleCase(normalizedSearch))\"", systemImage: "plus.circle")
                        }
                    }
                }

                Section("Sets") {
                    TextField("Load", text: $loadText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Stepper("\(setCount) sets", value: $setCount, in: 1...20)
                    Stepper("\(reps) reps", value: $reps, in: 0...99)
                }
            }
            .navigationTitle("Add Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        add()
                        dismiss()
                    }
                    .disabled(!canAdd)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        let exercise = selected ?? ExerciseCatalogEntry(
            id: normalizedSearch,
            label: Self.titleCase(normalizedSearch),
            pattern: "custom",
            custom: true
        )
        if exercise.custom || exactMatch == nil {
            try? ExercisePlanWriter.upsertCustomExercise(exercise, in: repo.url)
        }
        let trimmedLoad = loadText.trimmingCharacters(in: .whitespacesAndNewlines)
        onAdd(exercise.id, trimmedLoad.isEmpty ? nil : trimmedLoad, setCount, reps)
    }

    private static func titleCase(_ id: String) -> String {
        id.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

enum ExercisePlanWriter {
    static func upsertCustomExercise(_ exercise: ExerciseCatalogEntry, in repoURL: URL) throws {
        let url = repoURL.appending(path: "plan.fitspec")
        var text = try String(contentsOf: url, encoding: .utf8)
        let entry = "    \(exercise.id) { label \"\(escape(exercise.label))\"; pattern \(exercise.pattern); implement \(exercise.implement ?? "custom") }\n"

        if let range = entryRange(for: exercise.id, in: text) {
            text.replaceSubrange(range, with: entry.trimmingCharacters(in: .newlines))
            try text.write(to: url, atomically: true, encoding: .utf8)
            return
        }

        if let block = text.range(of: "exercises {"),
           let insertIndex = closingBraceIndex(in: text, from: block.upperBound) {
            text.insert(contentsOf: entry, at: insertIndex)
        } else if let insertIndex = text.lastIndex(of: "}") {
            text.insert(contentsOf: "\n  exercises {\n\(entry)  }\n", at: insertIndex)
        } else {
            text.append("\n  exercises {\n\(entry)  }\n")
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func entryRange(for id: String, in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: "\n    \(id) ")?.lowerBound
            ?? text.range(of: "\n  \(id) ")?.lowerBound else { return nil }
        let contentStart = text.index(after: start)
        guard let lineEnd = text[contentStart...].firstIndex(of: "\n") else {
            return contentStart..<text.endIndex
        }
        return contentStart..<lineEnd
    }

    private static func closingBraceIndex(in text: String, from start: String.Index) -> String.Index? {
        var depth = 1
        var index = start
        while index < text.endIndex {
            let char = text[index]
            if char == "{" {
                depth += 1
            } else if char == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "\\\"")
    }
}
