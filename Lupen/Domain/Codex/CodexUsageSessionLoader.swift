import Foundation

enum CodexUsageCacheStatus: String, Codable, Equatable, Sendable {
    case miss
    case hit
    case partial
}

struct CodexLoadSummary: Equatable, Sendable {
    let discoveredFileCount: Int
    let parsedRolloutFileCount: Int
    let sessionCount: Int
    let rejectedMetadataFileCount: Int
    let tokenEventCount: Int
    let rejectedLineCount: Int
    let titleIndexRejectedLineCount: Int
    let skippedDuplicateCumulativeCount: Int
    let skippedForkReplayCount: Int
    let missingUsageCount: Int
    let unknownPricingCount: Int
    let cacheStatus: CodexUsageCacheStatus

    init(
        discoveredFileCount: Int,
        parsedRolloutFileCount: Int,
        sessionCount: Int,
        rejectedMetadataFileCount: Int = 0,
        tokenEventCount: Int,
        rejectedLineCount: Int,
        titleIndexRejectedLineCount: Int = 0,
        skippedDuplicateCumulativeCount: Int = 0,
        skippedForkReplayCount: Int = 0,
        missingUsageCount: Int = 0,
        unknownPricingCount: Int,
        cacheStatus: CodexUsageCacheStatus
    ) {
        self.discoveredFileCount = discoveredFileCount
        self.parsedRolloutFileCount = parsedRolloutFileCount
        self.sessionCount = sessionCount
        self.rejectedMetadataFileCount = rejectedMetadataFileCount
        self.tokenEventCount = tokenEventCount
        self.rejectedLineCount = rejectedLineCount
        self.titleIndexRejectedLineCount = titleIndexRejectedLineCount
        self.skippedDuplicateCumulativeCount = skippedDuplicateCumulativeCount
        self.skippedForkReplayCount = skippedForkReplayCount
        self.missingUsageCount = missingUsageCount
        self.unknownPricingCount = unknownPricingCount
        self.cacheStatus = cacheStatus
    }

    init(result: CodexUsageSessionLoadResult) {
        self.init(
            discoveredFileCount: result.discoveredFileCount,
            parsedRolloutFileCount: result.parsedRolloutFileCount,
            sessionCount: result.sessions.count,
            rejectedMetadataFileCount: result.rejectedMetadataFileCount,
            tokenEventCount: result.tokenEventCount,
            rejectedLineCount: result.rejectedLineCount,
            titleIndexRejectedLineCount: result.titleIndexRejectedLineCount,
            skippedDuplicateCumulativeCount: result.skippedDuplicateCumulativeCount,
            skippedForkReplayCount: result.skippedForkReplayCount,
            missingUsageCount: result.missingUsageCount,
            unknownPricingCount: result.unknownPricingCount,
            cacheStatus: result.cacheStatus
        )
    }
}

struct CodexUsageSourceStats: Codable, Equatable, Sendable {
    let rejectedLineCount: Int
    let tokenEventCount: Int
    let skippedDuplicateCumulativeCount: Int
    let skippedForkReplayCount: Int
    let missingUsageCount: Int

    init(
        rejectedLineCount: Int,
        tokenEventCount: Int,
        skippedDuplicateCumulativeCount: Int,
        skippedForkReplayCount: Int,
        missingUsageCount: Int
    ) {
        self.rejectedLineCount = rejectedLineCount
        self.tokenEventCount = tokenEventCount
        self.skippedDuplicateCumulativeCount = skippedDuplicateCumulativeCount
        self.skippedForkReplayCount = skippedForkReplayCount
        self.missingUsageCount = missingUsageCount
    }

    init(read: CodexLineReader.Result, aggregation: CodexUsageAggregation) {
        self.init(
            rejectedLineCount: read.rejectedLineCount,
            tokenEventCount: aggregation.tokenEventCount,
            skippedDuplicateCumulativeCount: aggregation.skippedDuplicateCumulativeCount,
            skippedForkReplayCount: aggregation.skippedForkReplayCount,
            missingUsageCount: aggregation.missingUsageCount + read.rejectedLineCount
        )
    }

    static let zero = CodexUsageSourceStats(
        rejectedLineCount: 0,
        tokenEventCount: 0,
        skippedDuplicateCumulativeCount: 0,
        skippedForkReplayCount: 0,
        missingUsageCount: 0
    )

    static func total<S: Sequence>(_ stats: S) -> CodexUsageSourceStats where S.Element == CodexUsageSourceStats {
        stats.reduce(.zero) { partial, stat in
            CodexUsageSourceStats(
                rejectedLineCount: partial.rejectedLineCount + stat.rejectedLineCount,
                tokenEventCount: partial.tokenEventCount + stat.tokenEventCount,
                skippedDuplicateCumulativeCount: partial.skippedDuplicateCumulativeCount + stat.skippedDuplicateCumulativeCount,
                skippedForkReplayCount: partial.skippedForkReplayCount + stat.skippedForkReplayCount,
                missingUsageCount: partial.missingUsageCount + stat.missingUsageCount
            )
        }
    }
}

struct CodexUsageSessionLoadResult: Equatable, Sendable {
    let codexHome: URL
    let sessions: [Session]
    let costsByRequestId: [String: CostBreakdown?]
    let turnsBySession: [String: [Turn]]
    let sourceFileBySessionId: [String: URL]
    let sourceLabelsByIdentity: [String: String]
    let rawPayloadByRequestId: [String: Data]
    let rawPayloadLocatorByRequestId: [String: RawPayloadLocator]
    let subAgentLinksBySessionId: [String: [SubAgentLinker.Link]]
    let discoveredFileCount: Int
    let parsedRolloutFileCount: Int
    let rejectedMetadataFileCount: Int
    let rejectedMetadataFilePaths: Set<String>
    let rejectedLineCount: Int
    let titleIndexRejectedLineCount: Int
    let tokenEventCount: Int
    let skippedDuplicateCumulativeCount: Int
    let skippedForkReplayCount: Int
    let missingUsageCount: Int
    let unknownPricingCount: Int
    let diagnosticBatches: [ParseDiagnosticsBatch]
    let sourceStatsByPath: [String: CodexUsageSourceStats]
    let cacheStatus: CodexUsageCacheStatus

    var loadedFromCache: Bool {
        cacheStatus != .miss
    }

    var summary: CodexLoadSummary {
        CodexLoadSummary(result: self)
    }
}

struct CodexUsageLoadProgress: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case scanningFiles
        case fullParse
        case incrementalParse
    }

    let phase: Phase
    let pendingFiles: Int
    let pendingBytes: UInt64
    let processedFiles: Int
    let processedBytes: UInt64

    var fraction: Double? {
        guard pendingBytes > 0 else { return nil }
        return min(1, max(0, Double(processedBytes) / Double(pendingBytes)))
    }
}

typealias CodexUsageLoadProgressHandler = @Sendable (CodexUsageLoadProgress) -> Void

enum CodexSourceDiscriminator {
    private static let sourceMarker = ":source:"
    private static let tokenMarker = ":token_count:"

    static func key(for url: URL) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.standardizedFileURL.path.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    static func requestId(_ requestId: String, sourceKey: String) -> String {
        guard let markerRange = requestId.range(of: tokenMarker),
              requestId[..<markerRange.lowerBound].range(of: sourceMarker, options: .backwards) == nil else {
            return requestId
        }
        return "\(requestId[..<markerRange.lowerBound])\(sourceMarker)\(sourceKey)\(requestId[markerRange.lowerBound...])"
    }

    static func requestSourceComponents(from requestId: String) -> (scopedSessionId: String, sourceKey: String?)? {
        guard let markerRange = requestId.range(of: tokenMarker) else { return nil }
        let prefix = String(requestId[..<markerRange.lowerBound])
        guard let sourceRange = prefix.range(of: sourceMarker, options: .backwards) else {
            return (prefix, nil)
        }
        let scopedSessionId = String(prefix[..<sourceRange.lowerBound])
        let sourceKey = String(prefix[sourceRange.upperBound...])
        guard !scopedSessionId.isEmpty, !sourceKey.isEmpty else {
            return (prefix, nil)
        }
        return (scopedSessionId, sourceKey)
    }

    static func sourceIdentityKey(scopedSessionId: String, sourceKey: String?) -> String {
        guard let sourceKey, !sourceKey.isEmpty else { return scopedSessionId }
        return "\(scopedSessionId)\(sourceMarker)\(sourceKey)"
    }

    static func sourceIdentityComponents(from identityKey: String) -> (scopedSessionId: String, sourceKey: String?) {
        guard let sourceRange = identityKey.range(of: sourceMarker, options: .backwards) else {
            return (identityKey, nil)
        }
        let scopedSessionId = String(identityKey[..<sourceRange.lowerBound])
        let sourceKey = String(identityKey[sourceRange.upperBound...])
        guard !scopedSessionId.isEmpty, !sourceKey.isEmpty else {
            return (identityKey, nil)
        }
        return (scopedSessionId, sourceKey)
    }

    static func requestSourceIdentityKey(from requestId: String) -> String? {
        guard let components = requestSourceComponents(from: requestId) else { return nil }
        return sourceIdentityKey(
            scopedSessionId: components.scopedSessionId,
            sourceKey: components.sourceKey
        )
    }
}

enum CodexUsageSessionLoader {
    // ReadSessionPiece / LoadedSessionPiece / MergedSessions and the
    // loadPieces → mergeSessionPieces pipeline are `internal` (not
    // private): the Phase 2 scoped importer (`CodexDetailImporter`)
    // reuses them per identity group so cumulative dedup, replay
    // trimming, source discriminators, and grafting can never drift
    // from the legacy full-load path while both exist. The canaried
    // provider-wide entry point remains `load(...)` only.
    struct ReadSessionPiece: Sendable {
        let metadata: CodexSessionMetadata
        let read: CodexLineReader.Result
    }

    struct LoadedSessionPiece: Sendable {
        let metadata: CodexSessionMetadata
        let read: CodexLineReader.Result
        let decodedLines: [CodexLineReader.DecodedLine]
        let initialPreviousTotal: CodexTokenUsage?
        let sourceDiscriminator: String?
        let aggregation: CodexUsageAggregation
    }

    struct MergedSessions: Sendable {
        let sessions: [Session]
        let costsByRequestId: [String: CostBreakdown?]
        let turnsBySession: [String: [Turn]]
        let sourceFileBySessionId: [String: URL]
        let sourceLabelsByIdentity: [String: String]
        let rawPayloadByRequestId: [String: Data]
        let rawPayloadLocatorByRequestId: [String: RawPayloadLocator]
        let subAgentLinksBySessionId: [String: [SubAgentLinker.Link]]
    }

    private struct AssembledSessionPiece {
        let piece: LoadedSessionPiece
        let turns: [Turn]
    }

    struct SameRawReplayTrim: Sendable {
        let decodedLines: [CodexLineReader.DecodedLine]
        let droppedLineCount: Int
    }

    static func load(
        codexHome: URL? = nil,
        progress: CodexUsageLoadProgressHandler? = nil
    ) -> CodexUsageSessionLoadResult {
        let discovery = CodexSessionDiscovery(codexHome: codexHome)
        let titleIndexURL = discovery.codexHome.appendingPathComponent("session_index.jsonl")
        let files = discovery.discoverRolloutFiles()
        progress?(CodexUsageLoadProgress(
            phase: .scanningFiles,
            pendingFiles: files.count,
            pendingBytes: 0,
            processedFiles: 0,
            processedBytes: 0
        ))

        let titleIndex = CodexSessionTitleIndexReader.read(
            from: titleIndexURL
        )
        let index = CodexSessionIndexBuilder.build(from: files, titleIndex: titleIndex)

        var readPieces: [ReadSessionPiece] = []
        var rejectedLineCount = 0
        var tokenEventCount = 0
        var skippedDuplicateCumulativeCount = 0
        var skippedForkReplayCount = 0
        var missingUsageCount = 0
        var diagnosticBatches: [ParseDiagnosticsBatch] = []
        var sourceStatsByPath: [String: CodexUsageSourceStats] = [:]
        let rejectedMetadataFilePaths = Set(index.rejectedFiles.map {
            $0.url.standardizedFileURL.path
        })
        let parseURLs = index.sessions.map(\.fileURL)
        let pendingBytes = totalByteCount(for: parseURLs)
        var processedFiles = 0
        var processedBytes: UInt64 = 0
        progress?(CodexUsageLoadProgress(
            phase: .fullParse,
            pendingFiles: index.sessions.count,
            pendingBytes: pendingBytes,
            processedFiles: 0,
            processedBytes: 0
        ))

        for metadata in index.sessions {
            let fileBytes = byteCount(of: metadata.fileURL)
            let read = CodexLineReader.readEntries(from: metadata.fileURL)
            readPieces.append(ReadSessionPiece(metadata: metadata, read: read))
            processedFiles += 1
            processedBytes = min(pendingBytes, processedBytes + fileBytes)
            progress?(CodexUsageLoadProgress(
                phase: .fullParse,
                pendingFiles: index.sessions.count,
                pendingBytes: pendingBytes,
                processedFiles: processedFiles,
                processedBytes: processedBytes
            ))
        }

        let pieces = loadPieces(from: readPieces)
        for piece in pieces {
            let read = piece.read
            let aggregation = piece.aggregation
            let diagnosticBatch = CodexLineDiagnostics.batch(
                fileURL: piece.metadata.fileURL,
                decodedLines: piece.decodedLines,
                rejectedLines: read.rejectedLines,
                usageRequests: aggregation.requests,
                skippedDuplicateCumulativeCount: aggregation.skippedDuplicateCumulativeCount,
                skippedForkReplayCount: aggregation.skippedForkReplayCount
            )
            if !diagnosticBatch.items.isEmpty {
                diagnosticBatches.append(diagnosticBatch)
            }

            rejectedLineCount += read.rejectedLineCount
            tokenEventCount += aggregation.tokenEventCount
            skippedDuplicateCumulativeCount += aggregation.skippedDuplicateCumulativeCount
            skippedForkReplayCount += aggregation.skippedForkReplayCount
            missingUsageCount += aggregation.missingUsageCount + read.rejectedLineCount
            sourceStatsByPath[piece.metadata.fileURL.standardizedFileURL.path] = CodexUsageSourceStats(
                read: read,
                aggregation: aggregation
            )
        }

        let merged = mergeSessionPieces(pieces, titleIndex: titleIndex)

        let result = CodexUsageSessionLoadResult(
            codexHome: discovery.codexHome,
            sessions: merged.sessions,
            costsByRequestId: merged.costsByRequestId,
            turnsBySession: merged.turnsBySession,
            sourceFileBySessionId: merged.sourceFileBySessionId,
            sourceLabelsByIdentity: merged.sourceLabelsByIdentity,
            rawPayloadByRequestId: [:],
            rawPayloadLocatorByRequestId: merged.rawPayloadLocatorByRequestId,
            subAgentLinksBySessionId: merged.subAgentLinksBySessionId,
            discoveredFileCount: files.count,
            parsedRolloutFileCount: index.sessions.count,
            rejectedMetadataFileCount: index.rejectedFiles.count,
            rejectedMetadataFilePaths: rejectedMetadataFilePaths,
            rejectedLineCount: rejectedLineCount,
            titleIndexRejectedLineCount: titleIndex.rejectedLineCount,
            tokenEventCount: tokenEventCount,
            skippedDuplicateCumulativeCount: skippedDuplicateCumulativeCount,
            skippedForkReplayCount: skippedForkReplayCount,
            missingUsageCount: missingUsageCount,
            unknownPricingCount: unknownPricingCount(for: merged.sessions),
            diagnosticBatches: diagnosticBatches,
            sourceStatsByPath: sourceStatsByPath,
            cacheStatus: .miss
        )
        return result
    }

    static func unknownPricingCount(for sessions: [Session]) -> Int {
        sessions.reduce(into: 0) { count, session in
            for request in session.requests {
                guard let model = request.model,
                      !PricingTable.isSyntheticModel(model),
                      PricingTable.rates(for: model) == nil else {
                    continue
                }
                count += 1
            }
        }
    }

    static func rawPayload(
        for requestId: String,
        sourceURL: URL,
        codexHome: URL? = nil
    ) -> Data? {
        guard let metadata = try? CodexSessionMetadataReader.readMetadata(from: sourceURL) else {
            return nil
        }
        let read = CodexLineReader.readEntries(from: sourceURL)
        let parentDecodedLines = parentDecodedLines(for: metadata, codexHome: codexHome, excluding: sourceURL)
        let trim = CodexSubagentReplayTrimmer.trim(
            read.decodedLines,
            metadata: metadata,
            parentDecodedLines: parentDecodedLines
        )
        let requestedSourceKey = CodexSourceDiscriminator
            .requestSourceComponents(from: requestId)?
            .sourceKey
        if let requestedSourceKey,
           CodexSourceDiscriminator.key(for: sourceURL) != requestedSourceKey {
            guard let matchedSourceURL = CodexSessionDiscovery(codexHome: codexHome)
                .discoverRolloutFiles()
                .first(where: { CodexSourceDiscriminator.key(for: $0) == requestedSourceKey }) else {
                return nil
            }
            return rawPayload(for: requestId, sourceURL: matchedSourceURL, codexHome: codexHome)
        }
        let sourceDiscriminator = requestedSourceKey
            ?? (duplicateRawSessionIds(
                in: CodexSessionDiscovery(codexHome: codexHome).discoverRolloutFiles()
            ).contains(metadata.id) ? CodexSourceDiscriminator.key(for: sourceURL) : nil)
        if sourceDiscriminator != nil,
           let groupedPayload = sameRawGroupedRawPayload(
            for: requestId,
            sourceURL: sourceURL,
            metadata: metadata,
            codexHome: codexHome
           ) {
            return groupedPayload
        }
        let aggregation = disambiguatedAggregation(
            CodexUsageAggregator.aggregate(
                metadata: metadata,
                decodedLines: trim.decodedLines,
                initialPreviousTotal: trim.initialPreviousTotal
            ),
            sourceDiscriminator: sourceDiscriminator
        )
        return aggregation.rawPayloadLocatorByRequestId[requestId]
            .flatMap(JSONLLineReader.readLine(at:))
    }

    private static func sameRawGroupedRawPayload(
        for requestId: String,
        sourceURL: URL,
        metadata: CodexSessionMetadata,
        codexHome: URL?
    ) -> Data? {
        let sourcePath = sourceURL.standardizedFileURL.path
        let includedRawSessionIds = Set([metadata.id, metadata.subagentParentRawSessionId].compactMap(\.self))
        let readPieces = CodexSessionDiscovery(codexHome: codexHome)
            .discoverRolloutFiles()
            .compactMap { url -> ReadSessionPiece? in
                guard let candidate = try? CodexSessionMetadataReader.readMetadata(from: url),
                      includedRawSessionIds.contains(candidate.id) else {
                    return nil
                }
                return ReadSessionPiece(
                    metadata: candidate,
                    read: CodexLineReader.readEntries(from: candidate.fileURL)
                )
            }
        guard readPieces.contains(where: {
            $0.metadata.fileURL.standardizedFileURL.path == sourcePath
        }) else {
            return nil
        }
        return loadPieces(from: readPieces)
            .first {
                $0.metadata.fileURL.standardizedFileURL.path == sourcePath
            }?
            .aggregation
            .rawPayloadLocatorByRequestId[requestId]
            .flatMap(JSONLLineReader.readLine(at:))
    }

    private static func disambiguatedAggregation(
        _ aggregation: CodexUsageAggregation,
        sourceDiscriminator: String?
    ) -> CodexUsageAggregation {
        guard let sourceDiscriminator else { return aggregation }

        let remappedRequests = aggregation.requests.map { request in
            request.withID(CodexSourceDiscriminator.requestId(request.id, sourceKey: sourceDiscriminator))
        }
        let idMap = Dictionary(
            uniqueKeysWithValues: zip(aggregation.requests.map(\.id), remappedRequests.map(\.id))
        )
        let remappedRawPayloads = aggregation.rawPayloadByRequestId.reduce(into: [String: Data]()) {
            result,
            element in
            result[idMap[element.key] ?? element.key] = element.value
        }
        let remappedRawLocators = aggregation.rawPayloadLocatorByRequestId.reduce(into: [String: RawPayloadLocator]()) {
            result,
            element in
            result[idMap[element.key] ?? element.key] = element.value
        }
        let session = Session(
            id: aggregation.session.id,
            provider: aggregation.session.provider,
            rawSessionId: aggregation.session.rawSessionId,
            requests: remappedRequests,
            projectPath: aggregation.session.projectPath,
            cachedTitle: aggregation.session.cachedTitle,
            customTitle: aggregation.session.customTitle
        )

        return CodexUsageAggregation(
            session: session,
            requests: remappedRequests,
            rawPayloadByRequestId: remappedRawPayloads,
            rawPayloadLocatorByRequestId: remappedRawLocators,
            tokenEventCount: aggregation.tokenEventCount,
            skippedDuplicateCumulativeCount: aggregation.skippedDuplicateCumulativeCount,
            skippedForkReplayCount: aggregation.skippedForkReplayCount,
            missingUsageCount: aggregation.missingUsageCount,
            unknownPricingCount: aggregation.unknownPricingCount
        )
    }

    private static func duplicateRawSessionIds(in urls: [URL]) -> Set<String> {
        let rawIds = urls.compactMap { url -> String? in
            try? CodexSessionMetadataReader.readMetadata(from: url).id
        }
        let counts = rawIds.reduce(into: [String: Int]()) { result, rawId in
            result[rawId, default: 0] += 1
        }
        return Set(counts.compactMap { rawId, count in
            count > 1 ? rawId : nil
        })
    }

    static func codexUsageAggregation(
        metadata: CodexSessionMetadata,
        decodedLines: [CodexLineReader.DecodedLine],
        initialPreviousTotal: CodexTokenUsage?,
        sourceDiscriminator: String?
    ) -> CodexUsageAggregation {
        disambiguatedAggregation(
            CodexUsageAggregator.aggregate(
                metadata: metadata,
                decodedLines: decodedLines,
                initialPreviousTotal: initialPreviousTotal
            ),
            sourceDiscriminator: sourceDiscriminator
        )
    }

    static func loadPieces(from readPieces: [ReadSessionPiece]) -> [LoadedSessionPiece] {
        let readPiecesByRawSessionId = Dictionary(grouping: readPieces, by: { $0.metadata.id })
        let duplicateRawSessionIds = Set(readPiecesByRawSessionId.compactMap { rawSessionId, pieces in
            pieces.count > 1 ? rawSessionId : nil
        })
        var loadedByPath: [String: LoadedSessionPiece] = [:]

        for (_, rawPieces) in readPiecesByRawSessionId {
            let orderedPieces = rawPieces.sorted(by: readPieceSort)
            let usesSourceDiscriminator = orderedPieces.count > 1
            var previousDecodedLines: [CodexLineReader.DecodedLine] = []
            var previousTotal: CodexTokenUsage?

            for piece in orderedPieces {
                let parentDecodedLines = piece.metadata.subagentParentRawSessionId
                    .flatMap { readPiecesByRawSessionId[$0]?.flatMap(\.read.decodedLines) }
                let trim = CodexSubagentReplayTrimmer.trim(
                    piece.read.decodedLines,
                    metadata: piece.metadata,
                    parentDecodedLines: parentDecodedLines
                )
                let sameRawTrim = usesSourceDiscriminator
                    ? trimSameRawReplay(trim.decodedLines, previousDecodedLines: previousDecodedLines)
                    : SameRawReplayTrim(decodedLines: trim.decodedLines, droppedLineCount: 0)
                let initialPreviousTotal = trim.initialPreviousTotal
                    ?? (usesSourceDiscriminator ? previousTotal : nil)
                let sourceDiscriminator = duplicateRawSessionIds.contains(piece.metadata.id)
                    ? CodexSourceDiscriminator.key(for: piece.metadata.fileURL)
                    : nil
                let aggregation = codexUsageAggregation(
                    metadata: piece.metadata,
                    decodedLines: sameRawTrim.decodedLines,
                    initialPreviousTotal: initialPreviousTotal,
                    sourceDiscriminator: sourceDiscriminator
                )
                let loaded = LoadedSessionPiece(
                    metadata: piece.metadata,
                    read: piece.read,
                    decodedLines: sameRawTrim.decodedLines,
                    initialPreviousTotal: initialPreviousTotal,
                    sourceDiscriminator: sourceDiscriminator,
                    aggregation: aggregation
                )
                loadedByPath[piece.metadata.fileURL.standardizedFileURL.path] = loaded

                previousDecodedLines.append(contentsOf: sameRawTrim.decodedLines)
                previousTotal = lastEffectiveTotal(
                    in: sameRawTrim.decodedLines,
                    initialPreviousTotal: initialPreviousTotal
                ) ?? previousTotal
            }
        }

        return readPieces.compactMap {
            loadedByPath[$0.metadata.fileURL.standardizedFileURL.path]
        }
    }

    private static func totalByteCount(for urls: [URL]) -> UInt64 {
        urls.reduce(UInt64(0)) { partial, url in
            partial + byteCount(of: url)
        }
    }

    private static func byteCount(of url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func readPieceSort(_ lhs: ReadSessionPiece, _ rhs: ReadSessionPiece) -> Bool {
        let lhsTime = lhs.metadata.createdAt ?? .distantPast
        let rhsTime = rhs.metadata.createdAt ?? .distantPast
        if lhsTime != rhsTime { return lhsTime < rhsTime }
        return lhs.metadata.fileURL.standardizedFileURL.path < rhs.metadata.fileURL.standardizedFileURL.path
    }

    /// Per-chain carry for same-raw replay trimming (plan 3.8a):
    /// replay-identity keys per usage mode plus that mode's running
    /// total, appended piece by piece. Appending kept lines with the
    /// carried totals is exactly the legacy recompute over the
    /// concatenated previous lines — the legacy entry point below
    /// builds one of these and delegates, so there is one
    /// implementation for both paths.
    struct SameRawReplayCarry {
        fileprivate var keysByMode: [[ReplayIdentity]] = [[], [], []]
        fileprivate var totalsByMode: [CodexTokenUsage?] = [nil, nil, nil]

        var isEmpty: Bool { keysByMode.allSatisfy(\.isEmpty) }

        init() {}
    }

    private static let sameRawReplayModes: [ReplayUsageMode] = [
        .effectiveCumulative, .lastPreferred, .delta
    ]

    static func appendSameRawReplayKeys(
        of lines: [CodexLineReader.DecodedLine],
        to carry: inout SameRawReplayCarry
    ) {
        for (modeIndex, mode) in sameRawReplayModes.enumerated() {
            var runningTotal = carry.totalsByMode[modeIndex]
            let identities = replayIdentities(in: lines, usageMode: mode, runningTotal: &runningTotal)
            carry.keysByMode[modeIndex].append(contentsOf: identities.map(\.key))
            carry.totalsByMode[modeIndex] = runningTotal
        }
    }

    static func trimSameRawReplay(
        _ decodedLines: [CodexLineReader.DecodedLine],
        carry: SameRawReplayCarry
    ) -> SameRawReplayTrim {
        guard !decodedLines.isEmpty, !carry.isEmpty else {
            return SameRawReplayTrim(decodedLines: decodedLines, droppedLineCount: 0)
        }
        func currentKeys(_ mode: ReplayUsageMode) -> [(index: Int, key: ReplayIdentity)] {
            var runningTotal: CodexTokenUsage?
            return replayIdentities(in: decodedLines, usageMode: mode, runningTotal: &runningTotal)
        }
        let previousEffectiveKeys = carry.keysByMode[0]
        let currentEffectiveKeys = currentKeys(.effectiveCumulative)
        guard !previousEffectiveKeys.isEmpty, !currentEffectiveKeys.isEmpty else {
            return SameRawReplayTrim(decodedLines: decodedLines, droppedLineCount: 0)
        }
        let match = sameRawReplayMatch(
            previousReplayKeys: previousEffectiveKeys,
            currentReplayKeys: currentEffectiveKeys
        ) ?? sameRawReplayMatch(
            previousReplayKeys: carry.keysByMode[1],
            currentReplayKeys: currentKeys(.lastPreferred)
        ) ?? sameRawReplayMatch(
            previousReplayKeys: carry.keysByMode[2],
            currentReplayKeys: currentKeys(.delta)
        )
        guard let match else {
            return SameRawReplayTrim(decodedLines: decodedLines, droppedLineCount: 0)
        }
        guard match.dropCount < decodedLines.count else {
            return SameRawReplayTrim(decodedLines: decodedLines, droppedLineCount: 0)
        }
        let keptPrelude = decodedLines[..<match.startIndex]
        let keptSuffix = decodedLines.dropFirst(match.dropCount)
        return SameRawReplayTrim(
            decodedLines: Array(keptPrelude) + Array(keptSuffix),
            droppedLineCount: match.dropCount - match.startIndex
        )
    }

    private static func trimSameRawReplay(
        _ decodedLines: [CodexLineReader.DecodedLine],
        previousDecodedLines: [CodexLineReader.DecodedLine]
    ) -> SameRawReplayTrim {
        guard !decodedLines.isEmpty, !previousDecodedLines.isEmpty else {
            return SameRawReplayTrim(decodedLines: decodedLines, droppedLineCount: 0)
        }
        var carry = SameRawReplayCarry()
        appendSameRawReplayKeys(of: previousDecodedLines, to: &carry)
        return trimSameRawReplay(decodedLines, carry: carry)
    }

    private struct SameRawReplayMatch {
        let startIndex: Int
        let dropCount: Int
    }

    private static func sameRawReplayMatch(
        previousReplayKeys: [ReplayIdentity],
        currentReplayKeys: [(index: Int, key: ReplayIdentity)]
    ) -> SameRawReplayMatch? {
        let matchStart = currentReplayKeys.firstIndex { !$0.key.isPrelude } ?? currentReplayKeys.startIndex
        guard matchStart < currentReplayKeys.endIndex else { return nil }
        if matchStart > currentReplayKeys.startIndex {
            let previousPreludeTurnIds = Set(previousReplayKeys.compactMap { key in
                key.isPrelude ? key.turnId : nil
            })
            let skippedCurrentPreludeTurnIds = currentReplayKeys[currentReplayKeys.startIndex..<matchStart]
                .compactMap { $0.key.turnId }
            if skippedCurrentPreludeTurnIds.contains(where: { !previousPreludeTurnIds.contains($0) }) {
                return nil
            }
        }
        let matchKeys = currentReplayKeys[matchStart...].map(\.key)
        let matchedKeyCount = sameRawReplayPrefixMatchLength(
            previousReplayKeys: previousReplayKeys,
            currentReplayKeys: matchKeys
        )
        guard matchedKeyCount > 0,
              currentReplayKeys[matchStart..<(matchStart + matchedKeyCount)].contains(where: { $0.key.isTokenCount }) else {
            return nil
        }
        return SameRawReplayMatch(
            startIndex: currentReplayKeys[matchStart].index,
            dropCount: currentReplayKeys[matchStart + matchedKeyCount - 1].index + 1
        )
    }

    private static func sameRawReplayPrefixMatchLength(
        previousReplayKeys: [ReplayIdentity],
        currentReplayKeys: [ReplayIdentity]
    ) -> Int {
        let upperBound = min(previousReplayKeys.count, currentReplayKeys.count)
        guard upperBound > 0 else { return 0 }
        let pattern = Array(currentReplayKeys.prefix(upperBound))
        let prefixTable = replayPrefixTable(for: pattern)
        var matched = 0
        let lastPreviousIndex = previousReplayKeys.index(before: previousReplayKeys.endIndex)
        for index in previousReplayKeys.indices {
            let key = previousReplayKeys[index]
            while matched > 0, pattern[matched] != key {
                matched = prefixTable[matched - 1]
            }
            if pattern[matched] == key {
                matched += 1
            }
            if matched == pattern.count, index < lastPreviousIndex {
                matched = prefixTable[matched - 1]
            }
        }
        return matched
    }

    private static func replayPrefixTable(for pattern: [ReplayIdentity]) -> [Int] {
        guard pattern.count > 1 else {
            return Array(repeating: 0, count: pattern.count)
        }
        var table = Array(repeating: 0, count: pattern.count)
        var matched = 0
        for index in pattern.indices.dropFirst() {
            while matched > 0, pattern[index] != pattern[matched] {
                matched = table[matched - 1]
            }
            if pattern[index] == pattern[matched] {
                matched += 1
                table[index] = matched
            }
        }
        return table
    }

    /// Identity key for replay matching. The line's identity fields are
    /// folded into a hash + length instead of being retained verbatim:
    /// a multi-MB assistant message would otherwise live on inside
    /// every `SameRawReplayCarry` (3.8a — on the real corpus that carry
    /// would reach gigabytes for the duplicated multi-GB chains). Keys
    /// are compared only within one process run, so `Hasher`'s
    /// per-process seed is fine — the legacy whole-string comparison
    /// and the hashed comparison agree wherever hashes don't collide,
    /// and the auxiliary fields plus length keep the collision surface
    /// negligible.
    fileprivate struct ReplayIdentity: Equatable {
        let valueHash: UInt64
        let valueLength: Int
        let isPrelude: Bool
        let isTokenCount: Bool
        let turnId: String?

        init(value: String, isPrelude: Bool, isTokenCount: Bool, turnId: String?) {
            var hasher = Hasher()
            hasher.combine(value)
            self.valueHash = UInt64(bitPattern: Int64(hasher.finalize()))
            self.valueLength = value.utf8.count
            self.isPrelude = isPrelude
            self.isTokenCount = isTokenCount
            self.turnId = turnId
        }
    }

    private enum ReplayUsageMode {
        case effectiveCumulative
        case lastPreferred
        case delta
    }

    private static func replayIdentities(
        in lines: [CodexLineReader.DecodedLine],
        usageMode: ReplayUsageMode
    ) -> [(index: Int, key: ReplayIdentity)] {
        var total: CodexTokenUsage?
        return replayIdentities(in: lines, usageMode: usageMode, runningTotal: &total)
    }

    /// Carried-total variant: the per-mode fold state threads across
    /// pieces of a chain so keys can be appended incrementally
    /// (`SameRawReplayCarry`) instead of recomputed over retained lines.
    private static func replayIdentities(
        in lines: [CodexLineReader.DecodedLine],
        usageMode: ReplayUsageMode,
        runningTotal total: inout CodexTokenUsage?
    ) -> [(index: Int, key: ReplayIdentity)] {
        var identities: [(index: Int, key: ReplayIdentity)] = []
        for index in lines.indices {
            let line = lines[index]
            let usage: CodexTokenUsage?
            if line.entry.type == "event_msg",
               line.entry.payload?.type == "token_count",
               let info = line.entry.payload?.info {
                usage = replayUsage(from: info, mode: usageMode, runningTotal: &total)
            } else {
                usage = nil
            }
            guard let key = replayIdentity(for: line, usage: usage) else {
                continue
            }
            identities.append((index, key))
        }
        return identities
    }

    private static func replayUsage(
        from info: CodexEntry.Info,
        mode: ReplayUsageMode,
        runningTotal: inout CodexTokenUsage?
    ) -> CodexTokenUsage? {
        switch mode {
        case .effectiveCumulative:
            if let totalTokenUsage = info.totalTokenUsage {
                runningTotal = totalTokenUsage
                return totalTokenUsage
            }
            guard let lastTokenUsage = info.lastTokenUsage else { return nil }
            let effectiveTotal = runningTotal?.adding(lastTokenUsage) ?? lastTokenUsage
            runningTotal = effectiveTotal
            return effectiveTotal
        case .lastPreferred:
            let usage = info.lastTokenUsage ?? info.totalTokenUsage
            if let totalTokenUsage = info.totalTokenUsage {
                runningTotal = totalTokenUsage
            } else if let lastTokenUsage = info.lastTokenUsage {
                runningTotal = runningTotal?.adding(lastTokenUsage) ?? lastTokenUsage
            }
            return usage
        case .delta:
            if let lastTokenUsage = info.lastTokenUsage {
                if let totalTokenUsage = info.totalTokenUsage {
                    runningTotal = totalTokenUsage
                } else {
                    runningTotal = runningTotal?.adding(lastTokenUsage) ?? lastTokenUsage
                }
                return lastTokenUsage
            }
            guard let totalTokenUsage = info.totalTokenUsage else { return nil }
            let usage = runningTotal.map { totalTokenUsage.delta(from: $0) } ?? totalTokenUsage
            runningTotal = totalTokenUsage
            return usage
        }
    }

    private static func replayIdentity(
        for line: CodexLineReader.DecodedLine,
        usage: CodexTokenUsage?
    ) -> ReplayIdentity? {
        let entry = line.entry
        guard entry.type != "session_meta" else { return nil }
        let payload = entry.payload
        let payloadType = payload?.type
        let isPrelude = entry.type == "turn_context"
            || entry.type == "task_started"
            || (entry.type == "event_msg" && (payloadType == "turn_context" || payloadType == "task_started"))
        let isTokenCount = entry.type == "event_msg" && payloadType == "token_count"
        let fields = [
            entry.type,
            payloadType,
            payload?.turnId,
            payload?.model,
            payload?.role,
            normalizedReplayText(payload?.messageText),
            payload?.name,
            payload?.arguments,
            payload?.input,
            payload?.output,
            payload?.callId,
            payload?.id,
            payload?.status,
            payload?.changes?.compactJSONString,
            payload?.tools?.compactJSONString,
            payload?.invocation?.compactJSONString,
            payload?.result?.compactJSONString,
            payload?.duration?.compactJSONString,
            payload?.execution,
            usage.map(replayUsageKey)
        ]
        return ReplayIdentity(
            value: fields.map { $0 ?? "" }.joined(separator: "\u{1F}"),
            isPrelude: isPrelude,
            isTokenCount: isTokenCount,
            turnId: payload?.turnId
        )
    }

    private static func replayUsageKey(_ usage: CodexTokenUsage) -> String {
        [
            usage.inputTokens,
            usage.cachedInputTokens,
            usage.outputTokens,
            usage.reasoningOutputTokens,
            usage.totalTokens ?? -1
        ]
            .map(String.init)
            .joined(separator: ":")
    }

    private static func normalizedReplayText(_ value: String?) -> String? {
        let text = value?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    static func lastEffectiveTotal(
        in decodedLines: [CodexLineReader.DecodedLine],
        initialPreviousTotal: CodexTokenUsage?
    ) -> CodexTokenUsage? {
        var total = initialPreviousTotal
        for line in decodedLines {
            guard line.entry.type == "event_msg",
                  line.entry.payload?.type == "token_count",
                  let info = line.entry.payload?.info else {
                continue
            }
            if let totalTokenUsage = info.totalTokenUsage {
                total = totalTokenUsage
            } else if let lastTokenUsage = info.lastTokenUsage {
                if let totalBeforeLast = total {
                    total = totalBeforeLast.adding(lastTokenUsage)
                } else {
                    total = lastTokenUsage
                }
            }
        }
        return total
    }

    private static func parentDecodedLines(
        for metadata: CodexSessionMetadata,
        codexHome: URL?,
        excluding sourceURL: URL
    ) -> [CodexLineReader.DecodedLine]? {
        guard let parentRawSessionId = metadata.subagentParentRawSessionId else {
            return nil
        }
        let discovery = CodexSessionDiscovery(codexHome: codexHome)
        var decodedLines: [CodexLineReader.DecodedLine] = []
        for url in discovery.discoverRolloutFiles() {
            let standardizedURL = url.standardizedFileURL
            guard standardizedURL != sourceURL.standardizedFileURL,
                  let candidate = try? CodexSessionMetadataReader.readMetadata(from: standardizedURL),
                  candidate.id == parentRawSessionId else {
                continue
            }
            decodedLines.append(contentsOf: CodexLineReader.readEntries(from: standardizedURL).decodedLines)
        }
        return decodedLines.isEmpty ? nil : decodedLines
    }

    static func mergeSessionPieces(
        _ pieces: [LoadedSessionPiece],
        titleIndex: CodexSessionTitleIndex
    ) -> MergedSessions {
        guard !pieces.isEmpty else {
            return MergedSessions(
                sessions: [],
                costsByRequestId: [:],
                turnsBySession: [:],
                sourceFileBySessionId: [:],
                sourceLabelsByIdentity: [:],
                rawPayloadByRequestId: [:],
                rawPayloadLocatorByRequestId: [:],
                subAgentLinksBySessionId: [:]
            )
        }

        let knownRawSessionIds = Set(pieces.map(\.metadata.id))
        let parentByRawSessionId = parentMap(for: pieces.map(\.metadata))
        let groups = Dictionary(grouping: pieces) { piece in
            visibleRawSessionId(
                for: piece.metadata,
                parentByRawSessionId: parentByRawSessionId,
                knownRawSessionIds: knownRawSessionIds
            )
        }

        var sessions: [Session] = []
        var costsByRequestId: [String: CostBreakdown?] = [:]
        var turnsBySession: [String: [Turn]] = [:]
        var sourceFileBySessionId: [String: URL] = [:]
        var sourceLabelsByIdentity: [String: String] = [:]
        var rawPayloadByRequestId: [String: Data] = [:]
        var rawPayloadLocatorByRequestId: [String: RawPayloadLocator] = [:]
        var subAgentLinksBySessionId: [String: [SubAgentLinker.Link]] = [:]

        for (visibleRawSessionId, groupPieces) in groups {
            let visibleScopedSessionId = ProviderScopedID(
                provider: .codex,
                rawSessionId: visibleRawSessionId
            ).value
            let primaryPiece = primaryPiece(
                in: groupPieces,
                visibleRawSessionId: visibleRawSessionId
            )
            let assembledPieces = groupPieces.map { piece in
                AssembledSessionPiece(
                    piece: piece,
                    turns: CodexConversationAssembler.assemble(
                        metadata: piece.metadata,
                        decodedLines: piece.decodedLines,
                        usageRequests: piece.aggregation.requests,
                        costsByRequestId: [:]
                    )
                )
            }
            let directLinks = codexSubagentLinks(
                in: assembledPieces,
                visibleScopedSessionId: visibleScopedSessionId,
                visibleRawSessionId: visibleRawSessionId
            )
            if !directLinks.isEmpty {
                subAgentLinksBySessionId[visibleScopedSessionId] = directLinks
            }
            let directLinkedAgentIds = Set(directLinks.map(\.agentId))
            let requests = groupPieces
                .flatMap { piece in
                    let isLinkedSubagent = shouldGraftAsDirectCodexSubagent(
                        metadata: piece.metadata,
                        visibleRawSessionId: visibleRawSessionId,
                        linkedAgentIds: directLinkedAgentIds
                    )
                    return piece.aggregation.requests.map {
                        $0.withSessionIdentity(
                            provider: .codex,
                            rawSessionId: visibleRawSessionId,
                            scopedSessionId: visibleScopedSessionId
                        ).withSidechain(isLinkedSubagent)
                    }
                }
                .sorted(by: requestSort)
            let session = Session(
                id: visibleScopedSessionId,
                provider: .codex,
                rawSessionId: visibleRawSessionId,
                requests: requests,
                projectPath: primaryPiece.metadata.cwd ?? groupPieces.compactMap(\.metadata.cwd).first,
                isVisibleInSessionList: isSessionListVisible(
                    visibleRawSessionId: visibleRawSessionId,
                    titleIndex: titleIndex
                ),
                cachedTitle: primaryPiece.metadata.titleHint ?? groupPieces.compactMap(\.metadata.titleHint).first
            )
            sessions.append(session)

            let sessionCostsByRequestId = CostCalculator.calculateCosts(for: requests)
            costsByRequestId.merge(sessionCostsByRequestId) { current, _ in current }

            var mergedTurns: [Turn] = []
            var linkedTurnsByAgentId: [String: [Turn]] = [:]
            var linkedFallbackIdByAgentId: [String: String] = [:]
            for assembledPiece in assembledPieces {
                let piece = assembledPiece.piece
                if let label = sourceDisplayLabel(
                    for: piece.metadata,
                    visibleRawSessionId: visibleRawSessionId,
                    sourceDiscriminator: piece.sourceDiscriminator
                ) {
                    let identity = CodexSourceDiscriminator.sourceIdentityKey(
                        scopedSessionId: piece.metadata.scopedId,
                        sourceKey: piece.sourceDiscriminator
                    )
                    sourceLabelsByIdentity[identity] = label
                }
                rawPayloadByRequestId.merge(piece.aggregation.rawPayloadByRequestId) { current, _ in current }
                rawPayloadLocatorByRequestId.merge(piece.aggregation.rawPayloadLocatorByRequestId) { current, _ in current }
                let isLinkedSubagent = shouldGraftAsDirectCodexSubagent(
                    metadata: piece.metadata,
                    visibleRawSessionId: visibleRawSessionId,
                    linkedAgentIds: directLinkedAgentIds
                )
                let sourceIdentityPrefix = normalizedSourceIdentityPrefix(
                    sourceSessionId: piece.metadata.scopedId,
                    sourceDiscriminator: piece.sourceDiscriminator
                )
                let turns = CodexConversationAssembler.assemble(
                    metadata: piece.metadata,
                    decodedLines: piece.decodedLines,
                    usageRequests: piece.aggregation.requests.map {
                        $0.withSidechain(isLinkedSubagent)
                    },
                    costsByRequestId: sessionCostsByRequestId
                )
                let normalizedTurns = normalizeTurns(
                    turns,
                    to: visibleScopedSessionId,
                    sourceSessionId: piece.metadata.scopedId,
                    sourceDiscriminator: piece.sourceDiscriminator,
                    sidechainAgentId: isLinkedSubagent ? piece.metadata.id : nil
                )
                if isLinkedSubagent {
                    linkedTurnsByAgentId[piece.metadata.id, default: []].append(contentsOf: normalizedTurns)
                    if linkedFallbackIdByAgentId[piece.metadata.id] == nil {
                        linkedFallbackIdByAgentId[piece.metadata.id] = sourceIdentityPrefix.map {
                            "\($0):\(piece.metadata.id)"
                        } ?? "\(piece.metadata.scopedId):\(piece.metadata.id)"
                    }
                } else {
                    mergedTurns.append(contentsOf: normalizedTurns)
                }
            }
            for agentId in directLinks.map(\.agentId) {
                guard let turns = linkedTurnsByAgentId[agentId],
                      let coalesced = coalescedSidechainTurn(
                        turns,
                        sessionId: visibleScopedSessionId,
                        agentId: agentId,
                        fallbackId: linkedFallbackIdByAgentId[agentId] ?? "\(visibleScopedSessionId):\(agentId)"
                      ) else {
                    continue
                }
                mergedTurns.append(coalesced)
            }
            turnsBySession[visibleScopedSessionId] = mergedTurns.sorted(by: turnSort)
            sourceFileBySessionId[visibleScopedSessionId] = primaryPiece.metadata.fileURL
        }

        sessions.sort(by: sessionSort)
        return MergedSessions(
            sessions: sessions,
            costsByRequestId: costsByRequestId,
            turnsBySession: turnsBySession,
            sourceFileBySessionId: sourceFileBySessionId,
            sourceLabelsByIdentity: sourceLabelsByIdentity,
            rawPayloadByRequestId: rawPayloadByRequestId,
            rawPayloadLocatorByRequestId: rawPayloadLocatorByRequestId,
            subAgentLinksBySessionId: subAgentLinksBySessionId
        )
    }

    static func sourceDisplayLabel(
        for metadata: CodexSessionMetadata,
        visibleRawSessionId: String,
        sourceDiscriminator: String?
    ) -> String? {
        guard metadata.id != visibleRawSessionId || sourceDiscriminator != nil else { return nil }
        if let nickname = nonEmpty(metadata.agentNickname) {
            return nickname
        }
        if let title = nonEmpty(metadata.titleHint) {
            return title
        }
        return "subagent \(shortSessionId(metadata.id))"
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func isSessionListVisible(
        visibleRawSessionId: String,
        titleIndex: CodexSessionTitleIndex
    ) -> Bool {
        titleIndex.isEmpty || titleIndex.contains(sessionId: visibleRawSessionId)
    }

    private static func shortSessionId(_ id: String) -> String {
        String(id.prefix(8))
    }

    private static func visibleRawSessionId(
        for metadata: CodexSessionMetadata,
        parentByRawSessionId: [String: String],
        knownRawSessionIds: Set<String>
    ) -> String {
        rootRawSessionId(
            startingAt: metadata.id,
            parentByRawSessionId: parentByRawSessionId,
            knownRawSessionIds: knownRawSessionIds
        )
    }

    private static func parentMap<S: Sequence>(for metadataValues: S) -> [String: String] where S.Element == CodexSessionMetadata {
        var map: [String: String] = [:]
        for metadata in metadataValues {
            guard let parentRawSessionId = metadata.subagentParentRawSessionId,
                  parentRawSessionId != metadata.id,
                  map[metadata.id] == nil else {
                continue
            }
            map[metadata.id] = parentRawSessionId
        }
        return map
    }

    private static func rootRawSessionId(
        startingAt rawSessionId: String,
        parentByRawSessionId: [String: String],
        knownRawSessionIds: Set<String>
    ) -> String {
        var current = rawSessionId
        var visited: Set<String> = [rawSessionId]
        while let parent = parentByRawSessionId[current],
              parent != current,
              knownRawSessionIds.contains(parent),
              visited.insert(parent).inserted {
            current = parent
        }
        return current
    }

    private static func primaryPiece(
        in pieces: [LoadedSessionPiece],
        visibleRawSessionId: String
    ) -> LoadedSessionPiece {
        if let parent = pieces.first(where: { $0.metadata.id == visibleRawSessionId }) {
            return parent
        }
        return pieces.sorted { lhs, rhs in
            let lhsTime = lhs.metadata.createdAt ?? .distantPast
            let rhsTime = rhs.metadata.createdAt ?? .distantPast
            if lhsTime != rhsTime { return lhsTime < rhsTime }
            return lhs.metadata.id < rhs.metadata.id
        }.first!
    }

    static func normalizeTurns(
        _ turns: [Turn],
        to sessionId: String,
        sourceSessionId: String,
        sourceDiscriminator: String?,
        sidechainAgentId: String? = nil
    ) -> [Turn] {
        turns.map { turn in
            let sourceIdentityPrefix = normalizedSourceIdentityPrefix(
                sourceSessionId: sourceSessionId,
                sourceDiscriminator: sourceDiscriminator
            )
            let turnId: String = if let sourceIdentityPrefix {
                "\(sourceIdentityPrefix):\(turn.id)"
            } else if sourceSessionId == sessionId {
                turn.id
            } else {
                "\(sourceSessionId):\(turn.id)"
            }
            return Turn(
                id: turnId,
                sessionId: sessionId,
                steps: turn.steps.map {
                    normalizeStep(
                        $0,
                        to: sessionId,
                        sourceIdentityPrefix: sourceIdentityPrefix,
                        sidechainAgentId: sidechainAgentId
                    )
                },
                isInterrupted: turn.isInterrupted
            )
        }
    }

    private static func normalizedSourceIdentityPrefix(
        sourceSessionId: String,
        sourceDiscriminator: String?
    ) -> String? {
        sourceDiscriminator.map {
            "\(sourceSessionId):source:\($0)"
        }
    }

    private static func normalizeStep(
        _ step: Step,
        to sessionId: String,
        sourceIdentityPrefix: String?,
        sidechainAgentId: String? = nil
    ) -> Step {
        let uuid = sourceIdentityPrefix.map { "\($0):\(step.uuid)" } ?? step.uuid
        let parentUuid = step.parentUuid.map { parentUuid in
            sourceIdentityPrefix.map { "\($0):\(parentUuid)" } ?? parentUuid
        }
        let toolCalls = sourceIdentityPrefix.map { prefix in
            step.toolCalls.map {
                ToolUseInfo(
                    id: "\(prefix):\($0.id)",
                    name: $0.name,
                    inputJSON: $0.inputJSON,
                    skillName: $0.skillName,
                    displayInputSummary: $0.displayInputSummary
                )
            }
        } ?? step.toolCalls
        let toolResult = sourceIdentityPrefix.map { prefix in
            step.toolResult.map {
                ToolResultInfo(
                    toolUseId: "\(prefix):\($0.toolUseId)",
                    content: $0.content,
                    isError: $0.isError
                )
            }
        } ?? step.toolResult
        return Step(
            uuid: uuid,
            parentUuid: parentUuid,
            sessionId: sessionId,
            timestamp: step.timestamp,
            kind: step.kind,
            isSystemInjected: step.isSystemInjected,
            isSidechain: sidechainAgentId != nil || step.isSidechain,
            agentId: sidechainAgentId ?? step.agentId,
            isCompactSummary: step.isCompactSummary,
            text: step.text,
            thinkingText: step.thinkingText,
            images: step.images,
            imageSourcePaths: step.imageSourcePaths,
            mentionedFilePaths: step.mentionedFilePaths,
            attachments: step.attachments,
            toolCalls: toolCalls,
            toolResult: toolResult,
            requestId: step.requestId,
            requestIds: step.requestIds,
            messageId: step.messageId,
            model: step.model,
            speed: step.speed,
            stopReason: step.stopReason,
            stopReasonKind: step.stopReasonKind,
            tokens: step.tokens,
            cost: step.cost,
            rawJSON: step.rawJSON,
            rawJSONLocator: step.rawJSONLocator
        )
    }

    static func shouldGraftAsDirectCodexSubagent(
        metadata: CodexSessionMetadata,
        visibleRawSessionId: String,
        linkedAgentIds: Set<String>
    ) -> Bool {
        metadata.id != visibleRawSessionId
            && metadata.subagentParentRawSessionId == visibleRawSessionId
            && linkedAgentIds.contains(metadata.id)
    }

    static func coalescedSidechainTurn(
        _ turns: [Turn],
        sessionId: String,
        agentId: String,
        fallbackId: String
    ) -> Turn? {
        let orderedTurns = turns.sorted(by: turnSort)
        let steps = orderedTurns
            .flatMap(\.steps)
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
                return $0.uuid < $1.uuid
            }
        guard !steps.isEmpty else { return nil }
        return Turn(
            id: orderedTurns.first?.id ?? fallbackId,
            sessionId: sessionId,
            steps: steps,
            isInterrupted: orderedTurns.contains(where: \.isInterrupted)
        )
    }

    private static func codexSubagentLinks(
        in pieces: [AssembledSessionPiece],
        visibleScopedSessionId: String,
        visibleRawSessionId: String
    ) -> [SubAgentLinker.Link] {
        var directChildMetadataById: [String: CodexSessionMetadata] = [:]
        for assembled in pieces {
            let metadata = assembled.piece.metadata
            guard metadata.id != visibleRawSessionId,
                  metadata.subagentParentRawSessionId == visibleRawSessionId,
                  directChildMetadataById[metadata.id] == nil else {
                continue
            }
            directChildMetadataById[metadata.id] = metadata
        }
        guard !directChildMetadataById.isEmpty else { return [] }

        var links: [SubAgentLinker.Link] = []
        var seenAgentIds = Set<String>()
        for assembled in pieces where assembled.piece.metadata.id == visibleRawSessionId {
            let normalizedParentTurns = normalizeTurns(
                assembled.turns,
                to: visibleScopedSessionId,
                sourceSessionId: assembled.piece.metadata.scopedId,
                sourceDiscriminator: assembled.piece.sourceDiscriminator
            )
            links.append(contentsOf: codexSubagentLinks(
                fromNormalizedParentTurns: normalizedParentTurns,
                directChildMetadataById: directChildMetadataById,
                seenAgentIds: &seenAgentIds
            ))
        }
        return links
    }

    /// Per-parent-piece link extraction (plan 3.8a): the streaming
    /// importer calls this while a root-raw-id piece is resident,
    /// carrying only `seenAgentIds` and the child-metadata map (small,
    /// known from first-line metadata) across pieces.
    static func codexSubagentLinks(
        fromNormalizedParentTurns normalizedParentTurns: [Turn],
        directChildMetadataById: [String: CodexSessionMetadata],
        seenAgentIds: inout Set<String>
    ) -> [SubAgentLinker.Link] {
        guard !directChildMetadataById.isEmpty else { return [] }
        var links: [SubAgentLinker.Link] = []
        for turn in normalizedParentTurns {
            for step in turn.steps {
                for call in step.toolCalls where call.name == "Agent" {
                    guard let result = toolResult(for: call.id, in: turn.steps),
                          result.isError == false,
                          let output = CodexSubagentSpawnOutput(content: result.content),
                          directChildMetadataById[output.agentId] != nil,
                          seenAgentIds.insert(output.agentId).inserted else {
                        continue
                    }
                    let childMetadata = directChildMetadataById[output.agentId]
                    links.append(SubAgentLinker.Link(
                        agentId: output.agentId,
                        parentToolUseId: call.id,
                        parentAssistantUuid: step.uuid,
                        parentMessageId: nil,
                        description: codexSubagentDescription(
                            output: output,
                            call: call,
                            childMetadata: childMetadata
                        ),
                        subagentType: "codex-subagent",
                        timestamp: codexLinkTimestampString(from: step.timestamp),
                        workflowLabel: output.nickname ?? childMetadata?.agentNickname
                    ))
                }
            }
        }
        return links
    }

    private static func toolResult(for toolUseId: String, in steps: [Step]) -> ToolResultInfo? {
        steps.compactMap(\.toolResult).first { $0.toolUseId == toolUseId }
    }

    private static func codexSubagentDescription(
        output: CodexSubagentSpawnOutput,
        call: ToolUseInfo,
        childMetadata: CodexSessionMetadata?
    ) -> String? {
        let nickname = nonEmpty(output.nickname) ?? nonEmpty(childMetadata?.agentNickname)
        let prompt = codexSubagentPromptSummary(from: call)
        switch (nickname, prompt) {
        case (let nickname?, let prompt?) where nickname != prompt:
            return "\(nickname): \(prompt)"
        case (let nickname?, _):
            return nickname
        case (_, let prompt?):
            return prompt
        default:
            return nil
        }
    }

    private static func codexSubagentPromptSummary(from call: ToolUseInfo) -> String? {
        guard let data = call.inputJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return call.displayInputSummary
        }
        for key in ["message", "prompt", "task", "instructions", "description"] {
            guard let value = object[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return call.displayInputSummary
    }

    private static func codexLinkTimestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func sessionSort(_ lhs: Session, _ rhs: Session) -> Bool {
        let lhsTime = lhs.endTime ?? lhs.startTime ?? .distantPast
        let rhsTime = rhs.endTime ?? rhs.startTime ?? .distantPast
        if lhsTime != rhsTime { return lhsTime > rhsTime }
        return lhs.id < rhs.id
    }

    private static func requestSort(_ lhs: ParsedRequest, _ rhs: ParsedRequest) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id < rhs.id
    }

    static func turnSort(_ lhs: Turn, _ rhs: Turn) -> Bool {
        let lhsTime = lhs.startTime ?? .distantPast
        let rhsTime = rhs.startTime ?? .distantPast
        if lhsTime != rhsTime { return lhsTime < rhsTime }
        return lhs.id < rhs.id
    }
}

struct CodexSubagentReplayTrimResult: Sendable {
    let decodedLines: [CodexLineReader.DecodedLine]
    let initialPreviousTotal: CodexTokenUsage?
}

private struct CodexSubagentSpawnOutput: Equatable, Sendable {
    let agentId: String
    let nickname: String?

    init?(content: String) {
        guard let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let agentId = Self.nonEmpty(object["agent_id"] as? String)
            ?? Self.nonEmpty(object["agentId"] as? String)
            ?? Self.nonEmpty(object["id"] as? String)
        guard let agentId else { return nil }
        self.agentId = agentId
        self.nickname = Self.nonEmpty(object["nickname"] as? String)
            ?? Self.nonEmpty(object["agent_nickname"] as? String)
            ?? Self.nonEmpty(object["name"] as? String)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

enum CodexSubagentReplayTrimmer {

    /// Everything the trimmer needs from the parent thread — KB-scale
    /// summaries instead of the parent's decoded lines (plan 3.8a: a
    /// 2.3 GB parent must not stay resident across hundreds of child
    /// trims). `absorb` threads the cumulative-total fold across calls,
    /// so absorbing the parent's pieces one by one is exactly the
    /// legacy whole-concatenation computation.
    struct ParentSummary: Sendable {
        var prompts: Set<String> = []
        var totals: [CodexTokenUsage] = []
        private var runningTotal: CodexTokenUsage?

        var isEmpty: Bool { prompts.isEmpty && totals.isEmpty }

        init() {}

        mutating func absorb(_ lines: [CodexLineReader.DecodedLine]) {
            prompts.formUnion(CodexSubagentReplayTrimmer.userMessageTexts(in: lines))
            for line in lines {
                let entry = line.entry
                guard entry.type == "event_msg",
                      entry.payload?.type == "token_count",
                      let info = entry.payload?.info else {
                    continue
                }
                if let totalTokenUsage = info.totalTokenUsage {
                    runningTotal = totalTokenUsage
                } else if let lastTokenUsage = info.lastTokenUsage {
                    if let totalBeforeLast = runningTotal {
                        runningTotal = totalBeforeLast.adding(lastTokenUsage)
                    } else {
                        runningTotal = lastTokenUsage
                    }
                }
                if let runningTotal {
                    totals.append(runningTotal)
                }
            }
        }
    }

    static func summary(of lines: [CodexLineReader.DecodedLine]) -> ParentSummary {
        var summary = ParentSummary()
        summary.absorb(lines)
        return summary
    }

    static func trim(
        _ decodedLines: [CodexLineReader.DecodedLine],
        metadata: CodexSessionMetadata,
        parentDecodedLines: [CodexLineReader.DecodedLine]?
    ) -> CodexSubagentReplayTrimResult {
        guard metadata.isSubagentThread,
              let parentDecodedLines,
              !parentDecodedLines.isEmpty else {
            return CodexSubagentReplayTrimResult(decodedLines: decodedLines, initialPreviousTotal: nil)
        }
        return trim(decodedLines, metadata: metadata, parentSummary: summary(of: parentDecodedLines))
    }

    static func trim(
        _ decodedLines: [CodexLineReader.DecodedLine],
        metadata: CodexSessionMetadata,
        parentSummary: ParentSummary
    ) -> CodexSubagentReplayTrimResult {
        func original() -> CodexSubagentReplayTrimResult {
            CodexSubagentReplayTrimResult(decodedLines: decodedLines, initialPreviousTotal: nil)
        }

        guard metadata.isSubagentThread, !parentSummary.isEmpty else {
            return original()
        }

        let parentPrompts = parentSummary.prompts
        let parentTotals = parentSummary.totals
        let effectiveTotalsByIndex = tokenTotalsByIndex(in: decodedLines)

        if !parentPrompts.isEmpty,
           let firstNovelUserIndex = decodedLines.firstIndex(where: { line in
               let text = userMessageText(in: line)
               return !text.isEmpty && !parentPrompts.contains(text)
           }) {
            return trimResult(startingAt: contextStartIndex(before: firstNovelUserIndex, in: decodedLines), in: decodedLines)
        }

        guard let lastReplayIndex = decodedLines.indices.last(where: { index in
            isReplayMarker(
                decodedLines[index],
                effectiveTotal: effectiveTotalsByIndex[index],
                parentPrompts: parentPrompts,
                parentTotals: parentTotals
            )
        }) else {
            return original()
        }

        let nextIndex = decodedLines.index(after: lastReplayIndex)
        guard nextIndex < decodedLines.endIndex else {
            return CodexSubagentReplayTrimResult(
                decodedLines: [],
                initialPreviousTotal: previousTotal(before: decodedLines.endIndex, in: decodedLines)
            )
        }

        let startIndex = decodedLines[nextIndex...].firstIndex(where: isLocalTurnPrelude) ?? nextIndex
        return trimResult(startingAt: startIndex, in: decodedLines)
    }

    private static func trimResult(
        startingAt startIndex: Int,
        in decodedLines: [CodexLineReader.DecodedLine]
    ) -> CodexSubagentReplayTrimResult {
        CodexSubagentReplayTrimResult(
            decodedLines: Array(decodedLines[startIndex...]),
            initialPreviousTotal: previousTotal(before: startIndex, in: decodedLines)
        )
    }

    private static func userMessageTexts(in lines: [CodexLineReader.DecodedLine]) -> Set<String> {
        Set(lines.compactMap { line in
            let text = userMessageText(in: line)
            return text.isEmpty ? nil : text
        })
    }

    private static func userMessageText(in line: CodexLineReader.DecodedLine) -> String {
        let entry = line.entry
        guard let payload = entry.payload else { return "" }
        let isUserMessage = (entry.type == "event_msg" && payload.type == "user_message")
            || (entry.type == "response_item" && payload.type == "message" && payload.role == "user")
        guard isUserMessage else { return "" }
        return normalized(payload.messageText)
    }

    private static func tokenTotals(in lines: [CodexLineReader.DecodedLine]) -> [CodexTokenUsage] {
        Array(tokenTotalsByIndex(in: lines).values)
    }

    private static func tokenTotalsByIndex(in lines: [CodexLineReader.DecodedLine]) -> [Int: CodexTokenUsage] {
        var totals: [Int: CodexTokenUsage] = [:]
        var total: CodexTokenUsage?
        for index in lines.indices {
            let entry = lines[index].entry
            guard entry.type == "event_msg",
                  entry.payload?.type == "token_count",
                  let info = entry.payload?.info else {
                continue
            }
            if let totalTokenUsage = info.totalTokenUsage {
                total = totalTokenUsage
            } else if let lastTokenUsage = info.lastTokenUsage {
                if let totalBeforeLast = total {
                    total = totalBeforeLast.adding(lastTokenUsage)
                } else {
                    total = lastTokenUsage
                }
            }
            totals[index] = total
        }
        return totals
    }

    private static func isReplayMarker(
        _ line: CodexLineReader.DecodedLine,
        effectiveTotal: CodexTokenUsage?,
        parentPrompts: Set<String>,
        parentTotals: [CodexTokenUsage]
    ) -> Bool {
        let text = userMessageText(in: line)
        if !text.isEmpty, parentPrompts.contains(text) {
            return true
        }
        guard let total = effectiveTotal else { return false }
        return parentTotals.contains(total)
    }

    private static func previousTotal(
        before index: Int,
        in lines: [CodexLineReader.DecodedLine]
    ) -> CodexTokenUsage? {
        var total: CodexTokenUsage?
        for lineIndex in lines.indices where lineIndex < index {
            let entry = lines[lineIndex].entry
            guard entry.type == "event_msg",
                  entry.payload?.type == "token_count",
                  let info = entry.payload?.info else {
                continue
            }
            if let totalTokenUsage = info.totalTokenUsage {
                total = totalTokenUsage
            } else if let lastTokenUsage = info.lastTokenUsage {
                if let totalBeforeLast = total {
                    total = totalBeforeLast.adding(lastTokenUsage)
                } else {
                    total = lastTokenUsage
                }
            }
        }
        return total
    }

    private static func contextStartIndex(
        before userIndex: Int,
        in lines: [CodexLineReader.DecodedLine]
    ) -> Int {
        var index = userIndex
        while index > lines.startIndex {
            let previousIndex = lines.index(before: index)
            guard isLocalTurnPrelude(lines[previousIndex]) else {
                break
            }
            index = previousIndex
        }
        return index
    }

    private static func isLocalTurnPrelude(_ line: CodexLineReader.DecodedLine) -> Bool {
        let entry = line.entry
        let payloadType = entry.payload?.type
        return entry.type == "turn_context"
            || entry.type == "task_started"
            || (entry.type == "event_msg" && payloadType == "task_started")
    }

    private static func normalized(_ value: String?) -> String {
        value?
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        ?? ""
    }
}
