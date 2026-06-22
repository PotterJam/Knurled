import Foundation

struct GeneratedFilesReader: Sendable {
    func nextWorkout(dir: URL) throws -> RenderedSession? {
        try readJSON("build/next-workout.json", as: RenderedSession.self, dir: dir)
    }

    func state(dir: URL) throws -> StateProjection? {
        try readJSON("state/current.json", as: StateProjection.self, dir: dir)
    }

    func validation(dir: URL) throws -> ValidationReport? {
        try readJSON("build/validation.json", as: ValidationReport.self, dir: dir)
    }

    private func readJSON<T: Decodable>(_ relativePath: String, as type: T.Type, dir: URL) throws -> T? {
        let url = dir.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try KnurledCoding.decoder().decode(T.self, from: data)
    }
}
