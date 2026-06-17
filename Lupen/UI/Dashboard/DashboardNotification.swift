import Foundation

extension Notification.Name {
    static let openDashboard = Notification.Name("com.momoraul.lupen.openDashboard")
    /// Fired by any UI surface (status bar dropdown, toast, etc.) that wants
    /// to open the Parse Diagnostics window. AppDelegate subscribes and
    /// routes to `openParseDiagnostics(_:)`.
    static let openParseDiagnostics = Notification.Name("com.momoraul.lupen.openParseDiagnostics")
}
