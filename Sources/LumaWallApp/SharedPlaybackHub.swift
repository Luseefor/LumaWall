import AVFoundation
import CoreVideo
import Foundation
import LumaWallCore
import QuartzCore
import AppKit

@MainActor
final class SharedPlaybackHub {
    private static var hubs: [String: SharedPlaybackHub] = [:]

    let key: String
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let output: AVPlayerItemVideoOutput
    private var layers: [ObjectIdentifier: WeakLayer] = [:]
    private var pumpTimer: Timer?
    private var retainCount = 0
    private var sourceFrameRate: Double = 60
    private(set) var isLoaded = false

    private struct WeakLayer {
        weak var layer: CALayer?
    }

    static func acquire(url: URL) -> SharedPlaybackHub {
        let key = url.standardizedFileURL.path
        if let existing = hubs[key] {
            existing.retainCount += 1
            return existing
        }
        let hub = SharedPlaybackHub(key: key, url: url)
        hubs[key] = hub
        return hub
    }

    private init(key: String, url: URL) {
        self.key = key
        self.retainCount = 1
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ])
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.automaticallyWaitsToMinimizeStalling = false
        configure(url: url)
        startPump()
    }

    func attach(_ layer: CALayer) {
        layers[ObjectIdentifier(layer)] = WeakLayer(layer: layer)
    }

    func detach(_ layer: CALayer) {
        layers.removeValue(forKey: ObjectIdentifier(layer))
    }

    func release() {
        retainCount = max(0, retainCount - 1)
        guard retainCount == 0 else { return }
        stopPump()
        player.pause()
        looper = nil
        player.replaceCurrentItem(with: nil)
        Self.hubs.removeValue(forKey: key)
        isLoaded = false
    }

    func play(rate: Float = 1) {
        player.rate = rate
        player.play()
    }

    func pause() {
        player.pause()
    }

    func setDecodeBudget(bitRate: Double, maximumResolution: CGSize) {
        for item in player.items() {
            item.preferredPeakBitRate = bitRate
            item.preferredMaximumResolution = maximumResolution
        }
    }

    func synchronize(atHostTime hostTime: CMTime) {
        player.setRate(1, time: .zero, atHostTime: hostTime)
    }

    func unload() {
        stopPump()
        player.pause()
        looper = nil
        player.replaceCurrentItem(with: nil)
        isLoaded = false
    }

    static var activeDecoderCount: Int { hubs.count }

    private func configure(url: URL) {
        player.pause()
        looper = nil
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1
        item.add(output)
        looper = AVPlayerLooper(player: player, templateItem: item)
        isLoaded = true
        Task { await refreshSourceFrameRate(for: url) }
    }

    private func refreshSourceFrameRate(for url: URL) async {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let fps = try? await track.load(.nominalFrameRate)
        else { return }
        let rate = Double(fps)
        guard rate.isFinite, rate > 0 else { return }
        sourceFrameRate = rate
        restartPump()
    }

    private func displayMaxFrameRate() -> Double {
        Double(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60)
    }

    private func restartPump() {
        stopPump()
        startPump()
    }

    private func startPump() {
        let interval = PlaybackFrameRate.pumpInterval(
            sourceFPS: sourceFrameRate,
            displayMaxFPS: displayMaxFrameRate()
        )
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pumpFrames() }
        }
        timer.tolerance = min(0.01, interval * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        pumpTimer = timer
    }

    private func stopPump() {
        pumpTimer?.invalidate()
        pumpTimer = nil
    }

    private func pumpFrames() {
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }
        for entry in layers.values {
            entry.layer?.contents = buffer
        }
        layers = layers.filter { $0.value.layer != nil }
    }
}
