import ScreenSaver
import AVFoundation

@objc(LiveLockscreenView)
class LiveLockscreenView: ScreenSaverView {

    private var player: AVQueuePlayer?
    private var playerLayer: AVPlayerLayer?
    private var looper: AVPlayerLooper?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        animationTimeInterval = 1.0 / 30.0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    override func startAnimation() {
        super.startAnimation()

        guard player == nil else { return }

        let bundle = Bundle(for: type(of: self))
        let url: URL? = bundle.url(forResource: "video", withExtension: "mp4")
            ?? bundle.url(forResource: "video", withExtension: "mov")
        guard let url else { return }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(
            asset: asset,
            automaticallyLoadedAssetKeys: ["playable", "duration", "tracks"]
        )
        item.preferredForwardBufferDuration = 5

        let queuePlayer = AVQueuePlayer()
        queuePlayer.isMuted = true
        queuePlayer.automaticallyWaitsToMinimizeStalling = false

        looper = AVPlayerLooper(player: queuePlayer, templateItem: item)

        let layer = AVPlayerLayer(player: queuePlayer)
        layer.frame = bounds
        layer.videoGravity = .resizeAspectFill
        self.layer?.addSublayer(layer)

        player = queuePlayer
        playerLayer = layer
        queuePlayer.play()
    }

    override func stopAnimation() {
        super.stopAnimation()

        player?.pause()
        looper?.disableLooping()
        looper = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        player = nil
    }

    // MARK: - Layout & Drawing

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.black.cgColor
    }

    override func animateOneFrame() {
        // AVPlayer drives rendering; nothing to do here
    }
}
