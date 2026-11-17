import AVFoundation
import SwiftUI

/// Muted looping preview. Plays only while its window is visible on screen:
/// a window behind other apps, minimized, or on another Space stops decoding.
/// `isSuspended` stops it too, for states occlusion doesn't report, such as
/// a locked screen or sleeping displays.
struct LoopingVideoView: NSViewRepresentable {
    let url: URL
    var gravity: AVLayerVideoGravity = .resizeAspectFill
    var isSuspended = false

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeNSView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.playerLayer.player = context.coordinator.player
        view.playerLayer.videoGravity = gravity
        let coordinator = context.coordinator
        view.onVisibilityChange = { [weak coordinator] in coordinator?.setVisible($0) }
        coordinator.setSuspended(isSuspended)
        return view
    }

    func updateNSView(_ view: PlayerSurface, context: Context) {
        view.playerLayer.videoGravity = gravity
        context.coordinator.setSuspended(isSuspended)
        // Recreate the decoder when the URL changes (SwiftUI reuses the view).
        // Without this, hero/carousel reuse silently kept playing the old video.
        if context.coordinator.url != url {
            context.coordinator.reconfigure(url: url)
            view.playerLayer.player = context.coordinator.player
        }
    }

    static func dismantleNSView(_ view: PlayerSurface, coordinator: Coordinator) {
        view.onVisibilityChange = nil
        coordinator.tearDown()
        view.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator {
        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private(set) var url: URL
        private var isVisible = false
        private var isSuspended = false
        private var shouldPlay: Bool { isVisible && !isSuspended }

        init(url: URL) {
            self.url = url
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }

        func setVisible(_ visible: Bool) {
            isVisible = visible
            updatePlayback()
        }

        func setSuspended(_ suspended: Bool) {
            guard suspended != isSuspended else { return }
            isSuspended = suspended
            updatePlayback()
        }

        private func updatePlayback() {
            if shouldPlay { player.play() } else { player.pause() }
        }

        /// Swap the looping item for a new URL (main thread, SwiftUI update).
        func reconfigure(url: URL) {
            self.url = url
            player.pause()
            looper = nil
            player.replaceCurrentItem(with: nil)
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            if shouldPlay { player.play() }
        }

        /// Fully release the decoder for view teardown.
        func tearDown() {
            isVisible = false
            player.pause()
            looper = nil
            player.replaceCurrentItem(with: nil)
        }
    }
}

final class PlayerSurface: WindowVisibilityView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
    }

    @available(*, unavailable) required init?(coder: NSCoder) { nil }

    override func layout() { super.layout(); playerLayer.frame = bounds }
}
