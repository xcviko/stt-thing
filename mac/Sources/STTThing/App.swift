import AppKit
import Combine
import Carbon.HIToolbox
import SwiftUI

/// Borderless panel that floats above everything, including full-screen
/// apps, and never takes focus from the call window.
final class OverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        minSize = NSSize(width: 280, height: 70)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that opens the menu on right click and reacts to the first
/// click without activating the app.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var menuProvider: (() -> NSMenu)?

    override var mouseDownCanMoveWindow: Bool { false }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum Defaults {
    static let device = "device"
    static let fontSize = "fontSize"
    static let opacity = "opacity"
    static let hideFromCapture = "hideFromCapture"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var originalPanel: OverlayPanel!
    private var translationPanel: OverlayPanel!
    private var panels: [OverlayPanel] { [originalPanel, translationPanel].compactMap { $0 } }
    /// ⌥⌘T hides both panels.
    private var panelsHidden = false
    private var cancellables: Set<AnyCancellable> = []
    private var statusItem: NSStatusItem!
    private var transcript: Transcript!
    private var backend: Backend?
    private var devices: [InputDevice] = []
    private var hotKeyRef: EventHotKeyRef?
    private var mouseTimer: Timer?
    private var usr1Source: DispatchSourceSignal?
    private let settings = TranslationSettings()
    private let usage = UsageStore()
    private var translator: Translator!
    private var settingsWindow: NSWindow?
    private var statsWindow: NSWindow?
    private let defaults = UserDefaults.standard

    private var device: String {
        get { defaults.string(forKey: Defaults.device) ?? "BlackHole" }
        set { defaults.set(newValue, forKey: Defaults.device) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [
            Defaults.fontSize: 20.0,
            Defaults.opacity: 0.82,
            Defaults.hideFromCapture: true,
        ])
        transcript = Transcript(
            fontSize: CGFloat(defaults.double(forKey: Defaults.fontSize)),
            opacity: defaults.double(forKey: Defaults.opacity)
        )
        translator = Translator(settings: settings, usage: usage)
        translator.onUpdate = { [weak self] id, text, pending in
            self?.transcript.setTranslation(line: id, text: text, pending: pending)
        }
        translator.onError = { [weak self] message in self?.transcript.showTranslationError(message) }
        transcript.onCommitted = { [weak self] id, committed, final in
            self?.translator.process(line: id, committed: committed, final: final)
        }

        installEditMenu()
        createPanel()
        createStatusItem()
        registerHotKey()
        listenForPauseSignal()

        guard let dir = Backend.locateBackendDir() else {
            transcript.handle(.error("backend folder not found (set STT_BACKEND_DIR)"))
            return
        }
        let backend = Backend(backendDir: dir)
        backend.onEvent = { [weak self] event in self?.transcript.handle(event) }
        self.backend = backend
        startBackend()
        refreshDevices()
    }

    func applicationWillTerminate(_ notification: Notification) {
        backend?.stop()
    }

    // MARK: window

    /// Two panels: the recognized text and its translation, each moved and
    /// sized on its own. The translation panel starts right below the other.
    private func createPanel() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 760, height: 150)
        let top = NSRect(
            origin: NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 12), size: size
        )
        let below = top.offsetBy(dx: 0, dy: -(size.height + 8))
        originalPanel = makePanel(.original, frame: top, autosave: "STTOverlay")
        translationPanel = makePanel(.translation, frame: below, autosave: "STTTranslation")
        applyCaptureSetting()
        updatePanelVisibility()

        // Show or hide the translation panel when settings change.
        settings.$enabled.combineLatest(settings.$showOriginal)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePanelVisibility() }
            .store(in: &cancellables)

        startMouseTracking()
        startDebugSnapshots()
    }

    private func makePanel(_ kind: PanelKind, frame: NSRect, autosave: String) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: frame)
        let view = OverlayView(
            kind: kind,
            transcript: transcript,
            settings: settings,
            usage: usage,
            onTogglePause: { [weak self] in self?.togglePause() },
            onMenu: { [weak self] in self?.popUpMenu() }
        )
        let host = OverlayHostingView(rootView: view)
        host.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        panel.contentView = host
        panel.setFrameAutosaveName(autosave)
        return panel
    }

    private func updatePanelVisibility() {
        let showTranslation = !panelsHidden && settings.enabled
        let showOriginal = !panelsHidden && (!settings.enabled || settings.showOriginal)
        for (panel, show) in [(originalPanel!, showOriginal), (translationPanel!, showTranslation)] {
            if show && !panel.isVisible { panel.orderFrontRegardless() }
            if !show && panel.isVisible { panel.orderOut(nil) }
        }
    }

    /// Clicks go through the text area to the window below. The panel takes
    /// the mouse only over the top bar, or anywhere while paused (to scroll).
    /// macOS has no per-region click-through, so this follows the cursor.
    private func startMouseTracking() {
        panels.forEach { $0.ignoresMouseEvents = true }
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.updateMouseCapture()
        }
        RunLoop.main.add(mouseTimer!, forMode: .common) // keep working during drags and menus
    }

    private func updateMouseCapture() {
        let p = NSEvent.mouseLocation
        for panel in panels where panel.isVisible {
            let frame = panel.frame
            let inPanel = frame.insetBy(dx: -2, dy: -2).contains(p)
            let inTopBar = inPanel && p.y >= frame.maxY - topBarHeight - 2
            let dragging = NSEvent.pressedMouseButtons & 1 == 1 && !panel.ignoresMouseEvents
            let capture = inTopBar || (transcript.paused && inPanel) || dragging
            if panel.ignoresMouseEvents == capture {
                panel.ignoresMouseEvents = !capture
            }
        }
    }

    /// `kill -USR1 <pid>` toggles pause (for scripts and tests).
    private func listenForPauseSignal() {
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.togglePause() }
        src.resume()
        usr1Source = src
    }

    @objc private func togglePause() {
        transcript.paused.toggle()
        transcript.speech = false
        backend?.send(transcript.paused ? "pause" : "resume")
        updateMouseCapture()
        statusItem.menu = buildMenu()
    }

    private func popUpMenu() {
        buildMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Debug aids (work without screen recording permission):
    /// STT_SNAPSHOT=/path/prefix saves PNGs of the overlay (and of open
    /// windows) every 3 seconds; STT_OPEN=settings,stats opens those windows.
    private func startDebugSnapshots() {
        let env = ProcessInfo.processInfo.environment
        if let open = env["STT_OPEN"] {
            DispatchQueue.main.async {
                if open.contains("settings") { self.showSettings() }
                if open.contains("stats") { self.showStats() }
            }
        }
        guard let prefix = env["STT_SNAPSHOT"] else { return }
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            n += 1
            let targets: [(String, NSView?)] = [
                ("", self.originalPanel.isVisible ? self.originalPanel.contentView : nil),
                ("tr-", self.translationPanel.isVisible ? self.translationPanel.contentView : nil),
                ("settings-", self.settingsWindow?.isVisible == true ? self.settingsWindow?.contentView : nil),
                ("stats-", self.statsWindow?.isVisible == true ? self.statsWindow?.contentView : nil),
            ]
            for (name, view) in targets {
                guard let view, let png = Self.snapshotPNG(view) else { continue }
                try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(name)\(n).png"))
            }
        }
    }

    /// Renders the layer tree (cacheDisplay misses Charts, tables and scroll views).
    private static func snapshotPNG(_ view: NSView) -> Data? {
        guard let layer = view.layer else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = ctx.cgContext
        if let bg = view.window?.backgroundColor?.cgColor, view.window?.isOpaque == true {
            cg.setFillColor(bg)
            cg.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        }
        cg.scaleBy(x: scale, y: scale)
        if !view.isFlipped {
            // layer.render draws top-down
        }
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        layer.render(in: cg)
        return rep.representation(using: .png, properties: [:])
    }

    /// An accessory app has no menu bar of its own, but text fields need the
    /// Edit menu for ⌘C / ⌘V / ⌘A to work (pasting an API key).
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit STT Thing", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    private func applyCaptureSetting() {
        // .none asks the window server to leave the panel out of screen
        // captures and screen sharing. Newer capture APIs may ignore it.
        let type: NSWindow.SharingType = defaults.bool(forKey: Defaults.hideFromCapture) ? .none : .readOnly
        panels.forEach { $0.sharingType = type }
    }

    @objc private func toggleWindow() {
        panelsHidden.toggle()
        updatePanelVisibility()
    }

    // MARK: backend

    private func startBackend() {
        transcript.loading(device: device)
        backend?.start(device: device)
        if transcript.paused { backend?.send("pause") }
    }

    @objc private func restartBackend() {
        startBackend()
    }

    private func refreshDevices() {
        backend?.listDevices { [weak self] list in
            self?.devices = list
            self?.statusItem.menu = self?.buildMenu()
        }
    }

    @objc private func refreshDevicesAction() {
        refreshDevices()
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        device = name
        startBackend()
        statusItem.menu = buildMenu()
    }

    // MARK: menu

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "STT"
        statusItem.menu = buildMenu()
    }

    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = modifiers
        it.target = self
        return it
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let deviceMenu = NSMenu()
        if devices.isEmpty {
            let it = NSMenuItem(title: "Loading devices…", action: nil, keyEquivalent: "")
            it.isEnabled = false
            deviceMenu.addItem(it)
        }
        for d in devices {
            let it = item(d.name, #selector(selectDevice(_:)))
            it.representedObject = d.name
            it.state = d.name.localizedCaseInsensitiveContains(device) ? .on : .off
            deviceMenu.addItem(it)
        }
        deviceMenu.addItem(.separator())
        deviceMenu.addItem(item("Refresh list", #selector(refreshDevicesAction)))
        let deviceItem = NSMenuItem(title: "Input device", action: nil, keyEquivalent: "")
        deviceItem.submenu = deviceMenu
        menu.addItem(deviceItem)

        menu.addItem(item(transcript.paused ? "Resume listening" : "Pause listening", #selector(togglePause)))
        menu.addItem(item("Clear text", #selector(clearText)))
        menu.addItem(item("New conversation", #selector(newConversation)))
        menu.addItem(.separator())

        let translate = item("Translate", #selector(toggleTranslation), key: "t")
        translate.state = settings.enabled ? .on : .off
        menu.addItem(translate)
        let toMenu = NSMenu()
        for lang in Languages.target {
            let it = item(lang.name, #selector(selectTargetLanguage(_:)))
            it.representedObject = lang.code
            it.state = lang.code == settings.targetLanguage ? .on : .off
            toMenu.addItem(it)
        }
        let toItem = NSMenuItem(title: "Translate to: \(Languages.name(settings.targetLanguage))", action: nil, keyEquivalent: "")
        toItem.submenu = toMenu
        menu.addItem(toItem)
        let original = item("Show original panel", #selector(toggleOriginal))
        original.state = settings.showOriginal ? .on : .off
        menu.addItem(original)
        menu.addItem(item("Translation settings…", #selector(showSettings), key: ","))
        menu.addItem(item("Cost & stats…", #selector(showStats)))
        menu.addItem(.separator())
        menu.addItem(item("Bigger text", #selector(biggerText), key: "="))
        menu.addItem(item("Smaller text", #selector(smallerText), key: "-"))

        let bgMenu = NSMenu()
        for o in [0.55, 0.7, 0.82, 0.92] {
            let it = item("\(Int(o * 100))%", #selector(setOpacity(_:)))
            it.representedObject = o
            it.state = abs(transcript.opacity - o) < 0.01 ? .on : .off
            bgMenu.addItem(it)
        }
        let bgItem = NSMenuItem(title: "Background", action: nil, keyEquivalent: "")
        bgItem.submenu = bgMenu
        menu.addItem(bgItem)

        let capture = item("Hide from screen sharing", #selector(toggleCapture))
        capture.state = defaults.bool(forKey: Defaults.hideFromCapture) ? .on : .off
        menu.addItem(capture)

        menu.addItem(.separator())
        menu.addItem(item("Show / hide  (⌥⌘T)", #selector(toggleWindow)))
        menu.addItem(item("Restart backend", #selector(restartBackend)))
        menu.addItem(.separator())
        menu.addItem(item("Quit", #selector(quit), key: "q"))
        return menu
    }

    @objc private func clearText() {
        transcript.clear()
        translator.reset()
    }

    @objc private func newConversation() {
        clearText()
        usage.startConversation()
    }

    @objc private func toggleTranslation() {
        settings.enabled.toggle()
        statusItem.menu = buildMenu()
        if settings.enabled, case .failure(let err) = settings.endpoint() {
            transcript.showTranslationError(err.localizedDescription)
            showSettings()
        }
    }

    @objc private func selectTargetLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        settings.targetLanguage = code
        statusItem.menu = buildMenu()
    }

    @objc private func toggleOriginal() {
        settings.showOriginal.toggle()
        statusItem.menu = buildMenu()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "STT Thing · Translation", view: SettingsView(settings: settings), resizable: false)
        }
        present(settingsWindow!)
    }

    @objc private func showStats() {
        if statsWindow == nil {
            let view = StatsView(usage: usage, onNewConversation: { [weak self] in self?.newConversation() })
            statsWindow = makeWindow(title: "STT Thing · Cost & stats", view: view, resizable: true)
            statsWindow?.setContentSize(NSSize(width: 680, height: 860))
        }
        present(statsWindow!)
    }

    private func makeWindow<V: View>(title: String, view: V, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        return window
    }

    private func present(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func biggerText() { setFont(transcript.fontSize + 2) }

    @objc private func smallerText() { setFont(transcript.fontSize - 2) }

    private func setFont(_ size: CGFloat) {
        transcript.fontSize = min(48, max(12, size))
        defaults.set(Double(transcript.fontSize), forKey: Defaults.fontSize)
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let o = sender.representedObject as? Double else { return }
        transcript.opacity = o
        defaults.set(o, forKey: Defaults.opacity)
        statusItem.menu = buildMenu()
    }

    @objc private func toggleCapture() {
        defaults.set(!defaults.bool(forKey: Defaults.hideFromCapture), forKey: Defaults.hideFromCapture)
        applyCaptureSetting()
        statusItem.menu = buildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: global hotkey ⌥⌘T

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { me.toggleWindow() }
            return noErr
        }, 1, &spec, selfPtr, nil)
        let id = EventHotKeyID(signature: OSType(0x5354_5454), id: 1) // "STTT"
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

@main
enum STTThingApp {
    static func main() {
        // Writing to the stdin of a backend that just died must not kill us.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // no Dock icon, menu bar item only
        app.run()
    }
}
