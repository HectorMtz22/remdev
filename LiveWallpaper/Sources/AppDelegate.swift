import Cocoa
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var windows: [CGDirectDisplayID: DesktopWindow] = [:]
    private var engines: [CGDirectDisplayID: VideoEngine] = [:]
    private var currentVideoURL: URL?
    private var isMuted = true
    private var coordinator: PlaybackCoordinator!

    private var playPauseItem: NSMenuItem!
    private var muteItem: NSMenuItem!
    private var screensaverItem: NSMenuItem!
    private var lockscreenItem: NSMenuItem!
    private var convertItem: NSMenuItem!
    private var autoPauseItem: NSMenuItem!
    private var autoPauseAppsItem: NSMenuItem!
    private var autoPauseAppsMenu: NSMenu!
    private var idleTimeoutMenu: NSMenu!

    private let defaults = UserDefaults.standard
    private let videoPathKey = "lastVideoPath"
    private let screensaverKey = "alsoSetScreensaver"
    private let lockscreenKey = "alsoSetLockscreen"
    private let convertKey = "convertToAerialFormat"
    private let autoPauseKey = "autoPauseWhenInactive"
    private let autoPauseExcludedAppsKey = "autoPauseExcludedApps"
    private let idleTimeoutKey = "idleTimeoutMinutes"

    private var openAtLoginItem: NSMenuItem!

    private var isConvertingLockscreen = false
    private var cachedAerialPath: String? // path to the converted HEVC file
    private var activeAerialTarget: String? // path to the aerial being replaced

    private var powerManager: PowerManager!
    private var systemSleepMonitor: SystemSleepMonitor!
    private var idleMonitor: IdleMonitor!
    private var lastWakeHandled: Date?
    private var screenOffRecheck: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [idleTimeoutKey: 5])

        setupStatusBar()

        powerManager = PowerManager()
        powerManager.delegate = self

        coordinator = PlaybackCoordinator()
        coordinator.delegate = self

        // IOKit system-power notifications — the reliable forced-sleep (lid
        // close) signal. NSWorkspace screens-sleep stays as a second feed into
        // the same coordinator reason.
        systemSleepMonitor = SystemSleepMonitor()
        systemSleepMonitor.delegate = self

        idleMonitor = IdleMonitor()
        idleMonitor.delegate = self
        idleMonitor.setThreshold(minutes: defaults.integer(forKey: idleTimeoutKey))
        syncIdleMonitor(for: coordinator.decision)

        // Restore lockscreen aerial cache if available
        if defaults.bool(forKey: lockscreenKey) {
            let cacheDir = NSHomeDirectory() + "/Library/Application Support/LiveWallpaper"
            let cachePath = cacheDir + "/lockscreen-aerial.mov"
            if FileManager.default.fileExists(atPath: cachePath),
               let aerialID = findActiveAerialID() {
                let aerialsDir = NSHomeDirectory()
                    + "/Library/Application Support/com.apple.wallpaper/aerials/videos"
                cachedAerialPath = cachePath
                activeAerialTarget = aerialsDir + "/\(aerialID).mov"
                reapplyAerialLockscreen()
            }
        }

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

        // Pause when another app is in front, resume when desktop is showing
        ws.addObserver(self, selector: #selector(activeAppDidChange),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)

        // Screen unlock — re-apply aerial after WallpaperAgent restores the original
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(screenDidUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )
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

        autoPauseItem = NSMenuItem(
            title: "Auto-Pause When Inactive",
            action: #selector(toggleAutoPause),
            keyEquivalent: ""
        )
        autoPauseItem.state = defaults.bool(forKey: autoPauseKey) ? .on : .off
        menu.addItem(autoPauseItem)

        autoPauseAppsMenu = NSMenu()
        autoPauseAppsItem = NSMenuItem(
            title: "Pause For...",
            action: nil,
            keyEquivalent: ""
        )
        autoPauseAppsItem.submenu = autoPauseAppsMenu
        autoPauseAppsMenu.delegate = self
        menu.addItem(autoPauseAppsItem)

        idleTimeoutMenu = NSMenu()
        let idleTimeoutItem = NSMenuItem(
            title: "Idle Timeout",
            action: nil,
            keyEquivalent: ""
        )
        idleTimeoutItem.submenu = idleTimeoutMenu
        menu.addItem(idleTimeoutItem)
        let currentTimeout = defaults.integer(forKey: idleTimeoutKey)
        for (title, minutes) in [("Off", 0), ("2 min", 2), ("5 min", 5), ("10 min", 10)] {
            let item = NSMenuItem(
                title: title,
                action: #selector(selectIdleTimeout(_:)),
                keyEquivalent: ""
            )
            item.tag = minutes
            item.state = minutes == currentTimeout ? .on : .off
            idleTimeoutMenu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())

        screensaverItem = NSMenuItem(
            title: "Also Set as Screen Saver",
            action: #selector(toggleScreensaver),
            keyEquivalent: "s"
        )
        screensaverItem.state = defaults.bool(forKey: screensaverKey) ? .on : .off
        menu.addItem(screensaverItem)

        lockscreenItem = NSMenuItem(
            title: "Also Set as Lock Screen",
            action: #selector(toggleLockscreen),
            keyEquivalent: "l"
        )
        lockscreenItem.state = defaults.bool(forKey: lockscreenKey) ? .on : .off
        menu.addItem(lockscreenItem)

        menu.addItem(NSMenuItem.separator())

        let experimentalHeader = NSMenuItem(title: "Experimental", action: nil, keyEquivalent: "")
        experimentalHeader.isEnabled = false
        menu.addItem(experimentalHeader)

        convertItem = NSMenuItem(
            title: "Convert to Aerial Format (ffmpeg)",
            action: #selector(toggleConvert),
            keyEquivalent: ""
        )
        convertItem.state = defaults.bool(forKey: convertKey) ? .on : .off
        menu.addItem(convertItem)

        menu.addItem(NSMenuItem.separator())

        openAtLoginItem = NSMenuItem(
            title: "Open at Login",
            action: #selector(toggleOpenAtLogin),
            keyEquivalent: ""
        )
        openAtLoginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(openAtLoginItem)

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

        // Validate video is playable before committing (async to avoid blocking main thread)
        let asset = AVURLAsset(url: url)
        Task { @MainActor in
            let isPlayable = (try? await asset.load(.isPlayable)) ?? false
            guard isPlayable else {
                showAlert(
                    title: "Unplayable Video",
                    message: "The selected file cannot be played. Choose a different video."
                )
                return
            }

            defaults.set(url.path, forKey: videoPathKey)
            setVideo(url: url)

            if defaults.bool(forKey: screensaverKey) {
                updateScreensaver(videoURL: url)
            }
            if defaults.bool(forKey: lockscreenKey) {
                updateAerialLockscreen(videoURL: url)
            }
        }
    }

    // MARK: - Video Playback

    private func setVideo(url: URL) {
        currentVideoURL = url
        tearDown()

        let activeScreens = NSScreen.screens.filter { $0.isActive }

        // Every display went inactive (lid closed, etc.) — nothing to play
        // on. Don't build an engine; flag screen-off so the coordinator holds
        // the teardown decision until a display wakes, and drop menu state to
        // the no-engine baseline.
        if activeScreens.isEmpty {
            coordinator.clearAllReasons()
            coordinator.setReason(.screenOff)
            playPauseItem.isEnabled = false
            muteItem.isEnabled = false
            return
        }

        // Single engine for all displays — one decode pipeline, multiple layers
        // Decode at the largest active display's backing pixel size, not the
        // video's native res. Only active (awake + drawable) displays
        // contribute; an asleep display can still appear in NSScreen.screens.
        let engine = makeEngine(url: url)
        for screen in activeScreens {
            engines[screen.displayID] = engine
            setupWindow(for: screen, player: engine.player)
        }

        coordinator.clearAllReasons()
        playPauseItem.isEnabled = true
        muteItem.isEnabled = true

        // If on low battery right now, pause immediately
        if powerManager.currentState.shouldPausePlayback {
            coordinator.setReason(.power)
        }

        // A user's explicit pause survives rebuilds (sleep/wake, screen changes);
        // weaker signals re-assert naturally. Apply the current decision to the
        // fresh engine — clearAllReasons() alone may not have changed it.
        applyDecision(coordinator.decision)
    }

    /// The single engine-construction path: decode resolution from the
    /// largest active display, player-recreation wiring, mute/delegate state.
    /// Every engine (re)creation must go through here so a fresh engine is
    /// always fully configured.
    private func makeEngine(url: URL) -> VideoEngine {
        let maxRes = NSScreen.screens
            .filter { $0.isActive }
            .map { CGSize(width: $0.frame.width * $0.backingScaleFactor,
                          height: $0.frame.height * $0.backingScaleFactor) }
            .max { $0.width * $0.height < $1.width * $1.height }
        let engine = VideoEngine(url: url, maxResolution: maxRes)
        engine.isMuted = isMuted
        engine.delegate = self
        engine.onPlayerRecreated = { [weak self] newPlayer in
            guard let self else { return }
            for window in self.windows.values {
                (window.contentView as? VideoPlayerView)?.replacePlayer(newPlayer)
            }
        }
        return engine
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
        // Deduplicate since multiple displays share the same engine
        var seen = Set<ObjectIdentifier>()
        for engine in engines.values {
            if seen.insert(ObjectIdentifier(engine)).inserted {
                engine.tearDown()
            }
        }
        engines.removeAll()

        for (_, window) in windows {
            window.close()
        }
        windows.removeAll()
    }

    // MARK: - Controls

    @objc private func togglePlayback() {
        if coordinator.userPaused {
            coordinator.userResume()
        } else {
            coordinator.userPause()
        }
    }

    @objc private func toggleMute() {
        isMuted.toggle()
        if let engine = engines.values.first {
            engine.isMuted = isMuted
        }
        muteItem.title = isMuted ? "Unmute" : "Mute"
    }

    // MARK: - Occlusion Pause

    @objc private func toggleAutoPause() {
        let enabled = autoPauseItem.state != .on
        autoPauseItem.state = enabled ? .on : .off
        defaults.set(enabled, forKey: autoPauseKey)
        // If disabling while auto-paused by occlusion, resume playback
        if !enabled && coordinator.activeReasons.contains(.occlusion) {
            coordinator.clearReason(.occlusion)
        }
    }

    @objc private func activeAppDidChange(_ notification: Notification) {
        guard defaults.bool(forKey: autoPauseKey) else { return }
        guard !windows.isEmpty else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let isDesktop = app.bundleIdentifier == "com.apple.finder"
        let excluded = Set(defaults.stringArray(forKey: autoPauseExcludedAppsKey) ?? [])
        let isExcluded = app.bundleIdentifier.map { excluded.contains($0) } ?? false
        if !isDesktop && !isExcluded {
            coordinator.setReason(.occlusion)
        } else {
            coordinator.clearReason(.occlusion)
        }
    }

    // MARK: - Idle Timeout

    @objc private func selectIdleTimeout(_ sender: NSMenuItem) {
        let minutes = sender.tag
        for item in idleTimeoutMenu.items {
            item.state = item.tag == minutes ? .on : .off
        }
        defaults.set(minutes, forKey: idleTimeoutKey)
        idleMonitor.setThreshold(minutes: minutes)
        // A threshold change re-arms the monitor and re-evaluates the live
        // idle state; syncing against the current decision also handles the
        // paused cases (e.g. selecting Off while idle-paused resumes).
        idleMonitor.reevaluate()
        syncIdleMonitor(for: coordinator.decision)
    }

    /// Drives the monitor from the coordinator's decision: poll while
    /// playback is wanted, and keep polling while paused solely by idle so
    /// activity can resume. For any other pause cause, stop polling and drop
    /// a stale `.idle` reason — it re-asserts via a fresh signal when
    /// playback is wanted again.
    private func syncIdleMonitor(for decision: PlaybackDecision) {
        if decision == .play {
            idleMonitor.start()
            return
        }
        if coordinator.activeReasons == [.idle], idleMonitor.isEnabled {
            idleMonitor.start()
            return
        }
        idleMonitor.stop()
        coordinator.clearReason(.idle)
    }

    @objc private func toggleScreensaver() {
        let enabled = screensaverItem.state != .on
        screensaverItem.state = enabled ? .on : .off
        defaults.set(enabled, forKey: screensaverKey)

        if enabled, let url = currentVideoURL {
            updateScreensaver(videoURL: url)
        }
    }

    @objc private func toggleLockscreen() {
        let enabled = lockscreenItem.state != .on
        lockscreenItem.state = enabled ? .on : .off
        defaults.set(enabled, forKey: lockscreenKey)

        if enabled, let url = currentVideoURL {
            updateAerialLockscreen(videoURL: url)
        }
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Failed to toggle login item: \(error)")
        }
        openAtLoginItem.state = service.status == .enabled ? .on : .off
    }

    @objc private func toggleConvert() {
        let enabled = convertItem.state != .on
        convertItem.state = enabled ? .on : .off
        defaults.set(enabled, forKey: convertKey)
    }

    // MARK: - Power Management

    private func resumeFromPowerSaving() {
        coordinator.clearReason(.power)
    }

    // MARK: - Screen Saver Integration

    private func updateScreensaver(videoURL: URL) {
        let fm = FileManager.default
        let saverDest = NSHomeDirectory() + "/Library/Screen Savers/LiveLockscreen.saver"
        let resourcesPath = saverDest + "/Contents/Resources"

        if !fm.fileExists(atPath: saverDest) {
            guard let bundledSaver = Bundle.main.path(forResource: "LiveLockscreen", ofType: "saver") else {
                showAlert(
                    title: "Screen Saver Not Available",
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

    // MARK: - Lock Screen (Aerial Replacement)

    private func findActiveAerialID() -> String? {
        let plistPath = NSHomeDirectory()
            + "/Library/Application Support/com.apple.wallpaper/Store/Index.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let allSpaces = plist["AllSpacesAndDisplays"] as? [String: Any]
        else { return nil }

        // macOS 14–15 uses "Desktop", macOS 26+ uses "Linked"
        let container = (allSpaces["Desktop"] ?? allSpaces["Linked"]) as? [String: Any]

        guard let content = container?["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let first = choices.first,
              let configData = first["Configuration"] as? Data,
              let config = try? PropertyListSerialization.propertyList(
                  from: configData, options: [], format: nil
              ) as? [String: Any],
              let assetID = config["assetID"] as? String
        else { return nil }
        return assetID
    }

    private func updateAerialLockscreen(videoURL: URL) {
        let aerialsDir = NSHomeDirectory()
            + "/Library/Application Support/com.apple.wallpaper/aerials/videos"

        guard let aerialID = findActiveAerialID() else {
            showAlert(
                title: "No Active Aerial",
                message: "Could not detect the active aerial wallpaper. Select an aerial wallpaper in System Settings first."
            )
            return
        }

        let targetFile = aerialsDir + "/\(aerialID).mov"
        guard FileManager.default.fileExists(atPath: targetFile) else {
            showAlert(
                title: "Aerial Not Downloaded",
                message: "The active aerial video is not downloaded yet. Open System Settings > Wallpaper and ensure it's downloaded."
            )
            return
        }

        // Backup original if needed
        let backupFile = targetFile + ".bak"
        if !FileManager.default.fileExists(atPath: backupFile) {
            try? FileManager.default.copyItem(atPath: targetFile, toPath: backupFile)
        }

        let shouldConvert = defaults.bool(forKey: convertKey)
        let inputPath = videoURL.path

        if shouldConvert {
            // Full ffmpeg HEVC conversion
            guard !isConvertingLockscreen else {
                showAlert(
                    title: "Conversion In Progress",
                    message: "A lock screen video conversion is already running. Please wait."
                )
                return
            }

            let ffmpegPath: String
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") {
                ffmpegPath = "/opt/homebrew/bin/ffmpeg"
            } else if FileManager.default.fileExists(atPath: "/usr/local/bin/ffmpeg") {
                ffmpegPath = "/usr/local/bin/ffmpeg"
            } else {
                showAlert(
                    title: "ffmpeg Required",
                    message: "Install ffmpeg for aerial format conversion:\n\nbrew install ffmpeg"
                )
                return
            }

            isConvertingLockscreen = true
            lockscreenItem.title = "Lock Screen: Converting..."

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let tmpFile = NSTemporaryDirectory() + "aerial-\(UUID().uuidString).mov"

                let ffmpeg = Process()
                ffmpeg.executableURL = URL(fileURLWithPath: ffmpegPath)
                ffmpeg.arguments = [
                    "-y", "-i", inputPath,
                    "-c:v", "hevc_videotoolbox", "-profile:v", "main10",
                    "-b:v", "12000k", "-maxrate", "16000k", "-bufsize", "24000k",
                    "-tag:v", "hvc1",
                    "-pix_fmt", "p010le",
                    "-vf", "scale=3840:2160:force_original_aspect_ratio=decrease,pad=3840:2160:(ow-iw)/2:(oh-ih)/2,fps=240",
                    "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
                    "-an",
                    tmpFile
                ]
                ffmpeg.standardOutput = FileHandle.nullDevice
                ffmpeg.standardError = FileHandle.nullDevice

                do {
                    try ffmpeg.run()
                    ffmpeg.waitUntilExit()

                    guard ffmpeg.terminationStatus == 0 else {
                        throw NSError(domain: "LiveWallpaper", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: "ffmpeg exited with code \(ffmpeg.terminationStatus)"])
                    }

                    let cacheDir = NSHomeDirectory()
                        + "/Library/Application Support/LiveWallpaper"
                    try FileManager.default.createDirectory(
                        atPath: cacheDir, withIntermediateDirectories: true)
                    let cachePath = cacheDir + "/lockscreen-aerial.mov"
                    try? FileManager.default.removeItem(atPath: cachePath)
                    try FileManager.default.moveItem(atPath: tmpFile, toPath: cachePath)

                    try? FileManager.default.removeItem(atPath: targetFile)
                    try FileManager.default.copyItem(atPath: cachePath, toPath: targetFile)
                    Self.restartWallpaperAgent()

                    DispatchQueue.main.async {
                        self?.isConvertingLockscreen = false
                        self?.cachedAerialPath = cachePath
                        self?.activeAerialTarget = targetFile
                        self?.lockscreenItem.title = "Also Set as Lock Screen"
                    }
                } catch {
                    try? FileManager.default.removeItem(atPath: tmpFile)
                    DispatchQueue.main.async {
                        self?.isConvertingLockscreen = false
                        self?.lockscreenItem.title = "Also Set as Lock Screen"
                        self?.showAlert(
                            title: "Lock Screen Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        } else {
            // Direct copy — no conversion (off main thread for large files)
            let cacheDir = NSHomeDirectory()
                + "/Library/Application Support/LiveWallpaper"
            let cachePath = cacheDir + "/lockscreen-aerial.mov"

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                do {
                    try FileManager.default.createDirectory(
                        atPath: cacheDir, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(atPath: cachePath)
                    try FileManager.default.copyItem(atPath: inputPath, toPath: cachePath)

                    try? FileManager.default.removeItem(atPath: targetFile)
                    try FileManager.default.copyItem(atPath: cachePath, toPath: targetFile)

                    Self.restartWallpaperAgent()

                    DispatchQueue.main.async {
                        self?.cachedAerialPath = cachePath
                        self?.activeAerialTarget = targetFile
                    }
                } catch {
                    DispatchQueue.main.async {
                        self?.showAlert(
                            title: "Lock Screen Failed",
                            message: error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    private static func restartWallpaperAgent() {
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["WallpaperAgent"]
        try? killall.run()
        killall.waitUntilExit()
    }

    /// Re-copy the cached converted aerial over the target (fast, no ffmpeg)
    private func reapplyAerialLockscreen() {
        guard defaults.bool(forKey: lockscreenKey),
              let cache = cachedAerialPath,
              let target = activeAerialTarget,
              FileManager.default.fileExists(atPath: cache)
        else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.removeItem(atPath: target)
            try? FileManager.default.copyItem(atPath: cache, toPath: target)
            Self.restartWallpaperAgent()
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
        coordinator.clearAllReasons()
        defaults.removeObject(forKey: videoPathKey)
        playPauseItem.isEnabled = false
        muteItem.isEnabled = false
    }

    // MARK: - Screen & Sleep Handling

    @objc private func screensDidChange() {
        guard let url = currentVideoURL else { return }

        // A topology change (display connected/disconnected/resolution
        // change) — but display sleep/wake alone is not a topology change,
        // and NSScreen.screens keeps listing asleep displays. Detect whether
        // the *active* layout actually changed (frame or backing scale of any
        // active display, vs. the window we hold for it) and let the shared
        // reconcile/rebuild paths do the work.
        let activeScreens = NSScreen.screens.filter { $0.isActive }
        let layoutChanged = activeScreens.contains { screen in
            guard let window = windows[screen.displayID] else { return true }
            return window.frame != screen.frame
                || window.screen?.backingScaleFactor != screen.backingScaleFactor
        }
        let hadNoWindows = windows.isEmpty

        reconcileDisplayActivity()

        // reconcileDisplayActivity already did a full setVideo() rebuild if we
        // came in with no windows and active displays — don't rebuild twice.
        if layoutChanged && !(hadNoWindows && !activeScreens.isEmpty) {
            // Layout actually changed — full rebuild so the engine decodes at
            // the right resolution and every display gets a fresh window
            setVideo(url: url)
        }
    }

    @objc private func displayDidSleep() {
        guard !windows.isEmpty else { return }
        coordinator.setReason(.sleep)
    }

    @objc private func displayDidWake() {
        handleSystemWake()
    }

    /// Shared wake path for both the NSWorkspace screens-wake signal and the
    /// IOKit SystemSleepMonitor — one place for aerial reapply, reason
    /// clearing, and engine rebuild. Both signals fire on a normal wake, so
    /// back-to-back calls within a short window are treated as one event.
    private func handleSystemWake() {
        if let last = lastWakeHandled, Date().timeIntervalSince(last) < 1.0 {
            return
        }
        lastWakeHandled = Date()

        reapplyAerialLockscreen()

        coordinator.clearReason(.sleep)

        guard let url = currentVideoURL else { return }

        reconcileDisplayActivity()

        if windows.isEmpty {
            // Windows were torn down during sleep — rebuild them and let the
            // coordinator's current decision decide whether playback resumes
            setVideo(url: url)
        } else {
            // Windows still exist (lock without sleep) — restart engine
            // if the player stalled while the display was off
            if let engine = engines.values.first,
               engine.player.timeControlStatus != .playing,
               coordinator.decision == .play {
                setVideo(url: url)
            }
        }
    }

    /// Brings windows in line with display activity: creates windows for
    /// displays that woke, tears down windows for displays that went asleep,
    /// and drives the coordinator's `.screenOff` reason. Runs after sleep
    /// wake and from `screensDidChange`.
    private func reconcileDisplayActivity() {
        let activeScreens = NSScreen.screens.filter { $0.isActive }

        // Tear down windows for displays that are no longer active (a
        // disconnected display reports no screen at all — also torn down)
        for (displayID, window) in windows where window.screen?.isActive != true {
            window.close()
            windows.removeValue(forKey: displayID)
            engines.removeValue(forKey: displayID)
        }

        if windows.isEmpty {
            if activeScreens.isEmpty {
                // Every display is inactive — full teardown (also drops the
                // engine) and hold the teardown decision via `.screenOff`
                // until a display becomes active again.
                tearDown()
                coordinator.setReason(.screenOff)
                // A wake can be read while a display still reports inactive —
                // schedule one re-check so recovery doesn't depend on a
                // topology notification that may never fire.
                scheduleScreenOffRecheck()
            } else if currentVideoURL != nil {
                // Displays are active but we hold no windows (full teardown
                // during sleep, or a stale wake read). Rebuild via setVideo —
                // it creates the engine through the shared path and enforces
                // the coordinator's decision on it.
                setVideo(url: currentVideoURL!)
            }
            return
        }

        // Create windows for newly active displays that have none. The engine
        // is shared — every display maps to it.
        for screen in activeScreens where windows[screen.displayID] == nil {
            guard let engine = engines.values.first ?? currentVideoURL.map({ makeEngine(url: $0) }) else { return }
            engines[screen.displayID] = engine
            setupWindow(for: screen, player: engine.player)
        }

        coordinator.clearReason(.screenOff)
    }

    /// CGDisplayIsActive can lag the actual wake on the main run loop; a wake
    /// read as "still inactive" would strand the app in the `.screenOff`
    /// teardown state with no topology notification guaranteed to follow.
    /// Schedule one re-check (deduplicated) so recovery doesn't depend on it.
    private func scheduleScreenOffRecheck() {
        screenOffRecheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.screenOffRecheck = nil
            guard self.windows.isEmpty,
                  NSScreen.screens.contains(where: { $0.isActive }),
                  self.currentVideoURL != nil else { return }
            self.reconcileDisplayActivity()
        }
        screenOffRecheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    @objc private func screenDidUnlock() {
        // Delay to let WallpaperAgent finish restoring the original aerial,
        // then overwrite it again with our cached version
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.reapplyAerialLockscreen()
        }
    }

    @objc private func quit() {
        tearDown()
        NSApp.terminate(nil)
    }
}

// MARK: - PlaybackCoordinatorDelegate

extension AppDelegate: PlaybackCoordinatorDelegate {
    func playbackCoordinatorDidChangeDecision(
        _ coordinator: PlaybackCoordinator,
        decision: PlaybackDecision
    ) {
        applyDecision(decision)
    }

    /// Applies the coordinator's decision to the engine and updates menu state.
    /// This is the single write path for playback state and menu titles.
    private func applyDecision(_ decision: PlaybackDecision) {
        syncIdleMonitor(for: decision)
        switch decision {
        case .play:
            if let engine = engines.values.first,
               let item = engine.player.currentItem,
               item.status != .failed {
                engine.player.play()
            } else if let url = currentVideoURL {
                setVideo(url: url)
                return
            }
        case .pause:
            engines.values.first?.player.pause()
        case .teardown:
            tearDown()
        }
        // With no engine loaded there is nothing to reflect in the menu
        // (e.g. battery crosses 20% before any video was selected).
        guard !engines.isEmpty else { return }
        playPauseItem.title = decision == .play ? "Pause" : "Play"
    }
}

// MARK: - SystemSleepMonitorDelegate

extension AppDelegate: SystemSleepMonitorDelegate {
    func systemSleepMonitorDidSleep() {
        coordinator.setReason(.sleep)
    }

    func systemSleepMonitorDidWake() {
        handleSystemWake()
    }
}

// MARK: - IdleMonitorDelegate

extension AppDelegate: IdleMonitorDelegate {
    func idleMonitorDidBecomeIdle() {
        coordinator.setReason(.idle)
    }

    func idleMonitorDidBecomeActive() {
        coordinator.clearReason(.idle)
    }
}

// MARK: - PowerManagerDelegate

extension AppDelegate: PowerManagerDelegate {
    func powerStateDidChange(_ state: PowerState) {
        if state.shouldPausePlayback {
            coordinator.setReason(.power)
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

// MARK: - Auto-Pause App List

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu == autoPauseAppsMenu else { return }
        menu.removeAllItems()

        let excluded = Set(defaults.stringArray(forKey: autoPauseExcludedAppsKey) ?? [])
        let runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }

        for app in runningApps {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != "com.apple.finder" else { continue }
            let name = app.localizedName ?? bundleID
            let item = NSMenuItem(title: name, action: #selector(toggleAutoPauseApp(_:)), keyEquivalent: "")
            item.representedObject = bundleID
            item.state = excluded.contains(bundleID) ? .off : .on
            if let icon = app.icon {
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
            }
            menu.addItem(item)
        }
    }

    @objc private func toggleAutoPauseApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        var excluded = Set(defaults.stringArray(forKey: autoPauseExcludedAppsKey) ?? [])
        if excluded.contains(bundleID) {
            excluded.remove(bundleID)
        } else {
            excluded.insert(bundleID)
        }
        defaults.set(Array(excluded), forKey: autoPauseExcludedAppsKey)

        // If we just excluded the currently active app while paused by it, resume
        if excluded.contains(bundleID),
           let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.bundleIdentifier == bundleID {
            coordinator.clearReason(.occlusion)
        }
    }
}
