//
//  BobrvmKit.swift
//  Bobrvm
//
//  Swift wrappers around the C API with type safety.
//

import Foundation
import Metal
import QuartzCore

// MARK: - Error Types

public enum BobrvmError: Error, LocalizedError {
    case invalidArgument
    case invalidState
    case outOfMemory
    case hypervisorFailed
    case vmCreateFailed
    case vcpuCreateFailed
    case memoryMapFailed
    case surfaceCreateFailed
    case metalFailed
    case ioError
    case unknown(Int32)
    
    init(code: Int32) {
        switch code {
        case 0: self = .invalidArgument
        case 1: self = .invalidArgument
        case 2: self = .outOfMemory
        case 3: self = .hypervisorFailed
        case 4: self = .vmCreateFailed
        case 5: self = .vcpuCreateFailed
        case 6: self = .memoryMapFailed
        case 7: self = .surfaceCreateFailed
        case 8: self = .metalFailed
        case 9: self = .ioError
        default: self = .unknown(code)
        }
    }
    
    public var errorDescription: String? {
        switch self {
        case .invalidArgument: return "Invalid argument"
        case .invalidState: return "Operation not allowed in current state"
        case .outOfMemory: return "Out of memory"
        case .hypervisorFailed: return "Hypervisor initialization failed"
        case .vmCreateFailed: return "Failed to create VM"
        case .vcpuCreateFailed: return "Failed to create vCPU"
        case .memoryMapFailed: return "Failed to map memory"
        case .surfaceCreateFailed: return "Failed to create surface"
        case .metalFailed: return "Metal error"
        case .ioError: return "I/O error"
        case .unknown(let code): return "Unknown error (\(code))"
        }
    }
}

// MARK: - Input Types

public struct KeyEvent {
    public let keycode: UInt32
    public let modifiers: UInt32
    public let pressed: Bool
    
    public init(keycode: UInt32, modifiers: UInt32, pressed: Bool) {
        self.keycode = keycode
        self.modifiers = modifiers
        self.pressed = pressed
    }
    
    func toCStruct() -> bobrvm_key_event_s {
        return bobrvm_key_event_s(
            keycode: keycode,
            modifiers: modifiers,
            pressed: pressed
        )
    }
}

public enum MouseButton: Int32 {
    case left = 0
    case right = 1
    case middle = 2
}

// MARK: - VM Configuration

public struct VMConfig {
    public var memoryBytes: UInt64
    public var vcpuCount: UInt8
    /// UEFI firmware path (e.g., QEMU_EFI.fd). If set, boots via firmware.
    public var firmwarePath: String?
    /// UEFI variables file path. Created if doesn't exist.
    public var varsPath: String?
    public var kernelPath: String?
    public var initrdPath: String?
    public var cmdline: String?
    public var diskPath: String?
    public var diskReadOnly: Bool
    /// Secondary disk path (typically ISO for installation).
    public var isoPath: String?
    /// Whether ISO is read-only (default: true).
    public var isoReadOnly: Bool
    
    public init(
        memoryBytes: UInt64 = 512 * 1024 * 1024,
        vcpuCount: UInt8 = 2,
        firmwarePath: String? = nil,
        varsPath: String? = nil,
        kernelPath: String? = nil,
        initrdPath: String? = nil,
        cmdline: String? = nil,
        diskPath: String? = nil,
        diskReadOnly: Bool = false,
        isoPath: String? = nil,
        isoReadOnly: Bool = true
    ) {
        self.memoryBytes = memoryBytes
        self.vcpuCount = vcpuCount
        self.firmwarePath = firmwarePath
        self.varsPath = varsPath
        self.kernelPath = kernelPath
        self.initrdPath = initrdPath
        self.cmdline = cmdline
        self.diskPath = diskPath
        self.diskReadOnly = diskReadOnly
        self.isoPath = isoPath
        self.isoReadOnly = isoReadOnly
    }
    
    func withCConfig<T>(_ body: (UnsafePointer<bobrvm_vm_config_s>) throws -> T) rethrows -> T {
        var config = bobrvm_vm_config_s()
        config.memory_bytes = memoryBytes
        config.vcpu_count = vcpuCount
        config.disk_read_only = diskReadOnly
        config.disk2_read_only = isoReadOnly
        
        func withOptionalCString<R>(
            _ string: String?,
            _ body: (UnsafePointer<CChar>?) throws -> R
        ) rethrows -> R {
            if let string = string {
                return try string.withCString { try body($0) }
            } else {
                return try body(nil)
            }
        }
        
        return try withOptionalCString(firmwarePath) { firmwarePtr in
            config.firmware_path = firmwarePtr
            return try withOptionalCString(varsPath) { varsPtr in
                config.vars_path = varsPtr
                return try withOptionalCString(kernelPath) { kernelPtr in
                    config.kernel_path = kernelPtr
                    return try withOptionalCString(initrdPath) { initrdPtr in
                        config.initrd_path = initrdPtr
                        return try withOptionalCString(cmdline) { cmdlinePtr in
                            config.cmdline = cmdlinePtr
                            return try withOptionalCString(diskPath) { diskPtr in
                                config.disk_path = diskPtr
                                return try withOptionalCString(isoPath) { isoPtr in
                                    config.disk2_path = isoPtr
                                    return try withUnsafePointer(to: &config) { try body($0) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - App

@MainActor
public final class App {
    private var handle: bobrvm_app_t?
    private var runtimeConfig: bobrvm_runtime_config_s
    private var vms: [VM] = []
    
    public weak var delegate: BobrvmAppDelegate?
    
    public init() throws {
        runtimeConfig = bobrvm_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.wakeup = { userdata in
            guard let userdata = userdata else { return }
            let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                app.tick()
            }
        }
        runtimeConfig.set_title = { userdata, title in
            guard let userdata = userdata, let title = title else { return }
            let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            let titleStr = String(cString: title)
            DispatchQueue.main.async {
                app.delegate?.app(app, didRequestTitleChange: titleStr)
            }
        }
        runtimeConfig.request_close = { userdata in
            guard let userdata = userdata else { return }
            let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                app.delegate?.appDidRequestClose(app)
            }
        }
        runtimeConfig.read_clipboard = { userdata, outText in
            guard let userdata = userdata, let outText = outText else { return false }
            let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            guard let text = app.delegate?.appReadClipboard(app) else { return false }
            let cString = strdup(text)
            outText.pointee = cString
            return cString != nil
        }
        runtimeConfig.write_clipboard = { userdata, text in
            guard let userdata = userdata, let text = text else { return }
            let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            let textStr = String(cString: text)
            DispatchQueue.main.async {
                app.delegate?.app(app, didRequestWriteClipboard: textStr)
            }
        }
        runtimeConfig.free_clipboard = { _, text in
            if let text = text {
                free(text)
            }
        }
        runtimeConfig.gpu_frame_ready = { userdata in
            guard let userdata = userdata else { return }
            let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            app.delegate?.appGPUFrameReady(app)
        }
        runtimeConfig.console_output = { userdata, data, len in
            guard let userdata = userdata, let data = data, len > 0 else { return }
            let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            // Rebind from CChar (Int8) to UInt8 for String decoding
            let uint8Ptr = UnsafeRawPointer(data).bindMemory(to: UInt8.self, capacity: len)
            let buffer = UnsafeBufferPointer(start: uint8Ptr, count: len)
            let text = String(decoding: buffer, as: UTF8.self)
            DispatchQueue.main.async {
                app.delegate?.app(app, didReceiveConsoleOutput: text)
            }
        }
        
        guard let h = withUnsafePointer(to: &runtimeConfig, { bobrvm_app_new($0) }) else {
            throw BobrvmError.outOfMemory
        }
        handle = h
    }
    
    deinit {
        if let h = handle {
            bobrvm_app_destroy(h)
        }
    }
    
    public func tick() {
        guard let h = handle else { return }
        bobrvm_app_tick(h)
    }
    
    public func createVM(config: VMConfig) throws -> VM {
        guard let appHandle = handle else {
            throw BobrvmError.invalidArgument
        }
        
        let vm = try config.withCConfig { cfgPtr in
            guard let vmHandle = bobrvm_vm_new(appHandle, cfgPtr) else {
                throw BobrvmError.vmCreateFailed
            }
            return VM(handle: vmHandle, app: self)
        }
        
        vms.append(vm)
        return vm
    }
    
    func removeVM(_ vm: VM) {
        vms.removeAll { $0 === vm }
    }
}

// MARK: - App Delegate Protocol

@MainActor
public protocol BobrvmAppDelegate: AnyObject {
    func app(_ app: App, didRequestTitleChange title: String)
    func appDidRequestClose(_ app: App)
    func appReadClipboard(_ app: App) -> String?
    func app(_ app: App, didRequestWriteClipboard text: String)
    func appGPUFrameReady(_ app: App)
    func app(_ app: App, didReceiveConsoleOutput text: String)
}

public extension BobrvmAppDelegate {
    func app(_ app: App, didRequestTitleChange title: String) {}
    func appDidRequestClose(_ app: App) {}
    func appReadClipboard(_ app: App) -> String? { nil }
    func app(_ app: App, didRequestWriteClipboard text: String) {}
    func appGPUFrameReady(_ app: App) {}
    func app(_ app: App, didReceiveConsoleOutput text: String) {}
}

// MARK: - VM

@MainActor
public final class VM: ObservableObject {
    @Published public private(set) var state: VMState = .stopped
    
    private var handle: bobrvm_vm_t?
    private weak var app: App?
    private var surfaces: [Surface] = []
    
    init(handle: bobrvm_vm_t, app: App) {
        self.handle = handle
        self.app = app
    }
    
    deinit {
        if let h = handle {
            bobrvm_vm_destroy(h)
        }
    }
    
    public func start() throws {
        guard state == .stopped || state == .paused else {
            return  // Already running or invalid state
        }
        guard let h = handle else {
            throw BobrvmError.invalidArgument
        }
        let result = bobrvm_vm_start(h)
        if result.rawValue != 0 {
            throw BobrvmError(code: Int32(result.rawValue))
        }
        state = .running
    }
    
    public func stop() {
        guard let h = handle else { return }
        bobrvm_vm_stop(h)
        state = .stopped
    }
    
    public func pause() {
        guard let h = handle else { return }
        bobrvm_vm_pause(h)
        state = .paused
    }
    
    public func resume() {
        guard let h = handle else { return }
        bobrvm_vm_resume(h)
        state = .running
    }
    
    public func createSurface(
        device: MTLDevice,
        layer: CAMetalLayer,
        queue: MTLCommandQueue
    ) throws -> Surface {
        guard let vmHandle = handle else {
            throw BobrvmError.invalidArgument
        }
        
        let devicePtr = Unmanaged.passUnretained(device).toOpaque()
        let layerPtr = Unmanaged.passUnretained(layer).toOpaque()
        let queuePtr = Unmanaged.passUnretained(queue).toOpaque()
        
        guard let surfaceHandle = bobrvm_surface_new(vmHandle, devicePtr, layerPtr, queuePtr) else {
            throw BobrvmError.surfaceCreateFailed
        }
        
        let surface = Surface(handle: surfaceHandle, vm: self)
        surfaces.append(surface)
        return surface
    }
    
    func removeSurface(_ surface: Surface) {
        surfaces.removeAll { $0 === surface }
    }
    
    func destroy() {
        surfaces.removeAll()
        if let h = handle {
            bobrvm_vm_destroy(h)
            handle = nil
        }
        app?.removeVM(self)
    }
}

public enum VMState: String, CaseIterable {
    case stopped
    case running
    case paused
}

// MARK: - Surface

@MainActor
public final class Surface {
    private var handle: bobrvm_surface_t?
    private weak var vm: VM?
    
    init(handle: bobrvm_surface_t, vm: VM) {
        self.handle = handle
        self.vm = vm
    }
    
    deinit {
        if let h = handle {
            bobrvm_surface_destroy(h)
        }
    }
    
    public func setSize(width: UInt32, height: UInt32) {
        guard let h = handle else { return }
        bobrvm_surface_set_size(h, width, height)
    }
    
    public func setContentScale(x: Double, y: Double) {
        guard let h = handle else { return }
        bobrvm_surface_set_content_scale(h, x, y)
    }
    
    public func setFocus(_ focused: Bool) {
        guard let h = handle else { return }
        bobrvm_surface_set_focus(h, focused)
    }
    
    public func draw() {
        guard let h = handle else { return }
        bobrvm_surface_draw(h)
    }
    
    public func sendKey(_ event: KeyEvent) {
        guard let h = handle else { return }
        let cEvent = event.toCStruct()
        bobrvm_surface_key(h, cEvent)
    }
    
    public func sendMouseButton(_ button: MouseButton, pressed: Bool) {
        guard let h = handle else { return }
        bobrvm_surface_mouse_button(h, bobrvm_mouse_button_e(rawValue: UInt32(button.rawValue)), pressed)
    }
    
    public func sendMousePos(x: Double, y: Double) {
        guard let h = handle else { return }
        bobrvm_surface_mouse_pos(h, x, y)
    }
    
    public func sendMouseScroll(dx: Double, dy: Double) {
        guard let h = handle else { return }
        bobrvm_surface_mouse_scroll(h, dx, dy)
    }
    
    func destroy() {
        if let h = handle {
            bobrvm_surface_destroy(h)
            handle = nil
        }
        vm?.removeSurface(self)
    }
}

// MARK: - Version

public func bobrvmVersion() -> String {
    guard let version = bobrvm_version() else {
        return "unknown"
    }
    return String(cString: version)
}
