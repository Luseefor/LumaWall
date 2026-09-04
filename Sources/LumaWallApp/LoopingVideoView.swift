import AVFoundation
import SwiftUI

struct LoopingVideoView: NSViewRepresentable {
    let url: URL
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeNSView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.playerLayer.player = context.coordinator.player
        view.playerLayer.videoGravity = gravity
        context.coordinator.player.play()
        return view
    }

    func updateNSView(_ view: PlayerSurface, context: Context) {
        view.playerLayer.videoGravity = gravity
        // Recreate the decoder when the URL changes (SwiftUI reuses the view).
        // Without this, hero/carousel reuse silently kept playing the old video.
        if context.coordinator.url != url {
            context.coordinator.reconfigure(url: url)
            view.playerLayer.player = context.coordinator.player
            context.coordinator.player.play()
        }
    }

    static func dismantleNSView(_ view: PlayerSurface, coordinator: Coordinator) {
        coordinator.tearDown()
        view.playerLayer.player = nil
    }

    final class Coordinator {
        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private(set) var url: URL

        init(url: URL) {
            self.url = url
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }

        /// Swap the looping item for a new URL (main thread, SwiftUI update).
        func reconfigure(url: URL) {
            self.url = url
            player.pause()
            looper = nil
            player.replaceCurrentItem(with: nil)
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }

        /// Fully release the decoder for view teardown.
        func tearDown() {
            player.pause()
            looper = nil
            player.replaceCurrentItem(with: nil)
        }
    }
}

final class PlayerSurface: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = playerLayer
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); playerLayer.frame = bounds }
}
