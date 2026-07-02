import Foundation

/// Where a training repo's working copy lives. iCloud Drive is the primary home so training
/// data follows the user's Apple account across devices; local Application Support is the
/// fallback when iCloud is signed out or disabled for Knurled.
enum RepoStorageLocation: String, Codable, Sendable {
    case iCloud
    case local

    var title: String {
        switch self {
        case .iCloud: return "iCloud Drive"
        case .local: return "This device"
        }
    }
}

/// Owns the on-disk homes for training repo working copies.
///
/// A training repo is a plain file tree, so iCloud integration is iCloud Drive documents:
/// new repos are created inside the app's default ubiquity container (browsable in the Files
/// app), and repos created while iCloud was unavailable move there the first time it appears.
/// The working copy here is the source of truth the engine reads and writes — GitHub is only
/// an optional backup remote layered on top.
actor RepoManager {
    /// Test hook: when set, repos live under this directory and iCloud is never consulted.
    private let rootOverride: URL?
    /// Resolving the ubiquity container can block on first access, so it must happen off the
    /// main actor and only once per launch; the cache also remembers "unavailable".
    private var cachedICloudDocuments: URL??

    init(rootOverride: URL? = nil) {
        self.rootOverride = rootOverride
    }

    /// Where new repos are created: iCloud Drive when available, local otherwise.
    func storageLocation() -> RepoStorageLocation {
        iCloudRepoRoot() == nil ? .local : .iCloud
    }

    /// The directory a new repo working copy for `slug` should live in. Prefers an existing
    /// working copy in either storage so reconnect flows find what's already on disk.
    func workingDirectory(for slug: String) throws -> URL {
        if let existing = existingWorkingDirectory(for: slug) { return existing }
        return try primaryRoot().appending(path: slug, directoryHint: .isDirectory)
    }

    /// Finds an existing working copy by slug, checking iCloud first, then local storage.
    /// Kicks off an iCloud download for repos evicted from this device before returning.
    func existingWorkingDirectory(for slug: String) -> URL? {
        for root in [iCloudRepoRoot(), try? localRepoRoot()].compactMap({ $0 }) {
            let dir = root.appending(path: slug, directoryHint: .isDirectory)
            if FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) {
                ensureDownloaded(at: dir)
                return dir
            }
        }
        return nil
    }

    /// A directory for a brand-new repo, unique-ified against both storages so onboarding can
    /// never clobber an existing working copy.
    func newWorkingDirectory(preferredSlug: String) throws -> URL {
        let root = try primaryRoot()
        var slug = preferredSlug
        var attempt = 1
        while existingWorkingDirectory(for: slug) != nil {
            attempt += 1
            slug = "\(preferredSlug)-\(attempt)"
        }
        return root.appending(path: slug, directoryHint: .isDirectory)
    }

    /// Moves repos created while iCloud was unavailable into the ubiquity container so the
    /// primary copy always lives in iCloud once the user has it enabled. Safe to call every
    /// launch: it is a no-op without iCloud, and repos whose name already exists in iCloud
    /// stay local rather than risk overwriting.
    func migrateLocalReposToICloud() {
        guard let iCloudRoot = iCloudRepoRoot(), let localRoot = try? localRepoRoot() else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: localRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for dir in contents {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let destination = iCloudRoot.appending(path: dir.lastPathComponent, directoryHint: .isDirectory)
            guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else { continue }
            try? FileManager.default.setUbiquitous(true, itemAt: dir, destinationURL: destination)
        }
    }

    /// Deletes the bundled sample working copy older builds seeded on first launch. New users
    /// go through onboarding instead, so a leftover sample must not shadow a real repo slug.
    func removeLegacySampleRepo() {
        guard let localRoot = try? localRepoRoot() else { return }
        let sample = localRoot.appending(path: "sample-gzclp", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: sample)
    }

    // MARK: - Roots

    private func primaryRoot() throws -> URL {
        if let iCloud = iCloudRepoRoot() { return iCloud }
        return try localRepoRoot()
    }

    private func localRepoRoot() throws -> URL {
        let base: URL
        if let rootOverride {
            base = rootOverride
        } else {
            base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ).appending(path: "Knurled", directoryHint: .isDirectory)
        }
        let root = base.appending(path: "repos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func iCloudRepoRoot() -> URL? {
        guard let documents = iCloudDocuments() else { return nil }
        let root = documents.appending(path: "repos", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        return root
    }

    private func iCloudDocuments() -> URL? {
        if rootOverride != nil { return nil }
        if let cached = cachedICloudDocuments { return cached }
        var documents: URL?
        if FileManager.default.ubiquityIdentityToken != nil,
           let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            documents = container.appending(path: "Documents", directoryHint: .isDirectory)
        }
        cachedICloudDocuments = .some(documents)
        return documents
    }

    /// Best-effort request that every file in an iCloud working copy is materialized locally.
    /// iCloud can evict file contents under disk pressure; the engine needs real bytes.
    private func ensureDownloaded(at dir: URL) {
        guard FileManager.default.isUbiquitousItem(at: dir) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: dir)
        if let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator where FileManager.default.isUbiquitousItem(at: url) {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        }
    }
}
