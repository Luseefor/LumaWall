import AppKit
import SwiftUI

extension View {
    /// Tells the model when this view is on screen, so live stats poll only
    /// while someone can see them. "On screen" means in a window that is not
    /// fully occluded or hidden; a closed menu bar popover counts as hidden
    /// even though SwiftUI may not send `onDisappear` for it.
    func reportsDiagnosticsVisibility(to model: AppModel) -> some View {
        background(DiagnosticsVisibilityReader(model: model))
    }
}

private struct DiagnosticsVisibilityReader: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    static func dismantleNSView(_ nsView: ReaderView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    final class ReaderView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private let model: AppModel
        private let id = UUID()
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?

        init(model: AppModel) { self.model = model }

        func attach(to window: NSWindow?) {
            guard window !== self.window else { return }
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            self.window = window
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                }
            }
            report()
        }

        private func report() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            model.setDiagnosticsViewer(id, visible: visible)
        }
    }
}
