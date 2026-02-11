import ScreenSaver
import AVFoundation

@objc(LiveLockscreenView)
class LiveLockscreenView: ScreenSaverView {

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var loopObserver: NSObjectProtocol?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        animationTimeInterval = 1.0 / 30.0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func startAnimation() {
        super.startAnimation()

        guard player == nil else { return }

        // Bundle(for:) returns this .saver bundle, not the host process
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "video", withExtension: "mp4") else { return }

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true

        let layer = AVPlayerLayer(player: p)
        layer.frame = bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer.videoGravity = .resizeAspectFill
        self.layer?.addSublayer(layer)

        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak p] _ in
            p?.seek(to: .zero)
            p?.play()
        }

        player = p
        playerLayer = layer
        p.play()
    }

    override func stopAnimation() {
        super.stopAnimation()

        player?.pause()
        if let obs = loopObserver {
            NotificationCenter.default.removeObserver(obs)
            loopObserver = nil
        }
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
    }

    // MARK: - Drawing

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()
    }

    override func animateOneFrame() {
        // AVPlayer drives rendering; nothing to do here
    }
}
