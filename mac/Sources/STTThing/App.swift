import AppKit
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
    private var panel: OverlayPanel!
    private var statusItem: NSStatusItem!
    private var transcript: Transcript!
    private var backend: Backend?
    private var devices: [InputDevice] = []
    private var hotKeyRef: EventHotKeyRef?
    private var mouseTimer: Timer?
    private var usr1Source: DispatchSourceSignal?
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

    private func createPanel() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: 760, height: 170)
        let origin = NSPoint(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 12)
        panel = OverlayPanel(contentRect: NSRect(origin: origin, size: size))

        let view = OverlayView(
            transcript: transcript,
            onTogglePause: { [weak self] in self?.togglePause() },
            onMenu: { [weak self] in self?.popUpMenu() }
        )
        let host = OverlayHostingView(rootView: view)
        host.menuProvider = { [weak self] in self?.buildMenu() ?? NSMenu() }
        panel.contentView = host
        panel.setFrameAutosaveName("STTOverlay")
        applyCaptureSetting()
        panel.orderFrontRegardless()
        startMouseTracking()
        startDebugSnapshots()
    }

    /// Clicks go through the text area to the window below. The panel takes
    /// the mouse only over the top bar, or anywhere while paused (to scroll).
    /// macOS has no per-region click-through, so this follows the cursor.
    private func startMouseTracking() {
        panel.ignoresMouseEvents = true
        mouseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            self?.updateMouseCapture()
        }
        RunLoop.main.add(mouseTimer!, forMode: .common) // keep working during drags and menus
    }

    private func updateMouseCapture() {
        guard panel.isVisible else { return }
        let p = NSEvent.mouseLocation
        let frame = panel.frame
        let inPanel = frame.insetBy(dx: -2, dy: -2).contains(p)
        let inTopBar = inPanel && p.y >= frame.maxY - topBarHeight - 2
        let dragging = NSEvent.pressedMouseButtons & 1 == 1 && !panel.ignoresMouseEvents
        let capture = inTopBar || (transcript.paused && inPanel) || dragging
        if panel.ignoresMouseEvents == capture {
            panel.ignoresMouseEvents = !capture
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

    /// Debug aid: STT_SNAPSHOT=/path/prefix saves a PNG of the overlay every
    /// 3 seconds (works without screen recording permission).
    private func startDebugSnapshots() {
        guard let prefix = ProcessInfo.processInfo.environment["STT_SNAPSHOT"] else { return }
        var n = 0
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let view = self?.panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            n += 1
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(prefix)-\(n).png"))
        }
    }

    private func applyCaptureSetting() {
        // .none asks the window server to leave the panel out of screen
        // captures and screen sharing. Newer capture APIs may ignore it.
        panel.sharingType = defaults.bool(forKey: Defaults.hideFromCapture) ? .none : .readOnly
    }

    @objc private func toggleWindow() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
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

    @objc private func clearText() { transcript.clear() }

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
