import Foundation

struct LogReader: Sendable {
    func events(dir: URL) -> [TrainingEvent] {
        let logsDir = dir.appending(path: "logs", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: logsDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = KnurledCoding.decoder()
        var events: [TrainingEvent] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                if let event = try? decoder.decode(TrainingEvent.self, from: Data(trimmed.utf8)) {
                    events.append(event)
                }
            }
        }
        return events
    }

    func appendEvent(line: String, dir: URL, timestamp: String) throws {
        let (year, month) = Self.yearMonth(from: timestamp)
        let monthFile = dir
            .appending(path: "logs", directoryHint: .isDirectory)
            .appending(path: year, directoryHint: .isDirectory)
            .appending(path: "\(month).jsonl")
        try FileManager.default.createDirectory(
            at: monthFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var contents = (try? String(contentsOf: monthFile, encoding: .utf8)) ?? ""
        if !contents.isEmpty && !contents.hasSuffix("\n") { contents += "\n" }
        contents += line
        contents += "\n"
        try contents.write(to: monthFile, atomically: true, encoding: .utf8)
    }

    static func yearMonth(from timestamp: String) -> (year: String, month: String) {
        let parts = timestamp.split(separator: "-")
        if parts.count >= 2, parts[0].count == 4 {
            return (String(parts[0]), String(parts[1]))
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let fallback = now.split(separator: "-")
        if fallback.count >= 2 { return (String(fallback[0]), String(fallback[1])) }
        return ("2026", "01")
    }
}
