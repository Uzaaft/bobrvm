// Minimal bobrvm display app.
//
// Scaffolding for verifying the guest scanout pipeline end-to-end while
// the full SwiftUI app comes together: one window, one CAMetalLayer,
// frames drawn by the Zig renderer thread (Swift owns the window and
// Metal context only, per the ghostty pattern).
//
// Build: ./macos/MinimalApp/build.sh
// Run:   BobrvmDisplay --kernel Image --initrd initrd [--disk d.img] \
//            [--cmdline '...'] [--memory-mb 2048] [--net] [--cpus 1]

import AppKit
import Metal
import QuartzCore
import CoreGraphics

final class MetalView: NSView {
    let metalLayer = CAMetalLayer()
    var surface: bobrvm_surface_t?
    var lastFlags = NSEvent.ModifierFlags()

    // Click-to-capture mouse grab (VMware/Parallels-style): while captured,
    // the host cursor is hidden and unassociated from the display so raw
    // hardware deltas keep flowing past the screen edges — otherwise the
    // host cursor simply can't move further once it hits the edge of the
    // physical display, capping how far the guest pointer could ever travel.
    // Release with Control+Option (VMware Fusion's default host-key combo).
    var mouseCaptured = false
    var virtualX: CGFloat = 0
    var virtualY: CGFloat = 0

    func captureMouse() {
        guard !mouseCaptured else { return }
        mouseCaptured = true
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
        virtualX = bounds.midX
        virtualY = bounds.midY
        window?.title = "bobrvm (mouse captured — ⌃⌥ to release)"
    }

    func releaseMouse() {
        guard mouseCaptured else { return }
        mouseCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        // Warp the host cursor back to the window's center so it reappears
        // somewhere sane instead of wherever it silently drifted while hidden.
        if let window, let screen = window.screen ?? NSScreen.screens.first {
            let centerInWindow = NSPoint(x: bounds.midX, y: bounds.midY)
            let centerOnScreen = window.convertPoint(toScreen: convert(centerInWindow, to: nil))
            let mainScreenHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
            CGWarpMouseCursorPosition(CGPoint(x: centerOnScreen.x, y: mainScreenHeight - centerOnScreen.y))
        }
        window?.title = "bobrvm"
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = metalLayer
        // Letterbox (not distort) the stale framebuffer while the window and
        // the guest resolution disagree — i.e. between a live resize and the
        // guest's modeset in response to the display hotplug.
        metalLayer.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var acceptsFirstResponder: Bool { true }

    private func sendKeyCode(_ keyCode: UInt16, pressed: Bool, modifiers: UInt = 0) {
        guard let surface else { return }
        var key = bobrvm_key_event_s()
        key.keycode = UInt32(keyCode)
        key.modifiers = UInt32(modifiers & 0xFFFF_FFFF)
        key.pressed = pressed
        bobrvm_surface_key(surface, key)
    }

    private func sendKey(_ event: NSEvent, pressed: Bool) {
        sendKeyCode(event.keyCode, pressed: pressed, modifiers: event.modifierFlags.rawValue)
    }

    override func keyDown(with event: NSEvent) { sendKey(event, pressed: true) }
    override func keyUp(with event: NSEvent) { sendKey(event, pressed: false) }

    // ⌘-modified keys never reach keyDown — AppKit routes them to the
    // key-equivalent/menu chain, so without this override every ⌘-combo is
    // silently swallowed. Forward them to the guest as a press+release
    // pulse (the matching keyUp is also suppressed while ⌘ is held).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else { return false }
        sendKey(event, pressed: true)
        sendKey(event, pressed: false)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier keys: derive press/release from the DEVICE-dependent
        // flag bits (NX_DEVICE*KEYMASK) so left and right variants track
        // independently — the generic flags (.shift & co) stay set while
        // the *other* side is still held, which turned "release left
        // shift" into a re-press and left the guest with a stuck modifier.
        let deviceBitFor: [UInt16: UInt] = [
            0x37: 0x0008, // Command -> NX_DEVICELCMDKEYMASK
            0x36: 0x0010, // Right Command -> NX_DEVICERCMDKEYMASK
            0x38: 0x0002, // Shift -> NX_DEVICELSHIFTKEYMASK
            0x3C: 0x0004, // Right Shift -> NX_DEVICERSHIFTKEYMASK
            0x3A: 0x0020, // Option -> NX_DEVICELALTKEYMASK
            0x3D: 0x0040, // Right Option -> NX_DEVICERALTKEYMASK
            0x3B: 0x0001, // Control -> NX_DEVICELCTLKEYMASK
            0x3E: 0x2000, // Right Control -> NX_DEVICERCTLKEYMASK
        ]
        if event.keyCode == 0x39 {
            // CapsLock is a toggle on the Mac side but a momentary key to
            // the guest, which toggles its own caps state on PRESS edges.
            // Pulse press+release on every host flip; press-only/release-
            // only left the guest's caps lock stuck on.
            sendKey(event, pressed: true)
            sendKey(event, pressed: false)
        } else if let bit = deviceBitFor[event.keyCode] {
            sendKey(event, pressed: (event.modifierFlags.rawValue & bit) != 0)
        }
        if mouseCaptured, event.modifierFlags.contains(.control), event.modifierFlags.contains(.option) {
            releaseMouse()
        }
        lastFlags = event.modifierFlags
    }

    /// Release every modifier in the guest. Called when the app/window
    /// loses key status: a release that happens while unfocused (⌘Tab is
    /// the classic case — the ⌘ press reaches us, the release goes to the
    /// app switcher) otherwise leaves the guest with a modifier held
    /// forever, making every later keystroke look modified.
    func releaseAllModifiers() {
        for code: UInt16 in [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E] {
            sendKeyCode(code, pressed: false)
        }
        lastFlags = NSEvent.ModifierFlags()
    }

    override func mouseDown(with event: NSEvent) {
        if !mouseCaptured { captureMouse() }
        guard let surface else { return }
        bobrvm_surface_mouse_button(surface, BOBRVM_MOUSE_LEFT, true)
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface else { return }
        bobrvm_surface_mouse_button(surface, BOBRVM_MOUSE_LEFT, false)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface else { return }
        bobrvm_surface_mouse_button(surface, BOBRVM_MOUSE_RIGHT, true)
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface else { return }
        bobrvm_surface_mouse_button(surface, BOBRVM_MOUSE_RIGHT, false)
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        if mouseCaptured {
            // event.deltaX/deltaY are raw hardware deltas (positive deltaY
            // = moved down), which already matches the guest's top-left,
            // y-down convention — no flip needed here, unlike the absolute
            // path below.
            virtualX += event.deltaX
            virtualY += event.deltaY
            bobrvm_surface_mouse_pos(surface, virtualX, virtualY)
        } else {
            let p = convert(event.locationInWindow, from: nil)
            // Flip to top-left origin to match the guest's coordinate space.
            bobrvm_surface_mouse_pos(surface, p.x, bounds.height - p.y)
        }
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) { sendMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        bobrvm_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var view: MetalView!
    var timer: Timer?

    var bobrApp: bobrvm_app_t?
    var vm: bobrvm_vm_t?
    var surface: bobrvm_surface_t?

    // Retained for the app's lifetime: Zig holds raw pointers to these.
    var device: MTLDevice!
    var queue: MTLCommandQueue!

    /// Guest resolution follows backing pixels (Retina-native) instead of
    /// logical points. Off by default: points give Fusion-like sane DPI.
    var hidpi = false
    var resizeDebounce: DispatchWorkItem?

    /// Guest resolution for the current view size: points by default,
    /// backing pixels with --hidpi. Width rounded down to even so the
    /// guest's scanout resource keeps a tight (IOSurface-friendly) stride.
    private func guestSize() -> (UInt32, UInt32) {
        let scale = hidpi ? (window.backingScaleFactor) : 1.0
        let s = view.bounds.size
        let w = UInt32(max(s.width * scale, 1)) & ~1
        let h = UInt32(max(s.height * scale, 1))
        return (w, h)
    }

    /// Push the current window size to the guest (display hotplug) and the
    /// host drawable. The guest modesets asynchronously; until then the old
    /// framebuffer letterboxes.
    func requestGuestResize() {
        guard let surface else { return }
        let (w, h) = guestSize()
        bobrvm_surface_request_display_size(surface, w, h)
        bobrvm_surface_set_size(surface, w, h)
    }

    private func scheduleGuestResize() {
        resizeDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.requestGuestResize() }
        resizeDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func guestResizeNow() {
        resizeDebounce?.cancel()
        resizeDebounce = nil
        requestGuestResize()
    }

    // Debounce during drags (each resize is a full guest modeset); commit
    // immediately once the resize settles or the window changes mode/screen.
    func windowDidResize(_ notification: Notification) {
        if window.inLiveResize {
            scheduleGuestResize()
        } else {
            guestResizeNow()
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) { guestResizeNow() }
    func windowDidEnterFullScreen(_ notification: Notification) { guestResizeNow() }
    func windowDidExitFullScreen(_ notification: Notification) { guestResizeNow() }
    func windowDidChangeBackingProperties(_ notification: Notification) {
        if hidpi {
            view.metalLayer.contentsScale = window.backingScaleFactor
            guestResizeNow()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let width = 1280.0
        let height = 800.0

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "bobrvm"
        window.center()
        window.delegate = self
        // Native fullscreen (green button / ⌃⌘F).
        window.collectionBehavior.insert(.fullScreenPrimary)

        view = MetalView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        guard let dev = MTLCreateSystemDefaultDevice(),
              let cq = dev.makeCommandQueue()
        else {
            fatalError("no Metal device")
        }
        device = dev
        queue = cq
        view.metalLayer.device = device
        view.metalLayer.pixelFormat = .bgra8Unorm
        // The Zig renderer blits into the drawable texture.
        view.metalLayer.framebufferOnly = false

        bobrvm_init()

        var runtimeCfg = bobrvm_runtime_config_s()
        // Clipboard bridge (guest vdagent <-> NSPasteboard). Callbacks run
        // on the vCPU thread; NSPasteboard tolerates background access for
        // simple string get/set.
        runtimeCfg.read_clipboard = { _, outText in
            guard let text = NSPasteboard.general.string(forType: .string) else { return false }
            outText?.pointee = strdup(text)
            return true
        }
        runtimeCfg.write_clipboard = { _, text in
            guard let text else { return }
            let s = String(cString: text)
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }
        runtimeCfg.free_clipboard = { _, text in
            free(text)
        }
        bobrApp = bobrvm_app_new(&runtimeCfg)
        guard bobrApp != nil else { fatalError("bobrvm_app_new failed") }

        // Parse CLI arguments into the VM config.
        var kernel: String? = nil
        var initrd: String? = nil
        var disk: String? = nil
        var cmdline = "console=hvc0 earlycon=pl011,0x09000000"
        var memoryMB: UInt64 = 2048
        var enableNet = false
        var cpuCount: UInt8 = 1

        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--kernel": kernel = args.next()
            case "--initrd": initrd = args.next()
            case "--disk": disk = args.next()
            case "--cmdline": cmdline = args.next() ?? cmdline
            case "--memory-mb": memoryMB = UInt64(args.next() ?? "") ?? memoryMB
            case "--net": enableNet = true
            case "--cpus": cpuCount = UInt8(args.next() ?? "") ?? cpuCount
            case "--hidpi": hidpi = true
            default: print("unknown argument: \(arg)")
            }
        }
        if hidpi {
            view.metalLayer.contentsScale = window.backingScaleFactor
        }
        guard let kernelPath = kernel else {
            print("usage: BobrvmDisplay --kernel Image [--initrd initrd] [--disk disk.img] [--net] [--cpus 1] [--memory-mb 2048] [--hidpi]")
            NSApp.terminate(nil)
            return
        }

        // Keep C strings alive for the duration of bobrvm_vm_new (it copies).
        kernelPath.withCString { kernelC in
            withOptionalCString(initrd) { initrdC in
                withOptionalCString(disk) { diskC in
                    cmdline.withCString { cmdlineC in
                        var cfg = bobrvm_vm_config_s()
                        cfg.memory_bytes = memoryMB * 1024 * 1024
                        cfg.vcpu_count = cpuCount
                        cfg.kernel_path = kernelC
                        cfg.initrd_path = initrdC
                        cfg.disk_path = diskC
                        cfg.disk_read_only = diskC != nil && (disk?.hasSuffix(".iso") ?? false)
                        cfg.cmdline = cmdlineC
                        cfg.enable_net = enableNet
                        let (gw, gh) = guestSize()
                        cfg.display_width = gw
                        cfg.display_height = gh
                        vm = bobrvm_vm_new(bobrApp, &cfg)
                    }
                }
            }
        }
        guard vm != nil else { fatalError("bobrvm_vm_new failed") }

        let rc = bobrvm_vm_start(vm)
        guard rc == BOBRVM_OK else { fatalError("bobrvm_vm_start failed: \(rc)") }

        surface = bobrvm_surface_new(
            vm,
            Unmanaged.passUnretained(device).toOpaque(),
            Unmanaged.passUnretained(view.metalLayer).toOpaque(),
            Unmanaged.passUnretained(queue).toOpaque()
        )
        guard surface != nil else { fatalError("bobrvm_surface_new failed") }
        let (gw, gh) = guestSize()
        bobrvm_surface_set_size(surface, gw, gh)

        // Route input events from the view to the guest.
        view.surface = surface
        window.makeFirstResponder(view)
        window.acceptsMouseMovedEvents = true

        // Safety net: don't leave the host cursor hidden/ungrabbed — or
        // guest modifiers stuck down — if the user switches away from the
        // app some other way than ⌃⌥ (⌘Tab being the classic case).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.view.releaseMouse()
            self?.view.releaseAllModifiers()
        }

        // Drive frames at 60 Hz. (CVDisplayLink integration comes with
        // the full app; a timer is enough to verify the pipeline.)
        // Piggyback a ~0.5s host-clipboard poll: on changeCount
        // transitions, announce a vdagent GRAB so the guest can paste.
        var tick = 0
        var lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let surface = self.surface else { return }
            bobrvm_surface_draw(surface)
            tick += 1
            if tick % 30 == 0 {
                let count = NSPasteboard.general.changeCount
                if count != lastChangeCount {
                    lastChangeCount = count
                    if let vm = self.vm { bobrvm_vm_host_clipboard_changed(vm) }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let surface { bobrvm_surface_destroy(surface) }
        if let vm { bobrvm_vm_destroy(vm) }
        if let bobrApp { bobrvm_app_destroy(bobrApp) }
        bobrvm_deinit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

func withOptionalCString<R>(_ s: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
    if let s {
        return s.withCString { body($0) }
    }
    return body(nil)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.activate(ignoringOtherApps: true)
app.run()
