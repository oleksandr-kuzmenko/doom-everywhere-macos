import AppKit

final class DoomApplication: NSApplication {
    var input: ((NSEvent) -> Bool)?
    override func sendEvent(_ event: NSEvent) {
        if isActive, [.keyDown, .keyUp, .flagsChanged].contains(event.type), input?(event) == true { return }
        super.sendEvent(event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let dockView = DockFrameView()
    let staticDockView = NSImageView()
    let desktop = DesktopPresentation()
    let gameWindow = WindowPresentation()
    var facePixels = [UInt8](repeating: 0, count: Int(DD_FACE_SIZE) * Int(DD_FACE_SIZE) * 4)
    var faceFrame: CGImage?
    var screenObserver: NSObjectProtocol?
    var menuBarMode = UserDefaults.standard.string(forKey: "menuBarMode") ?? "face"
    var effectiveMenuBarMode: String { displayMode == "menubar" ? "game" : menuBarMode }
    var status: NSStatusItem!
    var timer: Timer?
    var pixels = [UInt8](repeating: 0, count: Int(DD_WIDTH) * Int(DD_HEIGHT) * 4)
    var serial: UInt64 = 0
    var cgFrame: CGImage?
    let targetFPS = 30
    var submitted = 0
    var reportTime = ProcessInfo.processInfo.systemUptime
    var submittedFPS = 0.0
    var manuallyPaused = false, sleeping = false, menuOpen = false, quitting = false
    var engineStarted = false
    var startupError: String?
    var held: [UInt16: UInt8] = [:]
    var modifierKeys = Set<UInt8>()
    var previousApp: NSRunningApplication?
    var focusRequest = 0, clicks = 0, activations = 0, keyEvents = 0
    var focusResult = "idle"
    var displayMode = UserDefaults.standard.string(forKey: "displayMode") ?? "dock"
    var soundMuted = UserDefaults.standard.bool(forKey: "soundMuted")
    var lastAmmo = -1
    var activity: NSObjectProtocol?
    var observers = [NSObjectProtocol]()
    var saveDirectory: URL!

    func argument(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap({ NSImage(contentsOf: $0) }) {
            NSApp.applicationIconImage = icon
            staticDockView.image = icon
        }
        installMainMenu()
        status = NSStatusBar.system.statusItem(withLength: 40)
        let button = status.button!
        button.target = self; button.action = #selector(statusClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel("DOOM for macOS — click to play, right-click for controls")
        button.toolTip = "DOOM is in the Dock • Click to focus • Right-click for controls"
        dockView.frame = NSRect(origin: .zero, size: NSApp.dockTile.size)
        dockView.autoresizingMask = [.width, .height]
        staticDockView.frame = dockView.frame
        staticDockView.autoresizingMask = [.width, .height]
        staticDockView.imageScaling = .scaleProportionallyUpOrDown
        if let requested = argument("--presentation"), ["dock", "menubar", "both", "desktop", "window"].contains(requested) { displayMode = requested }
        if displayMode == "both" { displayMode = "dock"; menuBarMode = "game" }
        if !["dock", "menubar", "desktop", "window"].contains(displayMode) { displayMode = "dock" }
        if let requested = argument("--menu-bar"), ["face", "game"].contains(requested) { menuBarMode = requested }
        if !["face", "game"].contains(menuBarMode) { menuBarMode = "face" }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            self.desktop.update(enabled: self.displayMode == "desktop", image: self.dockView.image)
        }
        gameWindow.onClose = { [weak self] in
            guard let self = self, self.displayMode == "window" else { return }
            self.displayMode = "dock"
            UserDefaults.standard.set("dock", forKey: "displayMode")
            self.releaseKeys(); self.applyPresentation(); self.updatePause()
        }
        gameWindow.onVisibilityChange = { [weak self] in self?.releaseKeys(); self?.updatePause() }
        applyPresentation()
        DD_AudioMute(soundMuted ? 1 : 0)
        (NSApp as! DoomApplication).input = { [weak self] in self?.handle($0) ?? false }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sleeping = true; self?.releaseKeys(); self?.updatePause()
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.sleeping = false; self?.updatePause()
            })
        }
        do {
            saveDirectory = argument("--data-dir").map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DockDOOM", isDirectory: true)
            try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
            let wad = argument("--iwad") ?? Bundle.main.url(forResource: "DOOM1", withExtension: "WAD")?.path
            guard let wad = wad, FileManager.default.isReadableFile(atPath: wad) else {
                throw NSError(domain: "DOOM for macOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "WAD missing. Rebuild with assets/DOOM1.WAD or launch with --iwad /path/to/game.wad."])
            }
            // Engine stdout/stderr are useful even when launched from Finder.
            let log = saveDirectory.appendingPathComponent("engine.log").path
            freopen(log, "w", stdout); freopen(log, "a", stderr)
            setvbuf(stdout, nil, _IOLBF, 0)
            engineStarted = DD_Start(wad, saveDirectory.path, CommandLine.arguments.contains("--title-screen") ? 0 : 1) != 0
            if !engineStarted { startupError = engineError() }
        } catch { startupError = error.localizedDescription }
        restartTimer()
        updateTitle()
    }

    func installMainMenu() {
        let menu = NSMenu(); let root = NSMenuItem(title: "DOOM for macOS", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        let release = NSMenuItem(title: "Release Keyboard", action: #selector(releaseFocus), keyEquivalent: "\u{1b}")
        release.target = self; appMenu.addItem(release)
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Hide DOOM for macOS", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit DOOM for macOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        root.submenu = appMenu; menu.addItem(root); NSApp.mainMenu = menu
    }

    func restartTimer() {
        timer?.invalidate()
        let value = Timer(timeInterval: 1.0 / Double(targetFPS), repeats: true) { [weak self] _ in self?.tick() }
        value.tolerance = 0.001; RunLoop.main.add(value, forMode: .common); timer = value
        reportTime = ProcessInfo.processInfo.systemUptime; submitted = 0
    }

    func tick() {
        let stats = DD_GetStats()
        lastAmmo = Int(stats.ammo)
        if stats.finished != 0 {
            if stats.failed != 0 { startupError = engineError() }
            else if engineStarted && !quitting { NSApp.terminate(nil); return }
            if quitting { DD_Join(); NSApp.reply(toApplicationShouldTerminate: true); return }
        }
        if DD_CopyFrame(&pixels, pixels.count, &serial) != 0 {
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let cg = CGImage(width: Int(DD_WIDTH), height: Int(DD_HEIGHT), bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: Int(DD_WIDTH) * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            cgFrame = cg
            dockView.image = NSImage(cgImage: cg, size: NSSize(width: 320, height: 240))
            if displayMode == "dock" { NSApp.dockTile.display() }
            desktop.setImage(dockView.image)
            gameWindow.setImage(dockView.image)
            if DD_CopyFace(&facePixels, facePixels.count) != 0 {
                let faceProvider = CGDataProvider(data: Data(facePixels) as CFData)!
                faceFrame = CGImage(width: Int(DD_FACE_SIZE), height: Int(DD_FACE_SIZE), bitsPerComponent: 8,
                                    bitsPerPixel: 32, bytesPerRow: Int(DD_FACE_SIZE) * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                    provider: faceProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            } else { faceFrame = nil }
            updateMenuBarImage()
            submitted += 1
            updatePause() // Allow initialization to publish a first frame before pausing.
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - reportTime >= 1 {
            submittedFPS = Double(submitted) / (now - reportTime)
            reportTime = now; submitted = 0; updateTitle(); writeDiagnostics(stats)
        }
    }

    func engineError() -> String {
        var buffer = [CChar](repeating: 0, count: 512); DD_GetError(&buffer, buffer.count)
        return String(cString: buffer)
    }
    func updateTitle() {
        let state = manuallyPaused || sleeping || menuOpen || !NSApp.isActive
            || (displayMode == "window" && gameWindow.window?.isMiniaturized == true) ? "Paused" : "Playing"
        let ammo = lastAmmo >= 0 ? String(lastAmmo) : "—"
        let description = startupError.map { "DOOM: \($0)" }
            ?? "DOOM · \(state) · Ammo: \(ammo) · Click to play · Right-click for options"
        status?.button?.title = ""
        status?.button?.toolTip = description
        status?.button?.setAccessibilityLabel(description)
        NSApp.dockTile.badgeLabel = startupError != nil ? "!" : (manuallyPaused ? "Ⅱ" : nil)
    }
    func updateMenuBarImage() {
        let image: NSImage?
        switch effectiveMenuBarMode {
        case "game": image = cgFrame.map { NSImage(cgImage: $0, size: NSSize(width: 24, height: 18)) }
        case "face": image = faceFrame.map { NSImage(cgImage: $0, size: NSSize(width: 20, height: 22)) }
        default: image = nil
        }
        image?.isTemplate = false
        // Keep a visible activation target on title/intermission screens without a face.
        status?.button?.image = image ?? NSImage(systemSymbolName: "flame.fill", accessibilityDescription: "DOOM")
    }
    func applyPresentation() {
        NSApp.dockTile.contentView = displayMode == "dock" ? dockView : staticDockView
        NSApp.dockTile.display()
        desktop.update(enabled: displayMode == "desktop", image: dockView.image)
        gameWindow.update(enabled: displayMode == "window", image: dockView.image)
        updateTitle()
        updateMenuBarImage()
    }
    @objc func changePresentation(_ sender: NSMenuItem) {
        displayMode = ["dock", "desktop", "menubar", "window"][sender.tag]
        UserDefaults.standard.set(displayMode, forKey: "displayMode")
        applyPresentation()
        updatePause()
    }
    @objc func changeMenuBar(_ sender: NSMenuItem) {
        menuBarMode = ["face", "game"][sender.tag]
        UserDefaults.standard.set(menuBarMode, forKey: "menuBarMode")
        updateMenuBarImage()
    }
    @objc func toggleSound() {
        soundMuted.toggle(); UserDefaults.standard.set(soundMuted, forKey: "soundMuted")
        DD_AudioMute(soundMuted ? 1 : 0)
    }
    func updatePause() {
        let shouldPause = manuallyPaused || sleeping || menuOpen || !NSApp.isActive
            || (displayMode == "window" && gameWindow.window?.isMiniaturized == true)
        if engineStarted && serial > 0 { DD_SetPaused(shouldPause ? 1 : 0) }
        if shouldPause, let token = activity { ProcessInfo.processInfo.endActivity(token); activity = nil }
        if !shouldPause && activity == nil && engineStarted {
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Playing DOOM")
        }
        updateTitle()
    }

    // Physical key codes work independently of the active Ukrainian/English layout.
    func doomKey(_ code: UInt16) -> UInt8? {
        switch code {
        case 13, 126: return 0xad // W / up
        case 1, 125: return 0xaf // S / down
        case 123: return 0xac
        case 124: return 0xae
        case 0: return 0xa0 // A strafe left
        case 2: return 0xa1 // D strafe right
        case 49, 14: return 0xa2 // Space / E use
        case 3: return 0xa3 // F fire (Ctrl also fires)
        case 53: return 27
        case 36, 76: return 13
        case 48: return 9
        case 51: return 127
        case 18: return 49
        case 19: return 50
        case 20: return 51
        case 21: return 52
        case 23: return 53
        case 22: return 54
        case 26: return 55
        case 16: return 121 // Y confirms game prompts
        case 45: return 110 // N
        case 24: return 61
        case 27: return 45
        default: return nil
        }
    }
    func handle(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { releaseKeys(); return false }
        guard !menuOpen, !manuallyPaused, startupError == nil,
              !(displayMode == "window" && gameWindow.window?.isMiniaturized == true) else { return false }
        if event.type == .flagsChanged {
            let flags: [(NSEvent.ModifierFlags, UInt8)] = [(.shift, 0xb6), (.control, 0xa3), (.option, 0xb8)]
            for (flag, key) in flags {
                let down = event.modifierFlags.contains(flag)
                if down != modifierKeys.contains(key) {
                    if down { modifierKeys.insert(key) } else { modifierKeys.remove(key) }
                    synchronize(key)
                }
            }
            return true
        }
        guard let key = doomKey(event.keyCode) else { return false }
        if event.isARepeat { return true }
        keyEvents += 1
        if event.type == .keyDown { held[event.keyCode] = key }
        else { held.removeValue(forKey: event.keyCode) }
        synchronize(key)
        return true
    }
    func synchronize(_ key: UInt8) {
        DD_Key(key, held.values.contains(key) || modifierKeys.contains(key) ? 1 : 0)
    }
    func releaseKeys() { held.removeAll(); modifierKeys.removeAll(); DD_ReleaseKeys() }

    @objc func releaseFocus() {
        focusRequest += 1; releaseKeys()
        if let previous = previousApp, !previous.isTerminated { previous.activate(options: []) }
        else { NSApp.hide(nil) }
    }
    func requestFocus() {
        clicks += 1; focusRequest += 1
        let request = focusRequest
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        focusResult = "requested"; NSApp.unhideWithoutActivation()
        if displayMode == "window" { gameWindow.show() }
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self = self, request == self.focusRequest else { return }
            if NSApp.isActive { self.focusResult = "direct"; return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == front?.processIdentifier else {
                self.focusResult = "cancelled"; return
            }
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    guard request == self.focusRequest else { return }
                    self.focusResult = error?.localizedDescription ?? "reopen completed"
                }
            }
        }
    }
    @objc func statusClicked(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            status.menu = controlMenu(); status.button?.performClick(nil); status.menu = nil
        } else { requestFocus() }
    }
    func controlMenu() -> NSMenu {
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        let info = startupError ?? "DOOM shareware · Ammo: \(lastAmmo) · F/Ctrl: fire"
        menu.addItem(withTitle: info, action: nil, keyEquivalent: "")
        for text in ["W/S or ↑/↓: move · ←/→: turn · A/D: strafe", "Ctrl or F: fire · Space/E: use · Shift: run", "Esc: game menu · Enter: select · Tab: map", "1–7: weapon · ⌘Esc: release · ⌘Q: quit"] {
            menu.addItem(withTitle: text, action: nil, keyEquivalent: "")
        }
        menu.addItem(.separator())
        for (index, title) in ["Game in Dock", "Game on Desktop", "Game in Menu Bar", "Game in Window"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(changePresentation(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            item.state = displayMode == ["dock", "desktop", "menubar", "window"][index] ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (index, title) in ["Menu Bar: Doomguy Face", "Menu Bar: Game Preview"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(changeMenuBar(_:)), keyEquivalent: "")
            item.target = self; item.tag = index
            item.state = effectiveMenuBarMode == ["face", "game"][index] ? .on : .off
            item.isEnabled = displayMode != "menubar"
            if !item.isEnabled { item.toolTip = "Choose Dock, Desktop or Window to customize the menu bar." }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let sound = NSMenuItem(title: soundMuted ? "Unmute Sound Effects" : "Mute Sound Effects", action: #selector(toggleSound), keyEquivalent: "")
        sound.target = self; menu.addItem(sound)
        menu.addItem(withTitle: DD_AudioReady() != 0 ? "Sound effects on · Music not implemented" : "Audio unavailable (\(DD_AudioError()))", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        for (title, action) in [("Focus Game", #selector(focusGame)), (manuallyPaused ? "Resume" : "Pause", #selector(togglePause)), ("Release Keyboard", #selector(releaseFocus))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DOOM for macOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action == nil { item.isEnabled = false }
        return menu
    }
    @objc func focusGame() { requestFocus() }
    @objc func togglePause() { manuallyPaused.toggle(); releaseKeys(); updatePause() }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; releaseKeys(); updatePause() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; updatePause() }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { controlMenu() }
    func applicationDidBecomeActive(_ notification: Notification) { activations += 1; updatePause() }
    func applicationDidResignActive(_ notification: Notification) { releaseKeys(); updatePause() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if displayMode == "window" { gameWindow.show(); updatePause() }
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        releaseKeys()
        if !engineStarted || DD_GetStats().finished != 0 { if engineStarted { DD_Join() }; return .terminateNow }
        quitting = true; DD_Stop(); return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let token = activity { ProcessInfo.processInfo.endActivity(token) }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let observer = screenObserver { NotificationCenter.default.removeObserver(observer) }
        desktop.update(enabled: false, image: nil)
        gameWindow.update(enabled: false, image: nil)
        NSApp.dockTile.contentView = nil; NSStatusBar.system.removeStatusItem(status)
    }
    func writeDiagnostics(_ stats: DDStats) {
        if let path = argument("--diagnostics") {
            let report: [String: Any] = ["active": NSApp.isActive, "keyWindow": NSApp.keyWindow != nil,
                "windows": NSApp.windows.map { String(describing: type(of: $0)) },
                "engineFrames": stats.frames, "engineInputEvents": stats.input_events, "submittedFPS": submittedFPS,
                "paused": stats.paused != 0, "health": stats.health, "map": stats.map,
                "ammo": stats.ammo, "weapon": stats.weapon, "attacking": stats.attacking != 0,
                "displayMode": displayMode, "dockRendering": NSApp.dockTile.contentView === dockView,
                "staticDockIcon": NSApp.dockTile.contentView === staticDockView,
                "staticDockIconValid": staticDockView.image?.isValid ?? false,
                "menuBarPreview": effectiveMenuBarMode == "game" && status.button?.image != nil,
                "menuBarMode": effectiveMenuBarMode, "menuBarTitle": status.button?.title ?? "",
                "menuBarWidth": status.length, "presentationTargetFPS": targetFPS, "faceAvailable": faceFrame != nil,
                "menuBarScreenRect": status.button.flatMap { button in
                    button.window.map { window -> [String: Double] in
                        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
                        let top = NSScreen.screens.first?.frame.maxY ?? 0
                        return ["x": frame.minX, "y": top - frame.maxY, "width": frame.width, "height": frame.height]
                    }
                } ?? [:],
                "gameWindowVisible": gameWindow.window?.isVisible ?? false,
                "gameWindowMiniaturized": gameWindow.window?.isMiniaturized ?? false,
                "gameWindowSize": gameWindow.window.map { "\($0.contentLayoutRect.size)" } ?? "",
                "desktopVisible": desktop.window?.isVisible ?? false,
                "desktopIgnoresMouse": desktop.window?.ignoresMouseEvents ?? false,
                "desktopCanBecomeKey": desktop.window?.canBecomeKey ?? false,
                "desktopLevel": desktop.window?.level.rawValue ?? 0,
                "audioReady": DD_AudioReady() != 0, "audioError": DD_AudioError(),
                "soundsStarted": DD_AudioSounds(), "audioSamples": DD_AudioSamples(), "muted": soundMuted,
                "playerX": stats.player_x, "playerY": stats.player_y, "keyEvents": keyEvents,
                "clicks": clicks, "activations": activations, "focusResult": focusResult,
                "error": startupError ?? "", "dockSize": "\(NSApp.dockTile.size)"]
            do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path), options: .atomic) }
            catch { fputs("Diagnostics: \(error)\n", stderr) }
        }
        if let path = argument("--face-snapshot"), let cg = faceFrame {
            let representation = NSBitmapImageRep(cgImage: cg)
            try? representation.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        if let path = argument("--snapshot"), let cg = cgFrame {
            let representation = NSBitmapImageRep(cgImage: cg)
            do { try representation.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path), options: .atomic) }
            catch { fputs("Snapshot: \(error)\n", stderr) }
        }
    }
}

let app = DoomApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
