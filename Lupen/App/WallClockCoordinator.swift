import AppKit
import Foundation

/// Emits a wall-clock "tick" notification once per local-hour boundary, plus
/// immediate ticks on system wake and clock/timezone changes.
///
/// ## Why this exists
/// Lupen's UI refresh is driven by `@Observable` mutations on
/// `AppStateStore` — i.e. new data from FSEvents. Several derived values
/// depend on the wall clock instead of store state (e.g. `todayAggregateCost`
/// uses `Calendar.isDateInToday`, sidebar's green dot uses `endTime + 600s`,
/// Reports bucketing uses `startOfDay`). With no new data arriving, these
/// go stale — the canonical symptom is the menu-bar "today cost" still
/// showing yesterday's total past midnight.
///
/// This coordinator fills that gap by broadcasting a single
/// `.wallClockTick` notification that interested views observe and respond
/// to with cheap, targeted refreshes. **It never mutates the store** —
/// incremental rebuilds are still FSEvents' job.
///
/// ## Firing policy
/// - Aligned to the top of each local hour (xx:00:00). One-shot `Timer`,
///   rescheduled on each fire — no drift.
/// - System wake → immediate tick + reschedule (catches overnight sleep
///   where the timer would otherwise fire once on wake, but we want it
///   deterministic).
/// - **Screens wake** (`screensDidWakeNotification`) → same handler as
///   system wake. Covers the common "external monitor sleeps" /
///   "lid closes-then-opens but Mac never fully slept" path that does
///   not fire `didWakeNotification`. Rate-limited to 5 s so rapid
///   display power-cycles don't fan out into observer storms.
/// - **System sleep** (`willSleepNotification`) → tick with reason
///   `.sleep` so observers that hold in-flight work can cancel
///   gracefully. The wall-clock value itself doesn't change on sleep;
///   the tick is purely a "system is going to sleep, react if you
///   need to" signal.
/// - Clock / timezone change → immediate tick + reschedule.
/// - `userInfo[didCrossMidnight] == true` when the fire crosses a local
///   day boundary. Observers that care only about day rollover
///   (sidebar / Reports) filter on this.
///
/// ## Cost
/// Idle: one Timer on the main run loop. Per fire: one
/// `NotificationCenter.post` + whatever observers do (typically a single
/// label update). See individual observers for details.
@MainActor
final class WallClockCoordinator {

    static let shared = WallClockCoordinator()

    /// Posted on the main queue. `userInfo` keys: `reason` (`Reason`),
    /// `didCrossMidnight` (`Bool`). `nonisolated` so observer registration
    /// and the `Notification.wallClockDidCrossMidnight` extension can
    /// reference the name from any actor context — the *post* still
    /// happens on main, but naming the notification is pure.
    nonisolated static let wallClockTick = Notification.Name("com.momoraul.lupen.wallClockTick")

    enum Reason: String {
        case hourly
        case wake
        case clockChange
        /// System is about to enter sleep. Wall-clock values don't move,
        /// but observers may want to cancel in-flight work or pause
        /// expensive subscriptions. No reschedule — the timer is left
        /// alone; macOS pauses Timers during sleep automatically.
        case sleep
    }

    enum UserInfoKey: String {
        case reason
        case didCrossMidnight
    }

    private var timer: Timer?
    /// Local day of the previous tick. First tick after `start()` compares
    /// against the day at start time, so no spurious "crossed midnight"
    /// fires on boot.
    private var lastTickDay: Date
    /// Last instant we fired a wake-class tick (`didWakeNotification` or
    /// `screensDidWakeNotification`). Used to debounce rapid screens-wake
    /// events from external monitor power cycles. `nil` until the first
    /// wake after `start()`.
    private var lastWakeTickAt: Date?
    /// Minimum gap between wake-class ticks. 5 s is long enough to absorb
    /// the burst of `screensDidWake` events that fire when an external
    /// display power-cycles or the lid moves through partially-open
    /// states, short enough that a real "wake → user looks at menu bar
    /// 5 s later" sequence delivers a fresh tick.
    private static let wakeDebounceSeconds: TimeInterval = 5

    private init() {
        self.lastTickDay = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    }

    // MARK: - Lifecycle

    /// Idempotent — a second call reuses the singleton cleanly. Must be
    /// on main. The internal `stop()` first pass clears any Timer and
    /// observer from a prior `start()`, so callers (tests, app relaunch
    /// in-process) can invoke it repeatedly without leaking or double-
    /// firing.
    func start() {
        stop()
        scheduleNextTick()

        // System sleep / wake / screens-wake all go through the
        // `NSWorkspace` notification center. Three observers, two
        // handlers — `handleWake` services both real wake and screens
        // wake (the difference is invisible to subscribers), and
        // `handleSleep` services the will-sleep entry point so
        // observers holding in-flight tasks can react before macOS
        // suspends the process.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleWake(_:)),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(handleSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleClockChange(_:)),
            name: .NSSystemClockDidChange,
            object: nil
        )
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        // Reset wake-debounce state so a subsequent `start()` doesn't
        // inherit a "last wake was 2 seconds ago" timestamp from the
        // prior session and swallow the first legitimate wake tick.
        lastWakeTickAt = nil
    }

    // MARK: - Timer scheduling

    private func scheduleNextTick() {
        timer?.invalidate()
        let fireDate = Self.nextHourBoundary(after: Date())
        // `Timer(fire:interval:repeats:block:)` uses an absolute fire date.
        // During system sleep the timer does not fire, but macOS delivers
        // the missed fire on wake; our wake observer also catches this
        // path explicitly and rescheduled from the new now.
        let timer = Timer(fire: fireDate, interval: 0, repeats: false) { [weak self] _ in
            // Block runs on the run loop where the timer is scheduled
            // (here, main). Hop to main-actor context explicitly for Swift
            // concurrency correctness.
            DispatchQueue.main.async {
                self?.handleTick(reason: .hourly)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func handleTick(reason: Reason) {
        let now = Date()
        let cal = Calendar.autoupdatingCurrent
        let today = cal.startOfDay(for: now)
        let crossedMidnight = Self.didCrossMidnight(
            previousTickDay: lastTickDay,
            currentTickDay: today
        )
        lastTickDay = today

        NotificationCenter.default.post(
            name: Self.wallClockTick,
            object: nil,
            userInfo: [
                UserInfoKey.reason.rawValue: reason,
                UserInfoKey.didCrossMidnight.rawValue: crossedMidnight,
            ]
        )

        scheduleNextTick()
    }

    // MARK: - System events
    //
    // Both handlers are `nonisolated` because the Obj-C selector can be
    // invoked from any thread depending on how the system dispatches the
    // notification (`NSWorkspace.didWakeNotification` is documented to
    // arrive on main; `NSSystemClockDidChange` is less explicit). Hopping
    // to main via `DispatchQueue.main.async` + `MainActor.assumeIsolated`
    // is cheap, keeps MainActor-isolated state access safe, and matches
    // the block-based `queue: .main` ergonomics without the block-based
    // observer's lifetime quirk.

    @objc private nonisolated func handleWake(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.dispatchWakeTick()
            }
        }
    }

    @objc private nonisolated func handleSleep(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                // No debounce on sleep — only one will-sleep fires per
                // sleep transition, and observers that care about
                // cancelling in-flight work must hear every one.
                self?.handleTick(reason: .sleep)
            }
        }
    }

    @objc private nonisolated func handleClockChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.handleTick(reason: .clockChange)
            }
        }
    }

    /// Debounced entry point for both `didWakeNotification` and
    /// `screensDidWakeNotification`. External monitor power cycles and
    /// rapid lid open/close can fire screens-wake several times in under
    /// a second; collapsing those to a single tick keeps observer
    /// work proportional to user-perceived wake events.
    private func dispatchWakeTick() {
        let now = Self.nowProvider()
        if let last = lastWakeTickAt,
           now.timeIntervalSince(last) < Self.wakeDebounceSeconds {
            return
        }
        lastWakeTickAt = now
        handleTick(reason: .wake)
    }

    // MARK: - Test seam

    /// Production reads `Date()`; tests inject a deterministic clock so
    /// the debounce window can be exercised without relying on real
    /// wall time. `nonisolated(unsafe)` because tests mutate it before
    /// driving the coordinator and the singleton's debounce code is
    /// main-actor isolated, so there's no concurrent access in
    /// practice.
    nonisolated(unsafe) static var nowProvider: @Sendable () -> Date = { Date() }

    /// Test-only: simulate a `screensDidWake` / `didWake` notification
    /// without round-tripping through `NSWorkspace.shared.notificationCenter`.
    /// Tests that drive the real notification center are flaky in
    /// xcodebuild suite mode (cross-process workers, deferred dispatch
    /// delivery). This skips the `DispatchQueue.main.async` hop and the
    /// system center entirely, so the test sees the same `dispatchWakeTick`
    /// path the selector handler would have taken.
    func testHook_simulateWake() {
        dispatchWakeTick()
    }

    /// Test-only: simulate a `willSleep` notification. Same rationale
    /// as `testHook_simulateWake`.
    func testHook_simulateSleep() {
        handleTick(reason: .sleep)
    }

    // MARK: - Pure helpers (testable)

    /// Returns the next local-hour boundary strictly after `date`.
    /// `Calendar.autoupdatingCurrent` so DST/timezone changes are honoured.
    /// `nonisolated` so tests (and any future non-main callers) can invoke
    /// the pure math without hopping actors.
    nonisolated static func nextHourBoundary(after date: Date,
                                             calendar: Calendar = .autoupdatingCurrent) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let thisHour = calendar.date(from: comps) ?? date
        return calendar.date(byAdding: .hour, value: 1, to: thisHour)
            ?? date.addingTimeInterval(3600)
    }

    /// Decides whether a tick crossed a local-day boundary. Both inputs
    /// must already be `startOfDay` instants. Split out as a pure
    /// function so the "did the day change?" logic is unit-testable
    /// independent of `handleTick`'s side-effects.
    nonisolated static func didCrossMidnight(previousTickDay: Date,
                                             currentTickDay: Date) -> Bool {
        previousTickDay != currentTickDay
    }
}

extension Notification {

    /// Convenience extractor for `WallClockCoordinator.wallClockTick`
    /// observers. Returns `false` if the flag is missing so "unknown"
    /// ticks fall back to the cheaper hourly-only refresh path.
    var wallClockDidCrossMidnight: Bool {
        (userInfo?[WallClockCoordinator.UserInfoKey.didCrossMidnight.rawValue] as? Bool) ?? false
    }
}
