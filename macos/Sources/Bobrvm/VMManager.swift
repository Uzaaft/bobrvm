import Combine
import Foundation
import OSLog

@MainActor
public final class VMManager: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.bobrvm.app",
        category: "VMManager"
    )

    @Published public var vms: [VMInstance] = []
    @Published public var showingCreateVM = false

    weak var app: App?

    private let frameReadySubject = PassthroughSubject<Void, Never>()
    public var frameReadyPublisher: AnyPublisher<Void, Never> {
        frameReadySubject.eraseToAnyPublisher()
    }

    public init() {}

    public func loadExistingVMs() {
        guard let app else {
            Self.logger.warning("Cannot load VMs: app not initialized")
            return
        }

        let storedConfigs = VMStorage.loadAllVMs()
        Self.logger.info("Found \(storedConfigs.count) stored VM(s)")

        for stored in storedConfigs {
            let instance = VMInstance(
                id: stored.id,
                name: stored.name,
                config: stored.vmConfig,
                app: app,
                isoPath: stored.isoPath,
                retinaEnabled: stored.retinaEnabled ?? true,
                guestSystem: stored.guestSystem ?? .linux,
                macOSPlatform: stored.macOSPlatform
            )
            vms.append(instance)
            Self.logger.info("Loaded VM: \(stored.name)")
        }
    }

    public func createVM(
        name: String,
        config: VMConfig,
        isoPath: String? = nil,
        retinaEnabled: Bool = true
    ) throws {
        guard let app else {
            throw BobrvmError.invalidArgument
        }

        let vm = try app.createVM(config: config)
        do {
            let instance = VMInstance(
                name: name,
                config: config,
                app: app,
                vm: vm,
                isoPath: isoPath,
                retinaEnabled: retinaEnabled
            )
            try VMStorage.saveVM(instance)
            vms.append(instance)
            Self.logger.info("Saved VM configuration: \(name)")
        } catch {
            vm.destroy()
            throw error
        }
    }

    public func createMacOSVM(
        name: String,
        ipswPath: String?,
        memoryBytes: UInt64,
        vcpuCount: UInt8,
        displayWidth: UInt32,
        displayHeight: UInt32,
        diskSizeGB: Int,
        retinaEnabled: Bool,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let app else { throw BobrvmError.invalidArgument }

        let id = UUID()
        let bundleURL = DiskManager.macOSBundleURL(id: id)
        do {
            let assets = try DiskManager.createMacOSAssets(
                id: id,
                diskSizeGB: diskSizeGB
            )
            let result = try await MacOSRestoreService.install(
                ipswURL: ipswPath.map(URL.init(fileURLWithPath:)),
                diskURL: assets.disk,
                auxiliaryStorageURL: assets.auxiliaryStorage,
                memoryBytes: memoryBytes,
                vcpuCount: vcpuCount,
                displayWidth: displayWidth,
                displayHeight: displayHeight,
                retinaEnabled: retinaEnabled,
                progress: progress
            )
            let instance = VMInstance(
                id: id,
                name: name,
                config: result.config,
                app: app,
                retinaEnabled: retinaEnabled,
                guestSystem: .macOS,
                macOSPlatform: result.metadata
            )
            try VMStorage.saveVM(instance)
            vms.append(instance)
            Self.logger.info("Installed macOS virtual machine: \(name)")
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }
    }

    public func deleteVM(_ instance: VMInstance) {
        instance.destroy()
        vms.removeAll { $0.id == instance.id }

        VMStorage.deleteVM(id: instance.id)
    }

    public func updateVM(
        _ instance: VMInstance,
        name: String,
        memoryGB: Int,
        vcpuCount: Int,
        vramMB: Int,
        isoPath: String?,
        displayWidth: Int,
        displayHeight: Int,
        retinaEnabled: Bool,
        networkEnabled: Bool,
        sharedFolderPath: String?,
        diskSizeGB: Int?
    ) throws {
        guard instance.state == .stopped else {
            throw BobrvmError.invalidState
        }

        if let diskSizeGB, let diskPath = instance.config.diskPath {
            try DiskManager.growRawDisk(path: diskPath, sizeGB: diskSizeGB)
        }

        let newConfig = VMConfig(
            memoryBytes: UInt64(memoryGB) * 1024 * 1024 * 1024,
            vcpuCount: UInt8(vcpuCount),
            displayWidth: UInt32(displayWidth),
            displayHeight: UInt32(displayHeight),
            gpuMemoryBytes: UInt64(vramMB) * 1024 * 1024,
            networkEnabled: networkEnabled,
            sharedFolderPath: sharedFolderPath,
            firmwarePath: instance.config.firmwarePath,
            varsPath: instance.config.varsPath,
            kernelPath: instance.config.kernelPath,
            initrdPath: instance.config.initrdPath,
            cmdline: instance.config.cmdline,
            diskPath: instance.config.diskPath,
            diskReadOnly: instance.config.diskReadOnly,
            isoPath: isoPath,
            isoReadOnly: true
        )

        guard let index = vms.firstIndex(where: { $0.id == instance.id }) else {
            throw BobrvmError.invalidArgument
        }

        guard let app else { throw BobrvmError.invalidArgument }
        let newVM = instance.guestSystem == .linux
            ? try app.createVM(config: newConfig)
            : nil
        let updatedInstance = VMInstance(
            id: instance.id,
            name: name,
            config: newConfig,
            app: app,
            vm: newVM,
            isoPath: isoPath,
            retinaEnabled: retinaEnabled,
            guestSystem: instance.guestSystem,
            macOSPlatform: instance.macOSPlatform
        )

        do {
            try VMStorage.saveVM(updatedInstance)
        } catch {
            newVM?.destroy()
            throw error
        }

        instance.destroy()
        vms[index] = updatedInstance

        Self.logger.info("Updated VM configuration: \(name)")
    }

    public func stopAllVMs() {
        for instance in vms {
            instance.stop()
        }
    }

    func notifyFrameReady() {
        frameReadySubject.send()
    }

}

// MARK: - VM Instance

@MainActor
public final class VMInstance: ObservableObject, Identifiable, Hashable {
    public nonisolated static func == (lhs: VMInstance, rhs: VMInstance) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    public let id: UUID
    public let name: String
    public let config: VMConfig
    private let app: App
    private var vm: VM?
    public let isoPath: String?
    public let retinaEnabled: Bool
    public let guestSystem: GuestSystem
    let macOSPlatform: MacOSPlatformMetadata?

    @Published public var surface: Surface?

    private var vmStateCancellable: AnyCancellable?
    private var macVM: MacVirtualMachine?
    private var macVMStateCancellable: AnyCancellable?

    public init(
        id: UUID = UUID(),
        name: String,
        config: VMConfig,
        app: App,
        vm: VM? = nil,
        isoPath: String? = nil,
        retinaEnabled: Bool = true,
        guestSystem: GuestSystem = .linux,
        macOSPlatform: MacOSPlatformMetadata? = nil
    ) {
        self.id = id
        self.name = name
        self.config = config
        self.app = app
        self.vm = vm
        self.isoPath = isoPath
        self.retinaEnabled = retinaEnabled
        self.guestSystem = guestSystem
        self.macOSPlatform = macOSPlatform

        observeVM()
    }

    public var state: VMState {
        switch guestSystem {
        case .linux: return vm?.state ?? .stopped
        case .macOS: return macVM?.state ?? .stopped
        }
    }

    public var vramMB: Int {
        Int(config.gpuMemoryBytes / (1024 * 1024))
    }

    public var guestToolsStatus: GuestToolsStatus {
        vm?.guestToolsStatus ?? .disconnected
    }

    public var isGuestManagementReady: Bool {
        vm?.isGuestManagementReady ?? false
    }

    var runtimeVM: VM? {
        vm
    }

    var runtimeMacVM: MacVirtualMachine? {
        macVM
    }

    public func start() throws {
        if guestSystem == .macOS {
            guard let macOSPlatform else {
                throw MacVirtualMachineError.missingPlatformMetadata
            }
            let machine = macVM
                ?? MacVirtualMachine(
                    config: config,
                    metadata: macOSPlatform,
                    retinaEnabled: retinaEnabled
                )
            macVM = machine
            observeMacVM()
            try machine.start()
            return
        }

        let vm: VM
        if let existing = self.vm {
            vm = existing
        } else {
            vm = try app.createVM(config: config)
            self.vm = vm
            observeVM()
        }
        try vm.start()
    }

    public func stop() {
        if guestSystem == .macOS {
            macVM?.stop()
        } else {
            vm?.stop()
        }
    }

    public func pause() {
        if guestSystem == .macOS {
            macVM?.pause()
        } else {
            vm?.pause()
        }
    }

    public func resume() {
        if guestSystem == .macOS {
            macVM?.resume()
        } else {
            vm?.resume()
        }
    }

    public func shutdownGracefully() {
        vm?.shutdownGracefully()
    }

    public func rebootGuest() {
        vm?.rebootGuest()
    }

    public func trimGuestFilesystems() {
        vm?.trimGuestFilesystems()
    }

    public func synchronizeGuestTime() {
        vm?.synchronizeGuestTime()
    }

    public func sendFileToGuest(_ file: URL) throws {
        guard let vm else { throw BobrvmError.invalidState }
        try vm.sendFileToGuest(file)
    }

    public func snapshotQuiesced(to directory: URL) async throws {
        guard let vm else { throw BobrvmError.invalidState }
        try await vm.snapshotQuiesced(to: directory)
    }

    public func requireVM() throws -> VM {
        guard let vm else { throw BobrvmError.invalidState }
        return vm
    }

    public func destroy() {
        vm?.stop()
        vm?.destroy()
        vm = nil
        macVM?.destroy()
        macVM = nil
        vmStateCancellable = nil
        macVMStateCancellable = nil
    }

    private func observeVM() {
        vmStateCancellable = vm?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func observeMacVM() {
        macVMStateCancellable = macVM?.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

// MARK: - VM Storage

enum VMStorage {
    private static let configDir: URL = {
        DiskManager.appSupportDir.appendingPathComponent("configs", isDirectory: true)
    }()

    struct StoredVM: Codable {
        let id: UUID
        let name: String
        let memoryBytes: UInt64
        let vcpuCount: UInt8
        let firmwarePath: String?
        let varsPath: String?
        let kernelPath: String?
        let initrdPath: String?
        let cmdline: String?
        let diskPath: String?
        let diskReadOnly: Bool
        let isoPath: String?
        let vramMB: Int
        let displayWidth: UInt32?
        let displayHeight: UInt32?
        let retinaEnabled: Bool?
        let networkEnabled: Bool?
        let sharedFolderPath: String?
        let guestSystem: GuestSystem?
        let macOSPlatform: MacOSPlatformMetadata?

        var vmConfig: VMConfig {
            let storedFirmware: String? = firmwarePath.flatMap { path -> String? in
                guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
                    return nil
                }
                return path
            }
            let bundledFirmware = Bundle.main.path(forResource: "QEMU_EFI", ofType: "fd")

            // A configured kernel selects direct Linux boot; firmware and
            // direct boot are mutually exclusive in the core configuration.
            let effectiveFirmwarePath = guestSystem == .macOS
                ? nil
                : kernelPath == nil ? storedFirmware ?? bundledFirmware : nil

            let effectiveVarsPath: String? = guestSystem == .macOS
                ? nil
                : varsPath
                    ?? {
                    let safeName = DiskManager.safeFilename(name)
                    return DiskManager.appSupportDir
                        .appendingPathComponent("\(safeName)_vars.fd")
                        .path
                    }()

            return VMConfig(
                memoryBytes: memoryBytes,
                vcpuCount: vcpuCount,
                displayWidth: displayWidth ?? 1280,
                displayHeight: displayHeight ?? 800,
                gpuMemoryBytes: UInt64(vramMB) * 1024 * 1024,
                networkEnabled: networkEnabled ?? true,
                sharedFolderPath: sharedFolderPath,
                firmwarePath: effectiveFirmwarePath,
                varsPath: effectiveVarsPath,
                kernelPath: kernelPath,
                initrdPath: initrdPath,
                cmdline: cmdline,
                diskPath: diskPath,
                diskReadOnly: diskReadOnly,
                isoPath: isoPath,
                isoReadOnly: true
            )
        }

        @MainActor
        init(from instance: VMInstance) {
            self.id = instance.id
            self.name = instance.name
            self.memoryBytes = instance.config.memoryBytes
            self.vcpuCount = instance.config.vcpuCount
            self.firmwarePath = instance.config.firmwarePath
            self.varsPath = instance.config.varsPath
            self.kernelPath = instance.config.kernelPath
            self.initrdPath = instance.config.initrdPath
            self.cmdline = instance.config.cmdline
            self.diskPath = instance.config.diskPath
            self.diskReadOnly = instance.config.diskReadOnly
            self.isoPath = instance.config.isoPath ?? instance.isoPath
            self.vramMB = instance.vramMB
            self.displayWidth = instance.config.displayWidth
            self.displayHeight = instance.config.displayHeight
            self.retinaEnabled = instance.retinaEnabled
            self.networkEnabled = instance.config.networkEnabled
            self.sharedFolderPath = instance.config.sharedFolderPath
            self.guestSystem = instance.guestSystem
            self.macOSPlatform = instance.macOSPlatform
        }
    }

    @MainActor
    static func saveVM(_ instance: VMInstance) throws {
        let fm = FileManager.default

        if !fm.fileExists(atPath: configDir.path) {
            try fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        }

        let stored = StoredVM(from: instance)
        let data = try JSONEncoder().encode(stored)
        let filePath = configDir.appendingPathComponent("\(instance.id.uuidString).json")
        try data.write(to: filePath)
    }

    static func loadAllVMs() -> [StoredVM] {
        let fm = FileManager.default

        guard fm.fileExists(atPath: configDir.path) else {
            return []
        }

        var results: [StoredVM] = []

        guard
            let files = try? fm.contentsOfDirectory(at: configDir, includingPropertiesForKeys: nil)
        else {
            return []
        }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let stored = try? JSONDecoder().decode(StoredVM.self, from: data)
            else {
                continue
            }

            if let diskPath = stored.diskPath, !fm.fileExists(atPath: diskPath) {
                continue
            }

            results.append(stored)
        }

        return results.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func deleteVM(id: UUID) {
        let filePath = configDir.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: filePath)
    }
}
