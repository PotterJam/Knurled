import Foundation

struct LogReader: Sendable {
    func records(dir: URL) -> [DayRecord] {
        let logsDir = dir.appending(path: "logs", directoryHint: .isDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: logsDir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let decoder = KnurledCoding.decoder()
        var records: [DayRecord] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let month = try? decoder.decode(LogMonth.self, from: data)
            else { continue }
            records.append(contentsOf: month.days)
        }
        return records.sorted { $0.date < $1.date }
    }

    func upsert(day: DayRecord, dir: URL) throws {
        let monthFile = try Self.monthFile(for: day.date, dir: dir)
        try FileManager.default.createDirectory(
            at: monthFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let decoder = KnurledCoding.decoder()
        let month = String(day.date.prefix(7))
        var logMonth: LogMonth
        if let data = try? Data(contentsOf: monthFile),
           let existing = try? decoder.decode(LogMonth.self, from: data) {
            logMonth = existing
        } else {
            logMonth = LogMonth(month: month)
        }

        logMonth.upsert(day: day)
        var data = try KnurledCoding.encoder(pretty: true).encode(logMonth)
        data.append(0x0A)
        try data.write(to: monthFile, options: .atomic)
    }

    static func monthFile(for date: String, dir: URL) throws -> URL {
        let (year, month) = try yearMonth(from: date)
        return dir
            .appending(path: "logs", directoryHint: .isDirectory)
            .appending(path: year, directoryHint: .isDirectory)
            .appending(path: "\(month).json")
    }

    static func yearMonth(from date: String) throws -> (year: String, month: String) {
        let parts = date.split(separator: "-")
        guard parts.count >= 3, parts[0].count == 4, parts[1].count == 2, parts[2].count >= 2 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (String(parts[0]), String(parts[1]))
    }
}
