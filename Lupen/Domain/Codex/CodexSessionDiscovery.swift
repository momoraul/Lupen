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
        discoverRolloutFilesWithDiagnostics().files
    }

    func discoverRolloutFiles(in directory: URL) -> [URL] {
        discoverRolloutFilesWithDiagnostics(in: directory).files
    }

    func discoverRolloutFilesWithDiagnostics() -> DiscoveryResult<URL> {
        discoverRolloutFilesWithDiagnostics(in: sessionsDirectory)
    }

    func discoverRolloutFilesWithDiagnostics(
        in directory: URL
    ) -> DiscoveryResult<URL> {
        var failures: [DiscoveryFailure] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { location, error in
                // A missing `sessions/` dir (Codex never run yet) is an empty,
                // COMPLETE scan, not a failure — mirror FileDiscovery.
                FileDiscovery.record(error, location: location, operation: .enumerateDirectory, into: &failures)
                return true
            }
        ) else {
            if failures.isEmpty {
                failures.append(DiscoveryFailure(
                    location: directory.standardizedFileURL,
                    operation: .enumerateDirectory
                ))
            }
            return DiscoveryResult(files: [], failures: failures)
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard isCodexRolloutFile(url) else { continue }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [.isRegularFileKey])
            } catch {
                FileDiscovery.record(error, location: url, operation: .inspectItem, into: &failures)
                continue
            }
            guard values.isRegularFile == true else { continue }
            results.append(url)
        }
        return DiscoveryResult(
            files: results.sorted { $0.path < $1.path },
            failures: failures
        )
    }

    private func isCodexRolloutFile(_ url: URL) -> Bool {
        url.pathExtension == "jsonl" &&
        url.deletingPathExtension().lastPathComponent.hasPrefix("rollout-")
    }
}
