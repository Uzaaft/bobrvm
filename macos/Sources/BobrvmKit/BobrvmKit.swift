import Combine
import AppKit
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
    case alreadyExists
    case cannotShrink
    case unsupportedFormat
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
        case 10: self = .alreadyExists
        case 11: self = .cannotShrink
        case 12: self = .unsupportedFormat
        case 13: self = .invalidState
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
        case .alreadyExists: return "The file already exists"
        case .cannotShrink: return "Virtual disks cannot be safely shrunk"
        case .unsupportedFormat: return "The disk format is unsupported"
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

enum ConsoleEvent: Sendable {
    case output(Data)
    case clear
}

// MARK: - VM Configuration

public struct VMConfig {
    public var memoryBytes: UInt64
    public var vcpuCount: UInt8
    public var displayWidth: UInt32
    public var displayHeight: UInt32
    public var gpuMemoryBytes: UInt64
    public var networkEnabled: Bool
    public var sharedFolderPath: String?
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
        memoryBytes: UInt64? = nil,
        vcpuCount: UInt8? = nil,
        displayWidth: UInt32? = nil,
        displayHeight: UInt32? = nil,
        gpuMemoryBytes: UInt64? = nil,
        networkEnabled: Bool? = nil,
        sharedFolderPath: String? = nil,
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
        let defaults = bobrvm_vm_config_defaults()
        self.memoryBytes = memoryBytes ?? defaults.memory_bytes
        self.vcpuCount = vcpuCount ?? defaults.vcpu_count
        self.displayWidth = displayWidth ?? defaults.display_width
        self.displayHeight = displayHeight ?? defaults.display_height
        self.gpuMemoryBytes = gpuMemoryBytes ?? defaults.gpu_memory_bytes
        self.networkEnabled = networkEnabled ?? defaults.enable_net
        self.sharedFolderPath = sharedFolderPath
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
        config.display_width = displayWidth
        config.display_height = displayHeight
        config.gpu_memory_bytes = gpuMemoryBytes
        config.enable_net = networkEnabled
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
                                    return try withOptionalCString(sharedFolderPath) { sharePtr in
                                        config.shared_dir = sharePtr
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
}

// MARK: - Virtual Disks

public enum VirtualDisk {
    public static func createSparse(path: String, sizeBytes: UInt64) throws {
        let code = path.withCString { bobrvm_disk_create_sparse($0, sizeBytes) }
        if code.rawValue != BOBRVM_OK.rawValue {
            throw BobrvmError(code: Int32(code.rawValue))
        }
    }

    public static func growRaw(path: String, sizeBytes: UInt64) throws {
        let code = path.withCString { bobrvm_disk_grow_raw($0, sizeBytes) }
        if code.rawValue != BOBRVM_OK.rawValue {
            throw BobrvmError(code: Int32(code.rawValue))
        }
    }

    public static func logicalSize(path: String) throws -> UInt64 {
        var sizeBytes: UInt64 = 0
        let code = path.withCString { bobrvm_disk_logical_size($0, &sizeBytes) }
        if code.rawValue != BOBRVM_OK.rawValue {
            throw BobrvmError(code: Int32(code.rawValue))
        }
        return sizeBytes
    }
}

public enum VMFilename {
    public static func sanitize(_ name: String) -> String {
        name.withCString { input in
            var output = [CChar](repeating: 0, count: Int(strlen(input)) + 1)
            var outputLength = 0
            let code = bobrvm_filename_sanitize(
                input,
                &output,
                output.count - 1,
                &outputLength
            )
            precondition(code.rawValue == BOBRVM_OK.rawValue, "Filename buffer invariant failed")
            return String(decoding: output[0..<outputLength].map(UInt8.init), as: UTF8.self)
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
        runtimeConfig.console_output = { userdata, vmHandle, data, len in
            guard let userdata = userdata, let vmHandle, let data = data, len > 0 else { return }
            let app = Unmanaged<App>.fromOpaque(userdata).takeUnretainedValue()
            let output = Data(bytes: data, count: len)
            DispatchQueue.main.async {
                guard let vm = app.vms.first(where: { $0.matches(vmHandle) }) else { return }
                vm.appendConsoleOutput(output)
                app.delegate?.app(app, vm: vm, didReceiveConsoleOutput: output)
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
        refreshGuestToolsStatus()
    }

    public func refreshGuestToolsStatus() {
        for vm in vms {
            vm.refreshGuestToolsStatus()
        }
    }

    public func createVM(config: VMConfig) throws -> VM {
        guard let appHandle = handle else {
            throw BobrvmError.invalidArgument
        }

        let vm = try config.withCConfig { cfgPtr in
            let validationCode = bobrvm_vm_config_validate(cfgPtr)
            guard validationCode.rawValue == BOBRVM_OK.rawValue else {
                throw BobrvmError(code: Int32(validationCode.rawValue))
            }
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

    /// Announce a host pasteboard change to every running Linux VM. The
    /// SPICE agent requests the contents lazily when the guest pastes.
    public func notifyHostClipboardChanged() {
        for vm in vms where vm.state == .running {
            vm.hostClipboardChanged()
        }
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
    func app(_ app: App, vm: VM, didReceiveConsoleOutput data: Data)
}

extension BobrvmAppDelegate {
    public func app(_ app: App, didRequestTitleChange title: String) {}
    public func appDidRequestClose(_ app: App) {}
    public func appReadClipboard(_ app: App) -> String? { nil }
    public func app(_ app: App, didRequestWriteClipboard text: String) {}
    public func appGPUFrameReady(_ app: App) {}
    public func app(_ app: App, vm: VM, didReceiveConsoleOutput data: Data) {}
}

// MARK: - VM

@MainActor
public final class VM: ObservableObject {
    @Published public private(set) var state: VMState = .stopped
    @Published public private(set) var isStopping = false
    @Published public private(set) var guestToolsStatus = GuestToolsStatus.disconnected
    private(set) var consoleOutputData = Data()

    public var consoleOutput: String {
        String(decoding: consoleOutputData, as: UTF8.self)
    }

    private var handle: bobrvm_vm_t?
    private weak var app: App?
    private var surfaces: [Surface] = []
    private let consoleEventSubject = PassthroughSubject<ConsoleEvent, Never>()

    var consoleEventPublisher: AnyPublisher<ConsoleEvent, Never> {
        consoleEventSubject.eraseToAnyPublisher()
    }

    init(handle: bobrvm_vm_t, app: App) {
        self.handle = handle
        self.app = app
    }

    func matches(_ candidate: bobrvm_vm_t) -> Bool {
        handle == candidate
    }

    func appendConsoleOutput(_ data: Data) {
        consoleOutputData.append(data)
        consoleEventSubject.send(.output(data))

        guard consoleOutputData.count > 125_000 else { return }
        consoleOutputData.removeFirst(consoleOutputData.count - 100_000)
    }

    public func clearConsoleOutput() {
        consoleOutputData.removeAll(keepingCapacity: true)
        consoleEventSubject.send(.clear)
    }

    func refreshGuestToolsStatus() {
        guard let handle else {
            guestToolsStatus = .disconnected
            return
        }
        let status = GuestToolsStatus(bobrvm_vm_guest_tools_status(handle))
        if status != guestToolsStatus {
            guestToolsStatus = status
        }
    }

    deinit {
        if let h = handle {
            bobrvm_vm_destroy(h)
        }
    }

    public func start() throws {
        guard !isStopping, state == .stopped || state == .paused else {
            return
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
        guard !isStopping, let h = handle else { return }
        isStopping = true
        let sendableHandle = SendableVMHandle(value: h)
        bobrvm_vm_request_stop(h)
        let stopTask = Task.detached(priority: .userInitiated) { [sendableHandle] in
            bobrvm_vm_finish_stop(sendableHandle.value)
        }
        Task { [self, stopTask] in
            await stopTask.value
            state = .stopped
            isStopping = false
        }
    }

    public func pause() {
        guard !isStopping, let h = handle else { return }
        bobrvm_vm_pause(h)
        state = .paused
    }

    public func resume() {
        guard !isStopping, let h = handle else { return }
        bobrvm_vm_resume(h)
        state = .running
    }

    public func sendConsoleInput(_ data: Data) throws {
        guard let h = handle else { throw BobrvmError.invalidState }
        let result = data.withUnsafeBytes { buffer in
            bobrvm_vm_console_write(
                h,
                buffer.bindMemory(to: UInt8.self).baseAddress,
                buffer.count
            )
        }
        guard result.rawValue == BOBRVM_OK.rawValue else {
            throw BobrvmError(code: Int32(result.rawValue))
        }
    }

    public func resizeConsole(columns: UInt16, rows: UInt16) throws {
        guard let h = handle else { throw BobrvmError.invalidState }
        let result = bobrvm_vm_console_resize(h, columns, rows)
        guard result.rawValue == BOBRVM_OK.rawValue else {
            throw BobrvmError(code: Int32(result.rawValue))
        }
    }

    public func shutdownGracefully() {
        guard let handle else { return }
        bobrvm_vm_shutdown_graceful(handle)
    }

    public func rebootGuest() {
        guard let handle else { return }
        bobrvm_vm_guest_reboot(handle)
    }

    public func trimGuestFilesystems() {
        guard let handle else { return }
        bobrvm_vm_guest_trim(handle)
    }

    public func synchronizeGuestTime() {
        guard let handle else { return }
        bobrvm_vm_guest_sync_time(handle)
    }

    public func hostClipboardChanged() {
        guard let handle else { return }
        bobrvm_vm_host_clipboard_changed(handle)
    }

    public var isGuestManagementReady: Bool {
        guard let handle else { return false }
        return bobrvm_vm_guest_management_ready(handle)
    }

    public func snapshotQuiesced(to directory: URL) async throws {
        guard let handle else { throw BobrvmError.invalidState }
        let sendableHandle = SendableVMHandle(value: handle)
        let path = directory.path
        let code = await Task.detached(priority: .userInitiated) {
            path.withCString { directoryPath in
                bobrvm_vm_snapshot_quiesced(sendableHandle.value, directoryPath)
            }
        }.value
        guard code.rawValue == BOBRVM_OK.rawValue else {
            throw BobrvmError(code: Int32(code.rawValue))
        }
    }

    public func sendFileToGuest(_ file: URL) throws {
        guard let handle else { throw BobrvmError.invalidState }
        let code = file.path.withCString { path in
            bobrvm_vm_send_file(handle, path)
        }
        guard code.rawValue == BOBRVM_OK.rawValue else {
            throw BobrvmError(code: Int32(code.rawValue))
        }
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

public struct GuestToolsStatus: Equatable, Sendable {
    public enum Connection: Equatable, Sendable {
        case disconnected
        case connecting
        case ready
        case protocolError
    }

    public let connection: Connection
    public let capabilities: UInt64

    public var supportsClipboard: Bool {
        capabilities & UInt64(BOBRVM_GUEST_TOOLS_CLIPBOARD.rawValue) != 0
    }

    public var supportsFileTransfer: Bool {
        capabilities & UInt64(BOBRVM_GUEST_TOOLS_FILE_TRANSFER.rawValue) != 0
    }

    public var supportsManagement: Bool {
        capabilities & UInt64(BOBRVM_GUEST_TOOLS_MANAGEMENT.rawValue) != 0
    }

    public static let disconnected = GuestToolsStatus(
        connection: .disconnected,
        capabilities: 0
    )

    init(_ status: bobrvm_guest_tools_status_s) {
        connection = switch status.connection.rawValue {
        case BOBRVM_GUEST_TOOLS_CONNECTING.rawValue: .connecting
        case BOBRVM_GUEST_TOOLS_READY.rawValue: .ready
        case BOBRVM_GUEST_TOOLS_PROTOCOL_ERROR.rawValue: .protocolError
        default: .disconnected
        }
        capabilities = status.capabilities
    }

    public init(connection: Connection, capabilities: UInt64) {
        self.connection = connection
        self.capabilities = capabilities
    }
}

public struct MacVMConfig {
    public let memoryBytes: UInt64
    public let vcpuCount: UInt8
    public let displayWidth: UInt32
    public let displayHeight: UInt32
    public let retinaEnabled: Bool
    public let diskPath: String
    public let auxiliaryStoragePath: String
    public let hardwareModel: String
    public let machineIdentifier: String
    public let macAddress: String

    public init(
        memoryBytes: UInt64,
        vcpuCount: UInt8,
        displayWidth: UInt32,
        displayHeight: UInt32,
        retinaEnabled: Bool,
        diskPath: String,
        auxiliaryStoragePath: String,
        hardwareModel: String,
        machineIdentifier: String,
        macAddress: String
    ) {
        self.memoryBytes = memoryBytes
        self.vcpuCount = vcpuCount
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.retinaEnabled = retinaEnabled
        self.diskPath = diskPath
        self.auxiliaryStoragePath = auxiliaryStoragePath
        self.hardwareModel = hardwareModel
        self.machineIdentifier = machineIdentifier
        self.macAddress = macAddress
    }

    fileprivate func withCConfig<T>(
        _ body: (UnsafePointer<bobrvm_macos_vm_config_s>) throws -> T
    ) rethrows -> T {
        try diskPath.withCString { disk in
            try auxiliaryStoragePath.withCString { auxiliary in
                try hardwareModel.withCString { hardware in
                    try machineIdentifier.withCString { identifier in
                        try macAddress.withCString { mac in
                            var config = bobrvm_macos_vm_config_s(
                                memory_bytes: memoryBytes,
                                vcpu_count: vcpuCount,
                                display_width: displayWidth,
                                display_height: displayHeight,
                                retina: retinaEnabled,
                                disk_path: disk,
                                auxiliary_storage_path: auxiliary,
                                hardware_model_base64: hardware,
                                machine_identifier_base64: identifier,
                                mac_address: mac
                            )
                            return try withUnsafePointer(to: &config, body)
                        }
                    }
                }
            }
        }
    }
}

@MainActor
public final class MacVM: ObservableObject {
    @Published public private(set) var state: VMState = .stopped
    public var displayView: NSView? {
        guard let handle, let pointer = bobrvm_macos_vm_display_view(handle) else { return nil }
        return Unmanaged<NSView>.fromOpaque(pointer).takeUnretainedValue()
    }

    private var handle: bobrvm_macos_vm_t?
    private var stateTimer: DispatchSourceTimer?

    public init(config: MacVMConfig) throws {
        handle = try config.withCConfig { pointer in
            guard let handle = bobrvm_macos_vm_new(pointer) else {
                throw BobrvmError.vmCreateFailed
            }
            return handle
        }
    }

    deinit {
        stateTimer?.cancel()
        if let handle { bobrvm_macos_vm_destroy(handle) }
    }

    public func start() throws {
        guard let handle else { throw BobrvmError.invalidState }
        let code = bobrvm_macos_vm_start(handle)
        guard code.rawValue == BOBRVM_OK.rawValue else {
            throw BobrvmError(code: Int32(code.rawValue))
        }
        state = .running
        beginStatePolling()
    }

    public func stop() {
        guard let handle else { return }
        bobrvm_macos_vm_stop(handle)
        beginStatePolling()
    }

    public func pause() {
        guard let handle else { return }
        bobrvm_macos_vm_pause(handle)
        beginStatePolling()
    }

    public func resume() {
        guard let handle else { return }
        bobrvm_macos_vm_resume(handle)
        beginStatePolling()
    }

    public func install(
        restorePath: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let handle else { throw BobrvmError.invalidState }
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                progress(bobrvm_macos_vm_install_progress(handle))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer { progressTask.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            let box = MacInstallContinuation(continuation)
            let userdata = Unmanaged.passRetained(box).toOpaque()
            let code = restorePath.withCString {
                bobrvm_macos_vm_install(handle, $0, userdata, macInstallCompletion)
            }
            guard code.rawValue != BOBRVM_OK.rawValue else { return }
            Unmanaged<MacInstallContinuation>.fromOpaque(userdata).release()
            continuation.resume(throwing: BobrvmError(code: Int32(code.rawValue)))
        }
        progress(1)
    }

    public func destroy() {
        stateTimer?.cancel()
        stateTimer = nil
        if let handle {
            bobrvm_macos_vm_destroy(handle)
            self.handle = nil
        }
        state = .stopped
    }

    private func beginStatePolling() {
        guard stateTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.pollState() }
        }
        stateTimer = timer
        timer.resume()
    }

    private func pollState() {
        guard let handle else { return }
        switch bobrvm_macos_vm_state(handle) {
        case BOBRVM_VM_STATE_RUNNING:
            state = .running
        case BOBRVM_VM_STATE_PAUSED:
            state = .paused
        case BOBRVM_VM_STATE_STOPPED, BOBRVM_VM_STATE_FAILED:
            state = .stopped
            stateTimer?.cancel()
            stateTimer = nil
        default:
            break
        }
    }
}

private final class MacInstallContinuation: @unchecked Sendable {
    let value: CheckedContinuation<Void, Error>

    init(_ value: CheckedContinuation<Void, Error>) {
        self.value = value
    }
}

private func macInstallCompletion(_ userdata: UnsafeMutableRawPointer?, _ success: Bool) {
    guard let userdata else { return }
    let box = Unmanaged<MacInstallContinuation>.fromOpaque(userdata).takeRetainedValue()
    if success {
        box.value.resume()
    } else {
        box.value.resume(throwing: BobrvmError.vmCreateFailed)
    }
}

private struct SendableVMHandle: @unchecked Sendable {
    let value: bobrvm_vm_t
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

    public func requestDisplaySize(width: UInt32, height: UInt32) {
        guard let h = handle else { return }
        bobrvm_surface_request_display_size(h, width, height)
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
        bobrvm_surface_mouse_button(
            h, bobrvm_mouse_button_e(rawValue: UInt32(button.rawValue)), pressed)
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
