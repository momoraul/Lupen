import AppKit

/// Builds the context menu raised by a secondary (right / Control) click on
/// the menu-bar status item. macOS convention is left-click = primary action,
/// right-click = action menu; the Dashboard, Reports, Diagnostics, Verify and
/// Manage windows otherwise live only under the app's Window menu.
///
/// Pure and stateless: it takes the click `target` (the `AppDelegate`, which
/// owns the `@objc` open actions) and a live `verifyTitle` (provider-dependent
/// — "Verify Costs…" vs "Verify Usage…") and returns a fresh `NSMenu`. Rebuilt
/// on every click so the Verify title tracks the active source. Keeping it free
/// of app state makes the item set unit-testable without launching the app.
@MainActor
enum StatusBarMenuBuilder {

    static func makeMenu(target: AnyObject, verifyTitle: String) -> NSMenu {
        let menu = NSMenu()

        menu.addItem(item(
            "Open Dashboard", #selector(AppDelegate.openDashboard(_:)),
            key: "0", mask: [.command], target: target
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            "Reports…", #selector(AppDelegate.openReports(_:)),
            key: "r", mask: [.command, .shift], target: target
        ))
        menu.addItem(item(
            "Parse Diagnostics…", #selector(AppDelegate.openParseDiagnostics(_:)),
            key: "d", mask: [.command, .shift], target: target
        ))
        menu.addItem(item(
            verifyTitle, #selector(AppDelegate.openVerifyCosts(_:)),
            key: "v", mask: [.command, .shift], target: target
        ))
        menu.addItem(item(
            "Manage Sessions & Storage…", #selector(AppDelegate.openManageSessions(_:)),
            key: "m", mask: [.command, .shift], target: target
        ))
        menu.addItem(.separator())
        menu.addItem(item(
            "Settings…", #selector(AppDelegate.openPreferences(_:)),
            key: ",", mask: [.command], target: target
        ))
        menu.addItem(.separator())
        // Quit routes through the responder chain to NSApp (target nil), so it
        // works no matter which object is wired as the click target.
        menu.addItem(item(
            "Quit Lupen", #selector(NSApplication.terminate(_:)),
            key: "q", mask: [.command], target: nil
        ))

        return menu
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        key: String,
        mask: NSEvent.ModifierFlags,
        target: AnyObject?
    ) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = mask
        menuItem.target = target
        return menuItem
    }
}
