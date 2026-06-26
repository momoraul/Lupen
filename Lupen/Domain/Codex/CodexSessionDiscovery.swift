import Foundation

struct CodexSessionDiscovery: Sendable {
    let codexHomeOverride: URL?

    init(codexHome: URL? = nil) {
        self.codexHomeOverride = codexHome
    }

    var codexHome: URL {
        if let codexHomeOverride {
            return codexHomeOverride
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            // Expand `~` and standardize so this matches the root that
            // KnownSourceLocations derives for the same CODEX_HOME — otherwise
            // a tilde'd value would make the built-in and the auto-detected
            // Codex source point at differently-spelled paths and dodge the
            // registry's root-dedup. A no-op for an already-absolute value.
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    var sessionsDirectory: URL {
        codexHome.appendingPathComponent("sessions")
    }

    func discoverRolloutFiles() -> [URL] {
        discoverRolloutFiles(in: sessionsDirectory)
    }

    func discoverRolloutFiles(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard isCodexRolloutFile(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }

    private func isCodexRolloutFile(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" &&
        url.deletingPathExtension().lastPathComponent.hasPrefix("rollout-")
    }
}
