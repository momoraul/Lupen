import AppKit

// Statusline-tap helper mode. Activated when Claude Code (via the
// `~/.claude/lupen-statusline-tap.sh` wrapper) invokes the Lupen binary
// with `--statusline-tap` as its first argument. Runs entirely before
// AppKit init so the spawn cost stays minimal — the helper just reads
// stdin, appends a sample, optionally chains, and exits.
if CommandLine.arguments.count >= 2,
   CommandLine.arguments[1] == StatuslineTapMode.argvFlag {
    StatuslineTapMode.runAndExit()
}

// Default smoke runs validate data loading only. Keep them ahead of
// NSApplication creation so CLI-driven validation cannot trigger AppKit
// registration crashes or user-visible crash alerts. Set
// LUPEN_SMOKE_OPEN_DASHBOARD=1 to exercise the full GUI launch path.
if let smokeTest = LaunchSmokeTestConfig.current(), !smokeTest.openDashboard {
    HeadlessSmokeTestRunner.runAndExit(config: smokeTest)
}

// Single-instance enforcement (skip when running as test host)
let isSmokeTestLaunch = ProcessInfo.processInfo.environment["LUPEN_SMOKE_TEST"] == "1"
    || CommandLine.arguments.contains("--lupen-smoke-test")

if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
   !isSmokeTestLaunch {
    let bundleId = Bundle.main.bundleIdentifier ?? "com.momoraul.lupen"
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        .filter { $0 != NSRunningApplication.current }
    if let existing = others.first {
        existing.activate(options: [.activateAllWindows])
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(delegate) {
    app.run()
}
