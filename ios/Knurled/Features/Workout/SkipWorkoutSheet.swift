import SwiftUI

struct SkipWorkoutSheet: View {
    let repo: ActiveRepo
    let session: RenderedSession

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var reason = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Skip **\(session.displayName)** and move forward to the next workout in the rotation. The skip is recorded in your history — nothing is lost.")
                        .font(.subheadline)
                }

                Section("Reason (optional)") {
                    TextField("e.g. travel, illness, rest day", text: $reason, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section {
                    Button(role: .destructive) {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Label("Skip & move forward", systemImage: "forward.end.fill")
                            }
                            Spacer()
                        }
                    }
                    .disabled(isSubmitting)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red).font(.footnote)
                    }
                }
            }
            .navigationTitle("Skip Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func submit() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await app.skip(session: session, in: repo, reason: reason)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
