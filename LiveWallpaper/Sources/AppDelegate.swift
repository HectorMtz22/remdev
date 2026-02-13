import Cocoa
import AVFoundation
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var windows: [CGDirectDisplayID: DesktopWindow] = [:]
    private var engines: [CGDirectDisplayID: VideoEngine] = [:]
    private var currentVideoURL: URL?
    private var isPlaying = false
    private var isMuted = true
    private var wasPlayingBeforeSleep = false
    private var pausedByPowerManager = false

    private var playPauseItem: NSMenuItem!
    private var muteItem: NSMenuItem!
    private var lockscreenItem: NSMenuItem!

    private let defaults = UserDefaults.standard
    private let videoPathKey = "lastVideoPath"
    private let lockscreenKey = "alsoSetLockscreen"

    private var powerManager: PowerManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusBar()

        powerManager = PowerManager()
        powerManager.delegate = self

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

        // Tear down on sleep/lock, rebuild on wake/unlock
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(displayDidSleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(displayDidWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(displayDidSleep),
                       name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(displayDidWake),
                       name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
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

        lockscreenItem = NSMenuItem(
            title: "Also Set as Screen Saver",
            action: #selector(toggleLockscreen),
            keyEquivalent: "l"
        )
        lockscreenItem.state = defaults.bool(forKey: lockscreenKey) ? .on : .off
        menu.addItem(lockscreenItem)

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

        // Validate video is playable before committing
        let asset = AVURLAsset(url: url)
        var isPlayable = false
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                isPlayable = try await asset.load(.isPlayable)
            } catch {
                isPlayable = false
            }
            semaphore.signal()
        }
        semaphore.wait()

        guard isPlayable else {
            showAlert(
                title: "Unplayable Video",
                message: "The selected file cannot be played. Choose a different video."
            )
            return
        }

        defaults.set(url.path, forKey: videoPathKey)
        setVideo(url: url)
    }

    // MARK: - Video Playback

    private func setVideo(url: URL) {
        currentVideoURL = url
        tearDown()

        // Build a map of primary display -> engine, reusing for mirrors
        var primaryEngines: [CGDirectDisplayID: VideoEngine] = [:]

        for screen in NSScreen.screens {
            let displayID = screen.displayID
            let mirrorOf = CGDisplayMirrorsDisplay(displayID)

            if mirrorOf != kCGNullDirectDisplay, let existing = primaryEngines[mirrorOf] {
                // This is a mirrored display — reuse the existing engine's player
                setupWindow(for: screen, player: existing.player)
            } else {
                let engine = VideoEngine(url: url)
                engine.isMuted = isMuted
                engine.delegate = self
                primaryEngines[displayID] = engine
                engines[displayID] = engine
                setupWindow(for: screen, player: engine.player)
            }
        }

        isPlaying = true
        pausedByPowerManager = false
        playPauseItem.title = "Pause"
        playPauseItem.isEnabled = true
        muteItem.isEnabled = true

        // If on low battery right now, pause immediately
        if powerManager.currentState.shouldPausePlayback {
            pauseForPowerSaving()
        }

        if defaults.bool(forKey: lockscreenKey) {
            updateLockscreen(videoURL: url)
        }
    }

    private func setupWindow(for screen: NSScreen, player: AVPlayer) {
        let displayID = screen.displayID

        let window = DesktopWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1
        )
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        window.animationBehavior = .none
        window.setFrame(screen.frame, display: false)

        let playerView = VideoPlayerView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            player: player
        )
        playerView.autoresizingMask = [.width, .height]

        window.contentView = playerView
        window.orderFront(nil)

        windows[displayID] = window
    }

    private func tearDown() {
        for (_, engine) in engines {
            engine.tearDown()
        }
        engines.removeAll()

        for (_, window) in windows {
            window.close()
        }
        windows.removeAll()
    }

    // MARK: - Controls

    @objc private func togglePlayback() {
        isPlaying.toggle()
        pausedByPowerManager = false
        for engine in engines.values {
            isPlaying ? engine.player.play() : engine.player.pause()
        }
        playPauseItem.title = isPlaying ? "Pause" : "Play"
    }

    @objc private func toggleMute() {
        isMuted.toggle()
        for engine in engines.values {
            engine.isMuted = isMuted
        }
        muteItem.title = isMuted ? "Unmute" : "Mute"
    }

    @objc private func toggleLockscreen() {
        let enabled = lockscreenItem.state != .on
        lockscreenItem.state = enabled ? .on : .off
        defaults.set(enabled, forKey: lockscreenKey)

        if enabled, let url = currentVideoURL {
            updateLockscreen(videoURL: url)
        }
    }

    // MARK: - Power Management

    private func pauseForPowerSaving() {
        guard isPlaying else { return }
        pausedByPowerManager = true
        for engine in engines.values {
            engine.player.pause()
        }
        isPlaying = false
        playPauseItem.title = "Play"
    }

    private func resumeFromPowerSaving() {
        guard pausedByPowerManager else { return }
        pausedByPowerManager = false
        for engine in engines.values {
            engine.player.play()
        }
        isPlaying = true
        playPauseItem.title = "Pause"
    }

    // MARK: - Lockscreen Integration

    private func updateLockscreen(videoURL: URL) {
        let fm = FileManager.default
        let saverDest = NSHomeDirectory() + "/Library/Screen Savers/LiveLockscreen.saver"
        let resourcesPath = saverDest + "/Contents/Resources"

        if !fm.fileExists(atPath: saverDest) {
            guard let bundledSaver = Bundle.main.path(forResource: "LiveLockscreen", ofType: "saver") else {
                showAlert(
                    title: "Lock Screen Not Available",
                    message: "LiveLockscreen.saver was not found in the app bundle. Rebuild the app."
                )
                return
            }
            do {
                try fm.copyItem(atPath: bundledSaver, toPath: saverDest)
            } catch {
                showAlert(
                    title: "Installation Failed",
                    message: "Could not install screen saver: \(error.localizedDescription)"
                )
                return
            }
        }

        try? fm.removeItem(atPath: resourcesPath + "/video.mp4")
        try? fm.removeItem(atPath: resourcesPath + "/video.mov")

        let dest = resourcesPath + "/video.\(videoURL.pathExtension)"
        do {
            try fm.copyItem(at: videoURL, to: URL(fileURLWithPath: dest))
        } catch {
            showAlert(
                title: "Video Copy Failed",
                message: error.localizedDescription
            )
            return
        }

        // Run codesign and defaults off the main thread to avoid
        // spinning a nested run loop (which causes SkyLight crashes)
        DispatchQueue.global(qos: .userInitiated).async {
            let signProcess = Process()
            signProcess.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signProcess.arguments = ["--force", "--deep", "--sign", "-", saverDest]
            try? signProcess.run()
            signProcess.waitUntilExit()

            let setProcess = Process()
            setProcess.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
            setProcess.arguments = [
                "-currentHost", "write", "com.apple.screensaver",
                "moduleDict", "-dict",
                "moduleName", "LiveLockscreen",
                "path", saverDest,
                "type", "0"
            ]
            try? setProcess.run()
            setProcess.waitUntilExit()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
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
        guard !windows.isEmpty else { return }
        wasPlayingBeforeSleep = isPlaying
        tearDown()
    }

    @objc private func displayDidWake() {
        guard windows.isEmpty, wasPlayingBeforeSleep, let url = currentVideoURL else { return }
        setVideo(url: url)
    }

    @objc private func quit() {
        tearDown()
        NSApp.terminate(nil)
    }
}

// MARK: - PowerManagerDelegate

extension AppDelegate: PowerManagerDelegate {
    func powerStateDidChange(_ state: PowerState) {
        if state.shouldPausePlayback {
            pauseForPowerSaving()
        } else {
            resumeFromPowerSaving()
        }
    }
}

// MARK: - VideoEngineDelegate

extension AppDelegate: VideoEngineDelegate {
    func videoEngineDidFailPermanently(_ engine: VideoEngine, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.showAlert(
                title: "Playback Failed",
                message: error?.localizedDescription ?? "The video could not be played after multiple retries."
            )
        }
    }
}
