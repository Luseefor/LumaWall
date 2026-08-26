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
    }

    static func dismantleNSView(_ view: PlayerSurface, coordinator: Coordinator) {
        coordinator.player.pause()
        view.playerLayer.player = nil
    }

    final class Coordinator {
        let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?

        init(url: URL) {
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
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
