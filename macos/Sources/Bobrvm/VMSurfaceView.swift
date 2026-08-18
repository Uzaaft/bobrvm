import AppKit
import Combine
import Metal
import OSLog
import QuartzCore
import SwiftUI

private let logger = Logger(subsystem: "com.bobrvm.app", category: "VMSurfaceView")

public final class VMSurfaceView: NSView {
    private static let guestCursor = NSCursor(
        image: NSImage(
            size: NSSize(width: 1, height: 1),
            flipped: false,
            drawingHandler: { _ in true }
        ),
        hotSpot: .zero
    )

    private var metalLayer: CAMetalLayer!
    private var device: MTLDevice!
    private var commandQueue: MTLCommandQueue!
    private var displayLink: CVDisplayLink?
    private var surface: Surface?
    private weak var vmInstance: VMInstance?
    private var cancellables = Set<AnyCancellable>()
    private var guestResizeWorkItem: DispatchWorkItem?
    private var lastGuestDisplaySize = CGSize.zero

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true

        guard let mtlDevice = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this device")
        }
        device = mtlDevice

        guard let queue = device.makeCommandQueue() else {
            fatalError("Failed to create Metal command queue")
        }
        commandQueue = queue

        metalLayer = CAMetalLayer()
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.displaySyncEnabled = true
        metalLayer.contentsScale = 1.0
        layer = metalLayer

        setupDisplayLink()
    }

    deinit {
        guestResizeWorkItem?.cancel()
        stopDisplayLink()
    }

    // MARK: - VM Surface Management

    @MainActor
    public func attach(to vmInstance: VMInstance) throws {
        logger.info("Attaching surface to VM: \(vmInstance.name)")
        self.vmInstance = vmInstance

        let newSurface = try vmInstance.requireVM().createSurface(
            device: device,
            layer: metalLayer,
            queue: commandQueue
        )
        surface = newSurface
        vmInstance.surface = newSurface
        logger.info("Surface created successfully")

        updateSurfaceSize()
        updateContentScale()
        window?.invalidateCursorRects(for: self)

        startDisplayLink()
        logger.info("Display link started")
    }

    public func detach() {
        guestResizeWorkItem?.cancel()
        guestResizeWorkItem = nil
        lastGuestDisplaySize = .zero
        stopDisplayLink()
        surface = nil
        vmInstance?.surface = nil
        vmInstance = nil
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Layer

    public override func makeBackingLayer() -> CALayer {
        metalLayer ?? CAMetalLayer()
    }

    public override var wantsUpdateLayer: Bool { true }

    public override func updateLayer() {
        updateSurfaceSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        metalLayer?.drawableSize = CGSize(
            width: newSize.width * metalLayer.contentsScale,
            height: newSize.height * metalLayer.contentsScale
        )
        updateSurfaceSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentScale()
    }

    public func refreshDisplayPreferences() {
        guard vmInstance != nil else { return }
        updateContentScale()
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        guard surface != nil else { return }
        addCursorRect(bounds, cursor: Self.guestCursor)
    }

    private func updateSurfaceSize() {
        let size = metalLayer.drawableSize
        surface?.setSize(width: UInt32(size.width), height: UInt32(size.height))
        scheduleGuestResize()
    }

    private func updateContentScale() {
        let scale =
            vmInstance?.retinaEnabled == true
            ? window?.backingScaleFactor ?? 2.0
            : 1.0
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        surface?.setContentScale(x: scale, y: scale)
        updateSurfaceSize()
    }

    private func scheduleGuestResize() {
        guard surface != nil, let vmInstance else { return }

        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width >= 320, drawableSize.height >= 240 else { return }

        let maximumSize = CGSize(
            width: CGFloat(vmInstance.config.displayWidth),
            height: CGFloat(vmInstance.config.displayHeight)
        )
        let scale = min(
            1,
            maximumSize.width / drawableSize.width,
            maximumSize.height / drawableSize.height
        )
        let width = floor(drawableSize.width * scale / 2) * 2
        let height = floor(drawableSize.height * scale / 2) * 2
        let requestedSize = CGSize(width: width, height: height)
        guard requestedSize != lastGuestDisplaySize else { return }

        guestResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let surface = self.surface else { return }
            surface.requestDisplaySize(
                width: UInt32(requestedSize.width),
                height: UInt32(requestedSize.height)
            )
            self.lastGuestDisplaySize = requestedSize
        }
        guestResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    // MARK: - Display Link

    private func setupDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else { return }
        self.displayLink = displayLink

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let view = Unmanaged<VMSurfaceView>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                view.surface?.draw()
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(
            displayLink,
            callback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func startDisplayLink() {
        guard let displayLink = displayLink else { return }
        if !CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStart(displayLink)
        }
    }

    private func stopDisplayLink() {
        guard let displayLink = displayLink else { return }
        if CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }

    // MARK: - First Responder

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        surface?.setFocus(true)
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        surface?.setFocus(false)
        return super.resignFirstResponder()
    }

    // MARK: - Keyboard Input

    public override func keyDown(with event: NSEvent) {
        let keyEvent = KeyEvent(
            keycode: UInt32(event.keyCode),
            modifiers: UInt32(event.modifierFlags.rawValue),
            pressed: true
        )
        surface?.sendKey(keyEvent)
    }

    public override func keyUp(with event: NSEvent) {
        let keyEvent = KeyEvent(
            keycode: UInt32(event.keyCode),
            modifiers: UInt32(event.modifierFlags.rawValue),
            pressed: false
        )
        surface?.sendKey(keyEvent)
    }

    public override func flagsChanged(with event: NSEvent) {
        let keyEvent = KeyEvent(
            keycode: UInt32(event.keyCode),
            modifiers: UInt32(event.modifierFlags.rawValue),
            pressed: event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.control)
                || event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command)
        )
        surface?.sendKey(keyEvent)
    }

    // MARK: - Mouse Input

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMousePosition(event)
        surface?.sendMouseButton(.left, pressed: true)
    }

    public override func mouseUp(with event: NSEvent) {
        surface?.sendMouseButton(.left, pressed: false)
    }

    public override func rightMouseDown(with event: NSEvent) {
        sendMousePosition(event)
        surface?.sendMouseButton(.right, pressed: true)
    }

    public override func rightMouseUp(with event: NSEvent) {
        surface?.sendMouseButton(.right, pressed: false)
    }

    public override func otherMouseDown(with event: NSEvent) {
        sendMousePosition(event)
        surface?.sendMouseButton(.middle, pressed: true)
    }

    public override func otherMouseUp(with event: NSEvent) {
        surface?.sendMouseButton(.middle, pressed: false)
    }

    private func sendMousePosition(_ event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        surface?.sendMousePos(x: location.x, y: bounds.height - location.y)
    }

    public override func mouseMoved(with event: NSEvent) {
        sendMousePosition(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        sendMousePosition(event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        mouseDragged(with: event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        mouseDragged(with: event)
    }

    public override func scrollWheel(with event: NSEvent) {
        surface?.sendMouseScroll(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY)
    }

    // MARK: - Tracking Area

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()

        for area in trackingAreas {
            removeTrackingArea(area)
        }

        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect]
        let trackingArea = NSTrackingArea(
            rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
    }
}

// MARK: - SwiftUI Representable

public struct VMSurfaceRepresentable: NSViewRepresentable {
    @ObservedObject var vmInstance: VMInstance

    public init(vmInstance: VMInstance) {
        self.vmInstance = vmInstance
    }

    public func makeNSView(context: Context) -> VMSurfaceView {
        let view = VMSurfaceView(frame: .zero)
        return view
    }

    public func updateNSView(_ nsView: VMSurfaceView, context: Context) {
        logger.debug(
            "updateNSView called, surface=\(vmInstance.surface == nil ? "nil" : "exists"), state=\(vmInstance.state.rawValue)"
        )
        if vmInstance.surface == nil
            && (vmInstance.state == .running || vmInstance.state == .paused)
        {
            Task { @MainActor in
                do {
                    try nsView.attach(to: vmInstance)
                } catch {
                    logger.error("Failed to attach surface: \(error.localizedDescription)")
                }
            }
        } else {
            nsView.refreshDisplayPreferences()
        }
    }

    public static func dismantleNSView(_ nsView: VMSurfaceView, coordinator: Void) {
        nsView.detach()
    }
}
