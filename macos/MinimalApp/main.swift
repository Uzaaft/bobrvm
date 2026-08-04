import AppKit
import Metal
import QuartzCore
import CoreGraphics

final class MetalView: NSView {
    let metalLayer = CAMetalLayer()
    var surface: bobrvm_surface_t?
    var lastFlags = NSEvent.ModifierFlags()

    // Disassociating the cursor preserves raw deltas beyond screen edges.
    // Control+Option releases the capture.
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
        if let surface {
            bobrvm_surface_mouse_pos(surface, virtualX, virtualY)
        }
        window?.title = "bobrvm (mouse captured — ⌃⌥ to release)"
    }

    func releaseMouse() {
        guard mouseCaptured else { return }
        mouseCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        // The hidden cursor may have drifted outside the window while captured.
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
        // Guest modesets lag host resizes, so preserve the old frame's aspect ratio.
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

    // AppKit routes Command shortcuts through the menu chain and suppresses keyUp.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.contains(.command) else { return false }
        sendKey(event, pressed: true)
        sendKey(event, pressed: false)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        // Generic flags cannot distinguish release of one side while the other is held.
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
            // macOS exposes Caps Lock as a toggle; the guest expects a key pulse.
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

    // Releases may go to another app after focus changes, leaving guest keys stuck.
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
            // Raw deltas already use the guest's y-down convention.
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

    // Off by default because logical points provide a conventional guest DPI.
    var hidpi = false
    var resizeDebounce: DispatchWorkItem?

    // Even widths keep the guest scanout stride IOSurface-friendly.
    private func guestSize() -> (UInt32, UInt32) {
        let scale = hidpi ? (window.backingScaleFactor) : 1.0
        let s = view.bounds.size
        let w = UInt32(max(s.width * scale, 1)) & ~1
        let h = UInt32(max(s.height * scale, 1))
        return (w, h)
    }

    // Update both guest display information and the host drawable.
    func requestGuestResize() {
        guard let surface else { return }
        let (w, h) = guestSize()
        let scale = hidpi ? window.backingScaleFactor : 1.0
        bobrvm_surface_set_content_scale(surface, scale, scale)
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
        // fbdev allocates once at boot and can only modeset smaller afterward.
        let work = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let width = work.width
        let height = work.height

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "bobrvm"
        window.center()
        window.delegate = self
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

        var kernel: String? = nil
        var initrd: String? = nil
        var disk: String? = nil
        var disk2: String? = nil
        var disk2ReadOnly: Bool? = nil
        var gpu3d = false
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
            case "--disk2": disk2 = args.next()
            case "--disk2-readonly": disk2ReadOnly = true
            case "--disk2-writable": disk2ReadOnly = false
            case "--gpu3d": gpu3d = true
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
            print("usage: BobrvmDisplay --kernel Image [--initrd initrd] [--disk disk.img] [--disk2 d2.img [--disk2-writable]] [--net] [--gpu3d] [--cpus 1] [--memory-mb 2048] [--hidpi]")
            NSApp.terminate(nil)
            return
        }

        // Keep C strings alive for the duration of bobrvm_vm_new (it copies).
        kernelPath.withCString { kernelC in
            withOptionalCString(initrd) { initrdC in
                withOptionalCString(disk) { diskC in
                  withOptionalCString(disk2) { disk2C in
                    cmdline.withCString { cmdlineC in
                        var cfg = bobrvm_vm_config_s()
                        cfg.memory_bytes = memoryMB * 1024 * 1024
                        cfg.vcpu_count = cpuCount
                        cfg.kernel_path = kernelC
                        cfg.initrd_path = initrdC
                        cfg.disk_path = diskC
                        cfg.disk_read_only = diskC != nil && (disk?.hasSuffix(".iso") ?? false)
                        cfg.cmdline = cmdlineC
                        cfg.disk2_path = disk2C
                        // Explicit disk access overrides the ISO default.
                        cfg.disk2_read_only = disk2ReadOnly ?? (disk2?.hasSuffix(".iso") ?? true)
                        cfg.enable_net = enableNet
                        cfg.enable_gpu3d = gpu3d
                        // Reserve enough fbdev storage for every attached screen at boot.
                        let scale = hidpi ? (NSScreen.main?.backingScaleFactor ?? 1.0) : 1.0
                        let maxScreen = NSScreen.screens.reduce(NSSize(width: 1280, height: 800)) {
                            NSSize(width: max($0.width, $1.frame.width * scale),
                                   height: max($0.height, $1.frame.height * scale))
                        }
                        cfg.display_width = UInt32(maxScreen.width) & ~1
                        cfg.display_height = UInt32(maxScreen.height)
                        vm = bobrvm_vm_new(bobrApp, &cfg)
                    }
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
        let scale = hidpi ? window.backingScaleFactor : 1.0
        bobrvm_surface_set_content_scale(surface, scale, scale)
        bobrvm_surface_set_size(surface, gw, gh)

        view.surface = surface
        window.makeFirstResponder(view)
        window.acceptsMouseMovedEvents = true

        // App switching can bypass the release events handled by MetalView.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.view.releaseMouse()
            self?.view.releaseAllModifiers()
        }

        // Poll pasteboard changes alongside this minimal app's render timer.
        var tick = 0
        var lastChangeCount = NSPasteboard.general.changeCount
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
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
        // Default-mode timers pause while AppKit tracks window and menu events.
        RunLoop.main.add(t, forMode: .common)
        timer = t

        // Shrink the boot-sized fbdev mode after the guest display stack starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.guestResizeNow()
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
