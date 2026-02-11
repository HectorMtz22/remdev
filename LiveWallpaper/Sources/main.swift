import Cocoa
import AVFoundation
import UniformTypeIdentifiers

// MARK: - NSScreen Extension

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

// MARK: - Desktop Window

class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Video Player View

class VideoPlayerView: NSView {
    private let playerLayer: AVPlayerLayer

    init(frame: NSRect, player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.frame = bounds
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var windows: [CGDirectDisplayID: DesktopWindow] = [:]
    private var players: [CGDirectDisplayID: AVPlayer] = [:]
    private var loopObservers: [CGDirectDisplayID: Any] = [:]
    private var currentVideoURL: URL?
    private var isPlaying = false
    private var isMuted = true
    private var wasPlayingBeforeSleep = false

    private var playPauseItem: NSMenuItem!
    private var muteItem: NSMenuItem!

    private let defaults = UserDefaults.standard
    private let videoPathKey = "lastVideoPath"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()

        // Restore last video
        if let path = defaults.string(forKey: videoPathKey),
           FileManager.default.fileExists(atPath: path) {
            setVideo(url: URL(fileURLWithPath: path))
        }

        // Watch for display changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        // Pause on display sleep, resume on wake
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(displayDidSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(displayDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    // MARK: - Status Bar

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "play.rectangle.fill",
                accessibilityDescription: "Live Wallpaper"
            )
        }

        let menu = NSMenu()

        menu.addItem(NSMenuItem(
            title: "Select Video...", action: #selector(selectVideo), keyEquivalent: "o"
        ))
        menu.addItem(NSMenuItem.separator())

        playPauseItem = NSMenuItem(
            title: "Pause", action: #selector(togglePlayback), keyEquivalent: "p"
        )
        playPauseItem.isEnabled = false
        menu.addItem(playPauseItem)

        muteItem = NSMenuItem(
            title: "Unmute", action: #selector(toggleMute), keyEquivalent: "m"
        )
        muteItem.isEnabled = false
        menu.addItem(muteItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Remove Wallpaper", action: #selector(removeWallpaper), keyEquivalent: "r"
        ))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(
            title: "Quit", action: #selector(quit), keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    // MARK: - Video Selection

    @objc private func selectVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.movie]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video for your live wallpaper"

        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        defaults.set(url.path, forKey: videoPathKey)
        setVideo(url: url)
    }

    // MARK: - Video Playback

    private func setVideo(url: URL) {
        currentVideoURL = url
        tearDown()

        for screen in NSScreen.screens {
            setupWindow(for: screen, videoURL: url)
        }

        isPlaying = true
        playPauseItem.title = "Pause"
        playPauseItem.isEnabled = true
        muteItem.isEnabled = true
    }

    private func setupWindow(for screen: NSScreen, videoURL: URL) {
        let displayID = screen.displayID

        let window = DesktopWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Place between desktop wallpaper and desktop icons
        window.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1
        )
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        window.setFrame(screen.frame, display: false)

        let player = AVPlayer(url: videoURL)
        player.isMuted = isMuted

        let playerView = VideoPlayerView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            player: player
        )
        playerView.autoresizingMask = [.width, .height]

        window.contentView = playerView
        window.orderFront(nil)

        // Seamless loop
        let observer = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }

        player.play()

        windows[displayID] = window
        players[displayID] = player
        loopObservers[displayID] = observer
    }

    private func tearDown() {
        for (_, observer) in loopObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        loopObservers.removeAll()

        for (_, player) in players {
            player.pause()
        }
        players.removeAll()

        for (_, window) in windows {
            window.close()
        }
        windows.removeAll()
    }

    // MARK: - Controls

    @objc private func togglePlayback() {
        isPlaying.toggle()
        for player in players.values {
            isPlaying ? player.play() : player.pause()
        }
        playPauseItem.title = isPlaying ? "Pause" : "Play"
    }

    @objc private func toggleMute() {
        isMuted.toggle()
        for player in players.values {
            player.isMuted = isMuted
        }
        muteItem.title = isMuted ? "Unmute" : "Mute"
    }

    @objc private func removeWallpaper() {
        tearDown()
        currentVideoURL = nil
        isPlaying = false
        defaults.removeObject(forKey: videoPathKey)
        playPauseItem.title = "Pause"
        playPauseItem.isEnabled = false
        muteItem.isEnabled = false
    }

    // MARK: - Screen & Sleep Handling

    @objc private func screensDidChange() {
        guard let url = currentVideoURL else { return }
        setVideo(url: url)
    }

    @objc private func displayDidSleep() {
        wasPlayingBeforeSleep = isPlaying
        if isPlaying {
            for player in players.values { player.pause() }
            isPlaying = false
        }
    }

    @objc private func displayDidWake() {
        if wasPlayingBeforeSleep {
            for player in players.values { player.play() }
            isPlaying = true
            playPauseItem.title = "Pause"
        }
    }

    @objc private func quit() {
        tearDown()
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
