import Foundation

struct DiscoveryFailure: Sendable, Equatable {
    enum Operation: Sendable, Equatable {
        case enumerateDirectory
        case inspectItem
    }

    let location: URL
    let operation: Operation
}

struct DiscoveryResult<Element: Sendable>: Sendable {
    let files: [Element]
    let failures: [DiscoveryFailure]

    var isComplete: Bool {
        failures.isEmpty
    }
}

struct FileDiscovery {
    enum SubagentKind: String, Sendable, Equatable {
        case legacy
        case workflow
    }

    struct DiscoveredFile: Sendable {
        let url: URL
        let sessionId: String
        let projectPath: String
        let isSubagent: Bool
        let subagentKind: SubagentKind?
        let subagentParentSessionId: String?
        let workflowRunId: String?
        let agentId: String?
    }

    var baseDirectory: URL {
        if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            return URL(fileURLWithPath: configDir)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
    }

    var projectsDirectory: URL {
        baseDirectory.appendingPathComponent("projects")
    }

    func discoverJSONLFiles() -> [DiscoveredFile] {
        discoverJSONLFilesWithDiagnostics().files
    }

    func discoverJSONLFiles(in projectsDir: URL) -> [DiscoveredFile] {
        discoverJSONLFilesWithDiagnostics(in: projectsDir).files
    }

    func discoverJSONLFilesWithDiagnostics() -> DiscoveryResult<DiscoveredFile> {
        discoverJSONLFilesWithDiagnostics(in: projectsDirectory)
    }

    func discoverJSONLFilesWithDiagnostics(
        in projectsDir: URL
    ) -> DiscoveryResult<DiscoveredFile> {
        let fm = FileManager.default
        let projectDirs: [URL]
        do {
            projectDirs = try fm.contentsOfDirectory(
                at: projectsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )
        } catch {
            return DiscoveryResult(
                files: [],
                failures: [DiscoveryFailure(
                    location: projectsDir.standardizedFileURL,
                    operation: .enumerateDirectory
                )]
            )
        }

        var results: [DiscoveredFile] = []
        var failures: [DiscoveryFailure] = []
        for projectDir in projectDirs {
            let values: URLResourceValues
            do {
                values = try projectDir.resourceValues(forKeys: [.isDirectoryKey])
            } catch {
                failures.append(DiscoveryFailure(
                    location: projectDir.standardizedFileURL,
                    operation: .inspectItem
                ))
                continue
            }
            guard values.isDirectory == true else { continue }
            let projectName = projectDir.lastPathComponent
            scan(
                directory: projectDir,
                projectName: projectName,
                isSubagent: false,
                into: &results,
                failures: &failures,
                fm: fm
            )
        }
        return DiscoveryResult(files: results, failures: failures)
    }

    /// Real Claude Code layout (Apr 2026):
    ///
    /// ```
    /// <project>/                    ← scan starts here
    ///   <sessionId>.jsonl           ← parent session
    ///   <sessionId>/                ← per-session companion dir
    ///     subagents/                ← sub-agent JSONLs live here
    ///       agent-<id>.jsonl
    ///       agent-<id>.meta.json    ← skipped (not .jsonl)
    ///       workflows/<runId>/      ← Claude Code dynamic workflows
    ///         agent-<id>.jsonl
    /// ```
    ///
    /// Two cases must be discovered:
    /// 1. Direct child `subagents/` of the project (legacy layout, kept for
    ///    test fixture compatibility).
    /// 2. Nested `<project>/<sessionId>/subagents/` (real layout — without
    ///    this branch, sub-agents are silently dropped and Reports / menu
    ///    bar under-report cost by the Plan-9 ratio).
    ///
    /// Other directories (e.g. unrelated cache folders) are not recursed —
    /// we strictly look for the `subagents` segment.
    private func scan(
        directory: URL, projectName: String, isSubagent: Bool,
        subagentKind: SubagentKind? = nil,
        subagentParentSessionId: String? = nil,
        workflowRunId: String? = nil,
        into results: inout [DiscoveredFile],
        failures: inout [DiscoveryFailure],
        fm: FileManager
    ) {
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )
        } catch {
            failures.append(DiscoveryFailure(
                location: directory.standardizedFileURL,
                operation: .enumerateDirectory
            ))
            return
        }

        for item in contents {
            let values: URLResourceValues
            do {
                values = try item.resourceValues(forKeys: [.isDirectoryKey])
            } catch {
                failures.append(DiscoveryFailure(
                    location: item.standardizedFileURL,
                    operation: .inspectItem
                ))
                continue
            }
            if values.isDirectory == true {
                if item.lastPathComponent == "subagents" {
                    scan(
                        directory: item,
                        projectName: projectName,
                        isSubagent: true,
                        subagentKind: .legacy,
                        into: &results,
                        failures: &failures,
                        fm: fm
                    )
                } else if isSubagent,
                          subagentKind == .legacy,
                          item.lastPathComponent == "workflows" {
                    scanWorkflowDirectories(
                        workflowsDirectory: item,
                        projectName: projectName,
                        parentSessionId: subagentParentSessionId,
                        into: &results,
                        failures: &failures,
                        fm: fm
                    )
                } else if !isSubagent {
                    // Nested case: <project>/<sessionId>/subagents/. Peek
                    // one level deep for a `subagents/` child without a
                    // full recursive walk so we never accidentally ingest
                    // unrelated nested directories. Only enabled at the
                    // project level (isSubagent == false) so we don't
                    // recurse infinitely from inside subagents/ itself.
                    let nested = item.appendingPathComponent("subagents")
                    do {
                        let nestedValues = try nested.resourceValues(forKeys: [.isDirectoryKey])
                        if nestedValues.isDirectory == true {
                            scan(
                                directory: nested,
                                projectName: projectName,
                                isSubagent: true,
                                subagentKind: .legacy,
                                subagentParentSessionId: item.lastPathComponent,
                                into: &results,
                                failures: &failures,
                                fm: fm
                            )
                        }
                    } catch {
                        if !Self.isMissingPathError(error) {
                            failures.append(DiscoveryFailure(
                                location: nested.standardizedFileURL,
                                operation: .inspectItem
                            ))
                        }
                    }
                }
            } else if item.pathExtension == "jsonl" {
                guard !Self.isNonTranscriptWorkflowJSONL(item) else { continue }
                let sessionId = item.deletingPathExtension().lastPathComponent
                let agentId = Self.agentId(fromSessionId: sessionId)
                if subagentKind == .workflow, agentId == nil {
                    continue
                }
                results.append(DiscoveredFile(
                    url: item,
                    sessionId: sessionId,
                    projectPath: projectName,
                    isSubagent: isSubagent,
                    subagentKind: subagentKind,
                    subagentParentSessionId: subagentParentSessionId,
                    workflowRunId: workflowRunId,
                    agentId: agentId
                ))
            }
        }
    }

    private func scanWorkflowDirectories(
        workflowsDirectory: URL,
        projectName: String,
        parentSessionId: String?,
        into results: inout [DiscoveredFile],
        failures: inout [DiscoveryFailure],
        fm: FileManager
    ) {
        let runs: [URL]
        do {
            runs = try fm.contentsOfDirectory(
                at: workflowsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )
        } catch {
            failures.append(DiscoveryFailure(
                location: workflowsDirectory.standardizedFileURL,
                operation: .enumerateDirectory
            ))
            return
        }

        for runDir in runs {
            let values: URLResourceValues
            do {
                values = try runDir.resourceValues(forKeys: [.isDirectoryKey])
            } catch {
                failures.append(DiscoveryFailure(
                    location: runDir.standardizedFileURL,
                    operation: .inspectItem
                ))
                continue
            }
            guard values.isDirectory == true else {
                continue
            }
            let runId = runDir.lastPathComponent
            scan(
                directory: runDir,
                projectName: projectName,
                isSubagent: true,
                subagentKind: .workflow,
                subagentParentSessionId: parentSessionId,
                workflowRunId: runId,
                into: &results,
                failures: &failures,
                fm: fm
            )
        }
    }

    private static func agentId(fromSessionId sessionId: String) -> String? {
        let prefix = "agent-"
        guard sessionId.hasPrefix(prefix) else { return nil }
        let id = String(sessionId.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }

    static func isNonTranscriptWorkflowJSONL(_ url: URL) -> Bool {
        guard url.pathExtension == "jsonl",
              isInsideWorkflowSubagentDirectory(url) else {
            return false
        }
        let sessionId = url.deletingPathExtension().lastPathComponent
        return agentId(fromSessionId: sessionId) == nil
    }

    private static func isInsideWorkflowSubagentDirectory(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 4 else { return false }
        for index in 0..<(components.count - 1) {
            if components[index] == "subagents",
               components[index + 1] == "workflows" {
                return true
            }
        }
        return false
    }

    private static func isMissingPathError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           (nsError.code == CocoaError.Code.fileNoSuchFile.rawValue
            || nsError.code == CocoaError.Code.fileReadNoSuchFile.rawValue) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           nsError.code == Int(POSIXErrorCode.ENOENT.rawValue) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isMissingPathError(underlying)
        }
        return false
    }
}
