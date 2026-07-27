import AppKit

/// Content view controller of the detached detail window.
///
/// Two jobs, both of which exist because a view controller cannot simply
/// become a window's content:
///
/// 1. **Insulation.** Assigning a view controller to
///    `NSWindow.contentViewController` forces its view's
///    `translatesAutoresizingMaskIntoConstraints` back to `true`. Doing
///    that to `DetailViewController` would leave it autoresizing-driven
///    when it returns to the dashboard's Auto Layout container. This
///    wrapper absorbs the flag flip; the detail view stays a constrained
///    subview throughout.
///
/// 2. **Responder-chain repair.** Several of the pane's controls dispatch
///    through the responder chain with `target = nil` — the Export Turn
///    Analysis button targets `DashboardSplitViewController`, and the
///    find-bar fallbacks forward to `nextResponder`. In a separate window
///    that chain no longer passes through the dashboard, so those actions
///    would go silently dead. `supplementalTarget(forAction:sender:)`
///    splices the dashboard back in as an action target.
@MainActor
final class DetachedDetailHostViewController: NSViewController {

    /// The dashboard split view controller. Weak — the dashboard owns
    /// this window controller indirectly through the coordinator.
    private weak var actionResponder: NSResponder?
    private(set) weak var embeddedDetail: DetailViewController?

    init(actionResponder: NSResponder?) {
        self.actionResponder = actionResponder
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        view = root
    }

    func embed(_ detailVC: DetailViewController) {
        guard embeddedDetail !== detailVC else { return }
        addChild(detailVC)
        let detailView = detailVC.view
        detailView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(detailView)
        NSLayoutConstraint.activate([
            detailView.topAnchor.constraint(equalTo: view.topAnchor),
            detailView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        embeddedDetail = detailVC
    }

    /// Hand the detail pane back. The edge constraints created in
    /// `embed` reference two views, so AppKit drops them from this
    /// container on `removeFromSuperview()` — nothing accumulates across
    /// round trips.
    func releaseDetail() {
        guard let detailVC = embeddedDetail else { return }
        detailVC.view.removeFromSuperview()
        detailVC.removeFromParent()
        embeddedDetail = nil
    }

    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let actionResponder, actionResponder.responds(to: action) {
            return actionResponder
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }
}
