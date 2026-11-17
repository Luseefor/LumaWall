import AppKit
import SwiftUI

/// NSView that reports whether its window is visible on screen. "Visible"
/// follows the window's occlusion state, so it turns false when the window is
/// behind other apps, minimized, on another Space, or the app is hidden.
class WindowVisibilityView: NSView {
    var onVisibilityChange: ((Bool) -> Void)?
    private var occlusionObserver: NSObjectProtocol?

    var isVisibleOnScreen: Bool {
        window?.occlusionState.contains(.visible) == true && !isHiddenOrHasHiddenAncestor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Leaving the window (including teardown) drops the observer.
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportVisibility() }
            }
        }
        reportVisibility()
    }

    override func viewDidUnhide() { super.viewDidUnhide(); reportVisibility() }
    override func viewDidHide() { super.viewDidHide(); reportVisibility() }

    func reportVisibility() {
        onVisibilityChange?(isVisibleOnScreen)
    }
}

/// Reports whether the enclosing window is visible on screen. Use it to stop
/// timers and animations that nobody can see.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowVisibilityView {
        let view = WindowVisibilityView()
        view.onVisibilityChange = onChange
        return view
    }

    func updateNSView(_ view: WindowVisibilityView, context: Context) {
        view.onVisibilityChange = onChange
    }

    static func dismantleNSView(_ view: WindowVisibilityView, coordinator: ()) {
        view.onVisibilityChange = nil
    }
}
