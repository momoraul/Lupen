import Foundation
import Darwin

/// Cross-process advisory lock (POSIX `flock`) guarding the CLI's index
/// refresh. Two concurrent `lupen` invocations would otherwise both run a
/// full cold index into the same SQLite file — correct (writes are
/// idempotent and WAL serialises them) but wasteful. Holding this lock
/// around the refresh means only one process indexes at a time; the other
/// waits briefly, then reads whatever the winner produced.
///
/// `flock` is advisory and per-open-file-description, so it also conflicts
/// across separate `open()`s within one process — which is exactly what
/// makes the behaviour unit-testable. It does not (and need not) prevent
/// the GUI app from writing concurrently: GRDB's WAL + 5 s busy timeout
/// already guarantee no corruption there; this lock only coordinates
/// CLI-vs-CLI refresh work.
final class CLIProcessLock {
    private let fileDescriptor: Int32
    private var released = false

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    /// Acquire an exclusive lock on `url`, retrying (~100 ms steps) up to
    /// `timeout`. Returns `nil` if another process holds it past the
    /// timeout, or if the lock file can't be opened — callers then proceed
    /// lock-less (reading the current index) rather than failing.
    static func acquire(at url: URL, timeout: TimeInterval) -> CLIProcessLock? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // O_NOFOLLOW + 0600: the lock lives in the user's own app-support dir
        // and its contents are never read or written (we only flock the fd),
        // so refuse to follow a symlink planted at the path and keep it private.
        // A failed open just means we proceed lock-less, which is the documented
        // fallback.
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return nil }

        var remainingSteps = max(0, Int((timeout / 0.1).rounded()))
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return CLIProcessLock(fileDescriptor: descriptor)
            }
            // EWOULDBLOCK → held elsewhere; anything else is a real error.
            if errno != EWOULDBLOCK {
                close(descriptor)
                return nil
            }
            if remainingSteps <= 0 {
                close(descriptor)
                return nil
            }
            remainingSteps -= 1
            usleep(100_000)  // 100 ms
        }
    }

    /// Release the lock and close the descriptor. Idempotent.
    func release() {
        guard !released else { return }
        released = true
        flock(fileDescriptor, LOCK_UN)
        close(fileDescriptor)
    }

    /// Safety net: if a caller ever drops the lock without calling `release()`,
    /// don't leak the descriptor or hold the advisory lock for the rest of the
    /// process. (Production callers use `defer { release() }`; this guards
    /// future ones.)
    deinit {
        if !released {
            flock(fileDescriptor, LOCK_UN)
            close(fileDescriptor)
        }
    }
}
