//
//  CollapsedCardsStorage.swift
//  Lupen
//
//  Created by jaden on 2026/07/26.
//

import Foundation

/// Overview cards the user can fold away. Both lead a selected turn, and both
/// start **expanded** — they are the glance, so a collapsed default would hide
/// the feature from anyone who never thinks to click a chevron. Folding is the
/// opt-out, and it is remembered.
enum CollapsibleCard: String, Sendable, CaseIterable {
    /// C-22 — which files the turn read and wrote.
    case fileAccess
    /// C-24 — where the turn's wall clock went.
    case timeline
}

/// Tiny JSON persistence utility for the conversation overview cards the user
/// has folded away.
///
/// **Shape: a sorted JSON array of the *collapsed* card keys.** Storing the
/// collapsed set rather than the expanded one is what makes "expanded" the
/// default for free — a missing file, an empty array, and a corrupt file all
/// degrade to "nothing is collapsed", which is exactly the intended first-run
/// state. No migration and no first-launch seeding.
///
/// **Unknown keys are preserved.** A key written by a newer build (a card this
/// version does not know about) is round-tripped untouched, so downgrading and
/// upgrading again does not silently discard the user's choice.
///
/// Load/save are synchronous and free-standing, mirroring
/// `ExpandedGroupsStorage`: that keeps the type trivially testable and avoids
/// a MainActor dependency in a pure I/O helper. Unlike the sidebar's expansion
/// state, no debounce is needed — a card toggle is a deliberate click, not a
/// drag, so writes are rare and each one is a few bytes.
struct CollapsedCardsStorage: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let base: URL
            if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
                base = URL(fileURLWithPath: configDir)
            } else {
                base = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude")
            }
            self.fileURL = base
                .appendingPathComponent("lupen")
                .appendingPathComponent("collapsed_cards.json")
        }
    }

    /// Reads the persisted set of collapsed card keys. Returns an empty set on
    /// missing / unreadable / corrupt files — every failure mode lands on
    /// "everything expanded", which is the intended default rather than a
    /// fallback the user has to notice.
    func load() -> Set<String> {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        guard let array = try? JSONDecoder().decode([String].self, from: data) else {
            LoggerService.shared.logFromAnyThread(
                .warning,
                "Failed to decode collapsed_cards.json — treating as empty",
                context: "Cache"
            )
            return []
        }
        return Set(array)
    }

    /// Writes the given set to disk atomically. Creates the parent directory
    /// if missing. Failures are logged, never thrown — persistence of UI
    /// collapse state is best-effort and should never crash the app.
    func save(_ keys: Set<String>) {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Sort for deterministic file contents — the same input always
            // produces the same bytes, which is handy when diffing by hand.
            let data = try JSONEncoder().encode(keys.sorted())
            try data.write(to: fileURL, options: .atomic)
        } catch {
            LoggerService.shared.logFromAnyThread(
                .error,
                "Failed to save collapsed cards: \(error.localizedDescription)",
                context: "Cache"
            )
        }
    }
}

/// In-memory view of `CollapsedCardsStorage`, loaded once and written through
/// on every change.
///
/// Kept separate from the storage so the renderers can ask a cheap synchronous
/// question ("is this card collapsed?") without touching the disk per card,
/// and so tests can drive the whole default-expanded contract against a temp
/// file. It lives here rather than under `Domain/` — unlike `ProviderStore` or
/// `AppStateStore` this holds no domain data, only the on-disk UI preference
/// its neighbouring storage type reads and writes.
///
/// **Single owner.** State is read once at init and never reloaded, so two
/// live stores over one file would let the later write clobber the earlier
/// one. `ConversationDetailView` owns the only instance;
/// `concurrentStoresAreLastWriteWins` pins that contract so a second owner
/// surfaces as a failing test rather than a silently lost preference.
@MainActor
final class CollapsedCardsStore {
    private let storage: CollapsedCardsStorage
    /// Raw keys, including any this build does not recognise — they are
    /// carried through saves untouched so a newer build's choice survives.
    private var collapsedKeys: Set<String>

    init(storage: CollapsedCardsStorage = CollapsedCardsStorage()) {
        self.storage = storage
        self.collapsedKeys = storage.load()
    }

    /// `false` unless the user explicitly folded this card away.
    func isCollapsed(_ card: CollapsibleCard) -> Bool {
        collapsedKeys.contains(card.rawValue)
    }

    /// Convenience inverse — what `DisclosureCardView.initialExpanded` wants.
    func isExpanded(_ card: CollapsibleCard) -> Bool {
        !isCollapsed(card)
    }

    // MARK: - Per-turn file rows (session-scoped, not persisted)

    /// Turns whose file-access card has its folded tail opened.
    ///
    /// In memory only, on purpose. The card is rebuilt on every turn selection
    /// *and* every highlight change, so without this an opened tail closed
    /// again the moment the user picked a step — but the key is per turn, so
    /// persisting it would grow a file without bound to remember a transient
    /// view state.
    private var turnsWithExpandedFileRows: Set<String> = []

    func areFileRowsExpanded(forTurn key: String) -> Bool {
        turnsWithExpandedFileRows.contains(key)
    }

    func setFileRowsExpanded(_ expanded: Bool, forTurn key: String) {
        if expanded {
            turnsWithExpandedFileRows.insert(key)
        } else {
            turnsWithExpandedFileRows.remove(key)
        }
    }

    /// Records a toggle. Writing on every change is affordable because a card
    /// toggle is a deliberate click; no debounce is needed.
    func setCollapsed(_ collapsed: Bool, for card: CollapsibleCard) {
        let changed = collapsed
            ? collapsedKeys.insert(card.rawValue).inserted
            : collapsedKeys.remove(card.rawValue) != nil
        guard changed else { return }
        storage.save(collapsedKeys)
    }
}
