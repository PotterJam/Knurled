import Foundation

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
