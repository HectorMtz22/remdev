import Cocoa
import AVFoundation

class VideoPlayerView: NSView {
    private let playerLayer: AVPlayerLayer

    init(frame: NSRect, player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        playerLayer.frame = bounds
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func replacePlayer(_ player: AVPlayer) {
        playerLayer.player = player
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
