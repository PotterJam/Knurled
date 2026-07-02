import Foundation

/// The bundled GZCLP fixture repo. Test-support only: the app no longer boots into a sample
/// plan (new users go through onboarding), but the unit tests still exercise the engine
/// against this known-good repository.
enum SampleRepo {
    static var bundledURL: URL? {
        Bundle.main.resourceURL?.appending(path: "Fixtures/gzclp-repo", directoryHint: .isDirectory)
    }

    static func makeWorkingCopy() throws -> URL {
        guard let source = bundledURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "knurled-sample-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
