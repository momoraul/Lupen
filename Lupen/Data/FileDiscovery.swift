import Foundation

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
        discoverJSONLFiles(in: projectsDirectory)
    }

    func discoverJSONLFiles(in projectsDir: URL) -> [DiscoveredFile] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        var results: [DiscoveredFile] = []
        for projectDir in projectDirs {
            guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let projectName = projectDir.lastPathComponent
            scan(
                directory: projectDir,
                projectName: projectName,
                isSubagent: false,
                into: &results,
                fm: fm
            )
        }
        return results
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
        into results: inout [DiscoveredFile], fm: FileManager
    ) {
        guard let contents = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        ) else { return }

        for item in contents {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir {
                if item.lastPathComponent == "subagents" {
                    scan(
                        directory: item,
                        projectName: projectName,
                        isSubagent: true,
                        subagentKind: .legacy,
                        into: &results,
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
                    var isDirObjC: ObjCBool = false
                    if fm.fileExists(atPath: nested.path, isDirectory: &isDirObjC), isDirObjC.boolValue {
                        scan(
                            directory: nested,
                            projectName: projectName,
                            isSubagent: true,
                            subagentKind: .legacy,
                            subagentParentSessionId: item.lastPathComponent,
                            into: &results,
                            fm: fm
                        )
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
        fm: FileManager
    ) {
        guard let runs = try? fm.contentsOfDirectory(
            at: workflowsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return }

        for runDir in runs {
            guard (try? runDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
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
}
