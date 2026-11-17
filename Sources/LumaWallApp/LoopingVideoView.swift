import AVFoundation
import SwiftUI

/// Muted looping preview. Plays only while its window is visible on screen:
/// a window behind other apps, minimized, or on another Space stops decoding.
struct LoopingVideoView: NSViewRepresentable {
    let url: URL
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeNSView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.playerLayer.player = context.coordinator.player
        view.playerLayer.videoGravity = gravity
        let coordinator = context.coordinator
        view.onVisibilityChange = { [weak coordinator] in coordinator?.setVisible($0) }
        return view
    }

    func updateNSView(_ view: PlayerSurface, context: Context) {
        view.playerLayer.videoGravity = gravity
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

        init(url: URL) {
            self.url = url
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }

        func setVisible(_ visible: Bool) {
            isVisible = visible
            if visible { player.play() } else { player.pause() }
        }

        /// Swap the looping item for a new URL (main thread, SwiftUI update).
        func reconfigure(url: URL) {
            self.url = url
            player.pause()
            looper = nil
            player.replaceCurrentItem(with: nil)
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            if isVisible { player.play() }
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
