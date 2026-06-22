import Foundation

struct RepoManager: Sendable {
    func reposRoot() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = base.appending(path: "Knurled/repos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func workingDirectory(for slug: String) throws -> URL {
        try reposRoot().appending(path: slug, directoryHint: .isDirectory)
    }

    @discardableResult
    func ensureSampleRepo() throws -> URL {
        let destination = try workingDirectory(for: "sample-gzclp")
        if !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            guard let source = SampleRepo.bundledURL else { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return destination
    }
}
