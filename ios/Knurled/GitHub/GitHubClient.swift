import Foundation

struct GitHubClient: Sendable {
    let token: String

    func currentUser() async throws -> GitHubUser {
        try await get("/user")
    }

    func repositories() async throws -> [GitHubRepo] {
        try await get("/user/repos?per_page=100&sort=updated")
    }

    func createRepository(name: String, isPrivate: Bool) async throws -> GitHubRepo {
        let body = try GitHub.encoder().encode(
            GitHubCreateRepoRequest(
                name: name,
                description: "Knurled training log and generated workout state",
                private: isPrivate,
                autoInit: false
            )
        )
        let data = try await send("POST", "/user/repos", body: body)
        return try GitHub.decoder().decode(GitHubRepo.self, from: data)
    }

    /// Downloads every file of `owner/repo@branch` into `dir`, returning the head commit sha.
    @discardableResult
    func pull(owner: String, repo: String, branch: String, into dir: URL) async throws -> String {
        let ref: GitHubRef = try await get("/repos/\(owner)/\(repo)/git/ref/heads/\(branch)")
        let commitSha = ref.object.sha
        let commit: GitHubCommitObject = try await get("/repos/\(owner)/\(repo)/git/commits/\(commitSha)")
        let tree: GitHubTree = try await get("/repos/\(owner)/\(repo)/git/trees/\(commit.tree.sha)?recursive=1")

        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in tree.tree where entry.type == "blob" {
            let blob: GitHubBlob = try await get("/repos/\(owner)/\(repo)/git/blobs/\(entry.sha)")
            let fileURL = dir.appending(path: entry.path)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let cleaned = blob.content.replacingOccurrences(of: "\n", with: "")
            let data = Data(base64Encoded: cleaned) ?? Data()
            try data.write(to: fileURL)
        }
        return commitSha
    }

    /// Creates a single commit touching `files` (paths relative to `dir`) on top of `baseCommit`.
    @discardableResult
    func commit(
        owner: String,
        repo: String,
        branch: String,
        baseCommit: String,
        files: [String],
        dir: URL,
        message: String
    ) async throws -> String {
        let base: GitHubCommitObject = try await get("/repos/\(owner)/\(repo)/git/commits/\(baseCommit)")

        var entries: [[String: Any]] = []
        for path in files {
            let fileURL = dir.appending(path: path)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let blobSha = try await createBlob(owner: owner, repo: repo, content: data)
            entries.append(["path": path, "mode": "100644", "type": "blob", "sha": blobSha])
        }

        let treeBody = try JSONSerialization.data(
            withJSONObject: ["base_tree": base.tree.sha, "tree": entries]
        )
        let treeSha = try await post("/repos/\(owner)/\(repo)/git/trees", body: treeBody).sha

        let commitBody = try JSONSerialization.data(
            withJSONObject: ["message": message, "tree": treeSha, "parents": [baseCommit]]
        )
        let newCommit = try await post("/repos/\(owner)/\(repo)/git/commits", body: commitBody).sha

        let refBody = try JSONSerialization.data(withJSONObject: ["sha": newCommit, "force": false])
        _ = try await send("PATCH", "/repos/\(owner)/\(repo)/git/refs/heads/\(branch)", body: refBody)
        return newCommit
    }

    @discardableResult
    func commitInitial(
        owner: String,
        repo: String,
        branch: String,
        files: [String],
        dir: URL,
        message: String
    ) async throws -> String {
        var entries: [[String: Any]] = []
        for path in files {
            let fileURL = dir.appending(path: path)
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            let blobSha = try await createBlob(owner: owner, repo: repo, content: data)
            entries.append(["path": path, "mode": "100644", "type": "blob", "sha": blobSha])
        }

        let treeBody = try JSONSerialization.data(withJSONObject: ["tree": entries])
        let treeSha = try await post("/repos/\(owner)/\(repo)/git/trees", body: treeBody).sha

        let commitBody = try JSONSerialization.data(
            withJSONObject: ["message": message, "tree": treeSha, "parents": []]
        )
        let newCommit = try await post("/repos/\(owner)/\(repo)/git/commits", body: commitBody).sha

        let refBody = try JSONSerialization.data(
            withJSONObject: ["ref": "refs/heads/\(branch)", "sha": newCommit]
        )
        _ = try await send("POST", "/repos/\(owner)/\(repo)/git/refs", body: refBody)
        return newCommit
    }

    // MARK: - Plumbing

    private func createBlob(owner: String, repo: String, content: Data) async throws -> String {
        let body = try JSONSerialization.data(
            withJSONObject: ["content": content.base64EncodedString(), "encoding": "base64"]
        )
        return try await post("/repos/\(owner)/\(repo)/git/blobs", body: body).sha
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send("GET", path, body: nil)
        return try GitHub.decoder().decode(T.self, from: data)
    }

    private func post(_ path: String, body: Data) async throws -> ShaResponse {
        let data = try await send("POST", path, body: body)
        return try GitHub.decoder().decode(ShaResponse.self, from: data)
    }

    @discardableResult
    private func send(_ method: String, _ path: String, body: Data?) async throws -> Data {
        guard let url = URL(string: "https://api.github.com" + path) else {
            throw GitHubError.badResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        GitHub.applyCommonHeaders(to: &request)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GitHubError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}
