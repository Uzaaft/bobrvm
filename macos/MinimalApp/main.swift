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
        metalLayer.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override var acceptsFirstResponder: Bool { true }

    private func sendKey(_ event: NSEvent, pressed: Bool) {
        guard let surface else { return }
        var key = bobrvm_key_event_s()
        key.keycode = UInt32(event.keyCode)
        key.modifiers = UInt32(event.modifierFlags.rawValue & 0xFFFF_FFFF)
        key.pressed = pressed
        bobrvm_surface_key(surface, key)
    }

    override func keyDown(with event: NSEvent) { sendKey(event, pressed: true) }
    override func keyUp(with event: NSEvent) { sendKey(event, pressed: false) }

    override func flagsChanged(with event: NSEvent) {
        // Modifier keys: derive press/release from the flag transition.
        let flagFor: [UInt16: NSEvent.ModifierFlags] = [
            0x37: .command, 0x36: .command,
            0x38: .shift, 0x3C: .shift,
            0x3A: .option, 0x3D: .option,
            0x3B: .control, 0x3E: .control,
            0x39: .capsLock,
        ]
        if let flag = flagFor[event.keyCode] {
            sendKey(event, pressed: event.modifierFlags.contains(flag))
        }
        if mouseCaptured, event.modifierFlags.contains(.control), event.modifierFlags.contains(.option) {
            releaseMouse()
        }
        lastFlags = event.modifierFlags
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var view: MetalView!
    var timer: Timer?

    var bobrApp: bobrvm_app_t?
    var vm: bobrvm_vm_t?
    var surface: bobrvm_surface_t?

    // Retained for the app's lifetime: Zig holds raw pointers to these.
    var device: MTLDevice!
    var queue: MTLCommandQueue!

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
            default: print("unknown argument: \(arg)")
            }
        }
        guard let kernelPath = kernel else {
            print("usage: BobrvmDisplay --kernel Image [--initrd initrd] [--disk disk.img] [--net] [--cpus 1] [--memory-mb 2048]")
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
        bobrvm_surface_set_size(surface, UInt32(width), UInt32(height))

        // Route input events from the view to the guest.
        view.surface = surface
        window.makeFirstResponder(view)
        window.acceptsMouseMovedEvents = true

        // Safety net: don't leave the host cursor hidden/ungrabbed if the
        // user switches away from the app some other way than ⌃⌥.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.view.releaseMouse() }

        // Drive frames at 60 Hz. (CVDisplayLink integration comes with
        // the full app; a timer is enough to verify the pipeline.)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self, let surface = self.surface else { return }
            bobrvm_surface_draw(surface)
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
