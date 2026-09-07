import AppKit
import Combine
import Foundation

@MainActor
public final class VMManager: ObservableObject {
    private static let logger = BobrvmLogging.logger(for: VMManager.self)

    @Published public var vms: [VMInstance] = []
    @Published public var showingCreateVM = false
    @Published public var vmPendingEdit: VMInstance?

    weak var app: App?

    private let frameReadySubject = PassthroughSubject<Void, Never>()
    public var frameReadyPublisher: AnyPublisher<Void, Never> {
        frameReadySubject.eraseToAnyPublisher()
    }

    public init() {}

    public func loadExistingVMs() {
        guard let app else {
            if BobrvmLogging.warningEnabled {
                Self.logger.warning("Cannot load VMs: app not initialized")
            }
            return
        }

        let storedConfigs = VMStorage.loadAllVMs()
        if BobrvmLogging.infoEnabled {
            Self.logger.info("Found \(storedConfigs.count) stored VM(s)")
        }

        for stored in storedConfigs {
            let instance = VMInstance(
                id: stored.id,
                name: stored.name,
                config: stored.vmConfig,
                ssh: stored.ssh ?? SSHSettings(),
                app: app,
                isoPath: stored.isoPath,
                retinaEnabled: stored.retinaEnabled ?? true,
                guestSystem: stored.effectiveGuestSystem,
                backend: stored.effectiveBackend,
                creationDate: stored.effectiveCreationDate,
                macOSPlatform: stored.macOSPlatform
            )
            vms.append(instance)
            if BobrvmLogging.infoEnabled {
                Self.logger.info("Loaded VM: \(stored.name)")
            }
        }
    }

    public func createVM(
        name: String,
        config: VMConfig,
        ssh: SSHSettings = SSHSettings(),
        isoPath: String? = nil,
        retinaEnabled: Bool = true,
        guestSystem: GuestSystem = .linux,
        backend: VMBackend? = nil
    ) throws {
        guard guestSystem != .macOS, let app else {
            throw BobrvmError.invalidArgument
        }

        let selectedBackend = backend ?? VMBackend.defaultValue(for: guestSystem)
        let runtimeConfig = try ssh.applying(to: config)
        try selectedBackend.validate(guestSystem: guestSystem, config: runtimeConfig)
        let vm = selectedBackend == .hypervisor ? try app.createVM(config: runtimeConfig) : nil
        do {
            let instance = VMInstance(
                name: name,
                config: config,
                ssh: ssh,
                app: app,
                vm: vm,
                isoPath: isoPath,
                retinaEnabled: retinaEnabled,
                guestSystem: guestSystem,
                backend: selectedBackend
            )
            try VMStorage.saveVM(instance)
            vms.append(instance)
            if BobrvmLogging.infoEnabled {
                Self.logger.info("Saved VM configuration: \(name)")
            }
        } catch {
            vm?.destroy()
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
                backend: .virtualization,
                macOSPlatform: result.metadata
            )
            try VMStorage.saveVM(instance)
            vms.append(instance)
            if BobrvmLogging.infoEnabled {
                Self.logger.info("Installed macOS virtual machine: \(name)")
            }
        } catch {
            try? FileManager.default.removeItem(at: bundleURL)
            throw error
        }
    }

    public func deleteVM(_ instance: VMInstance) async {
        vms.removeAll { $0.id == instance.id }
        VMStorage.deleteVM(id: instance.id)
        await instance.destroyForDeletion()
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
        sharedNetworking: Bool,
        touchIDEnabled: Bool,
        ssh: SSHSettings,
        portForwards: [TCPForward],
        sharedFolderPath: String?,
        diskSizeGB: Int?,
        backend: VMBackend,
        boot: BootConfiguration? = nil,
        gpu3DEnabled: Bool? = nil,
        diskReadOnly: Bool? = nil,
        soundEnabled: Bool? = nil,
        sharedFolderReadOnly: Bool? = nil
    ) throws {
        guard instance.state == .stopped else {
            throw BobrvmError.invalidState
        }

        if let diskSizeGB, let diskPath = instance.config.diskPath {
            try DiskManager.growRawDisk(path: diskPath, sizeGB: diskSizeGB)
        }

        let effectiveSharedFolder = backend == .hypervisor ? sharedFolderPath : nil
        var newConfig = VMConfig(
            memoryBytes: UInt64(memoryGB) * 1024 * 1024 * 1024,
            vcpuCount: UInt8(vcpuCount),
            displayWidth: UInt32(displayWidth),
            displayHeight: UInt32(displayHeight),
            gpuMemoryBytes: UInt64(vramMB) * 1024 * 1024,
            gpu3DEnabled: backend == .hypervisor
                && (gpu3DEnabled ?? instance.config.gpu3DEnabled),
            soundEnabled: backend == .hypervisor && (soundEnabled ?? instance.config.soundEnabled),
            sharedFolderReadOnly: sharedFolderReadOnly ?? instance.config.sharedFolderReadOnly,
            networkEnabled: networkEnabled,
            sharedNetworking: sharedNetworking,
            networkMAC: instance.config.networkMAC,
            touchIDEnabled: touchIDEnabled && backend == .hypervisor
                && instance.guestSystem == .linux,
            portForwards: portForwards,
            sharedFolderPath: effectiveSharedFolder,
            firmwarePath: instance.config.firmwarePath,
            varsPath: instance.config.varsPath,
            kernelPath: instance.config.kernelPath,
            initrdPath: instance.config.initrdPath,
            cmdline: instance.config.cmdline,
            diskPath: instance.config.diskPath,
            diskReadOnly: diskReadOnly ?? instance.config.diskReadOnly,
            isoPath: isoPath,
            isoReadOnly: true
        )

        if let boot { newConfig = try boot.applying(to: newConfig) }

        try replaceVM(
            instance,
            name: name,
            config: newConfig,
            ssh: ssh,
            isoPath: isoPath,
            retinaEnabled: retinaEnabled,
            backend: backend
        )

        if BobrvmLogging.infoEnabled {
            Self.logger.info("Updated VM configuration: \(name)")
        }
    }

    public func updateISO(_ instance: VMInstance, path: String?) throws {
        guard instance.guestSystem != .macOS else {
            throw BobrvmError.invalidArgument
        }

        var newConfig = instance.config
        newConfig.isoPath = path
        newConfig.isoReadOnly = true

        try replaceVM(
            instance,
            name: instance.name,
            config: newConfig,
            ssh: instance.ssh,
            isoPath: path,
            retinaEnabled: instance.retinaEnabled,
            backend: instance.backend
        )

        if BobrvmLogging.infoEnabled {
            Self.logger.info("Updated ISO media for VM: \(instance.name)")
        }
    }

    public func updateLiveSettings(
        _ instance: VMInstance,
        name: String,
        displayWidth: UInt32,
        displayHeight: UInt32,
        retinaEnabled: Bool
    ) throws {
        guard instance.state != .stopped else {
            throw BobrvmError.invalidState
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
            displayWidth > 0,
            displayHeight > 0
        else {
            throw BobrvmError.invalidArgument
        }

        if instance.backend == .virtualization,
            displayWidth != instance.config.displayWidth
                || displayHeight != instance.config.displayHeight
                || retinaEnabled != instance.retinaEnabled
        {
            throw BobrvmError.invalidState
        }

        let previousName = instance.name
        let previousConfig = instance.config
        let previousRetinaEnabled = instance.retinaEnabled
        instance.applyLiveSettings(
            name: name,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            retinaEnabled: retinaEnabled
        )

        do {
            try VMStorage.saveVM(instance)
        } catch {
            instance.restoreLiveSettings(
                name: previousName,
                config: previousConfig,
                retinaEnabled: previousRetinaEnabled
            )
            throw error
        }

        objectWillChange.send()
        if BobrvmLogging.infoEnabled {
            Self.logger.info("Updated live settings for VM: \(instance.name)")
        }
    }

    private func replaceVM(
        _ instance: VMInstance,
        name: String,
        config: VMConfig,
        ssh: SSHSettings,
        isoPath: String?,
        retinaEnabled: Bool,
        backend: VMBackend
    ) throws {
        guard instance.state == .stopped else {
            throw BobrvmError.invalidState
        }

        guard let index = vms.firstIndex(where: { $0.id == instance.id }) else {
            throw BobrvmError.invalidArgument
        }

        guard let app else { throw BobrvmError.invalidArgument }
        let runtimeConfig = try ssh.applying(to: config)
        try backend.validate(guestSystem: instance.guestSystem, config: runtimeConfig)
        let newVM =
            backend == .hypervisor
            ? try app.createVM(config: runtimeConfig)
            : nil
        let updatedInstance = VMInstance(
            id: instance.id,
            name: name,
            config: config,
            ssh: ssh,
            app: app,
            vm: newVM,
            isoPath: isoPath,
            retinaEnabled: retinaEnabled,
            guestSystem: instance.guestSystem,
            backend: backend,
            creationDate: instance.creationDate,
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
protocol VMRuntime: AnyObject {
    var state: VMState { get }
    var stateChanges: AnyPublisher<Void, Never> { get }

    func start() throws
    func stop()
    func stopAndWait() async
    func pause()
    func resume()
    func destroy()
}

extension VMRuntime {
    func stopAndWait() async {
        while state != .stopped {
            stop()
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

extension VM: VMRuntime {
    var stateChanges: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }
}

extension MacVirtualMachine: VMRuntime {
    var stateChanges: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }
}

extension LinuxVirtualMachine: VMRuntime {
    var stateChanges: AnyPublisher<Void, Never> {
        objectWillChange.eraseToAnyPublisher()
    }
}

@MainActor
public final class VMInstance: ObservableObject, Identifiable, Hashable {
    public nonisolated static func == (lhs: VMInstance, rhs: VMInstance) -> Bool {
        lhs.id == rhs.id
    }

    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    public let id: UUID
    @Published public private(set) var name: String
    @Published public private(set) var ssh: SSHSettings
    @Published public private(set) var config: VMConfig
    private let app: App
    private var runtime: (any VMRuntime)?
    public let isoPath: String?
    @Published public private(set) var retinaEnabled: Bool
    public let guestSystem: GuestSystem
    public let backend: VMBackend
    public let creationDate: Date
    let macOSPlatform: MacOSPlatformMetadata?

    @Published public var surface: Surface?

    private var runtimeStateCancellable: AnyCancellable?
    private var sshPortCancellable: AnyCancellable?
    private var guestIPCancellable: AnyCancellable?
    @Published private(set) var sshError: String?

    var sshAlias: String { "bobrvm-\(id.uuidString.lowercased())" }

    var guestIPv4: String? { runtimeVM?.guestIPv4 }

    var sshPort: UInt16 {
        if config.sharedNetworking { return state == .running && guestIPv4 != nil ? 22 : 0 }
        guard ssh.enabled, state == .running,
            runtimeVM?.isStopping == false
        else { return 0 }
        return runtimeVM?.forwardedPorts.first ?? 0
    }

    var sshCommand: String {
        let host = config.sharedNetworking ? (guestIPv4 ?? "<guest-ip>") : "127.0.0.1"
        return "ssh -o HostKeyAlias=\(sshAlias) -p \(sshPort) \(ssh.username)@\(host)"
    }

    func openSSH() {
        guard sshPort != 0, ssh.validUsername else { return }
        let directory = DiskManager.appSupportDir.appendingPathComponent("ssh", isDirectory: true)
        let script = directory.appendingPathComponent("\(id.uuidString).command")
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try "#!/bin/sh\nexec /usr/bin/\(sshCommand)\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: script.path
            )
            NSWorkspace.shared.open(script)
            sshError = nil
        } catch { sshError = error.localizedDescription }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        config: VMConfig,
        ssh: SSHSettings = SSHSettings(),
        app: App,
        vm: VM? = nil,
        isoPath: String? = nil,
        retinaEnabled: Bool = true,
        guestSystem: GuestSystem = .linux,
        backend: VMBackend? = nil,
        creationDate: Date = Date(),
        macOSPlatform: MacOSPlatformMetadata? = nil
    ) {
        self.id = id
        self.name = name
        self.config = config
        self.ssh = ssh
        self.app = app
        self.runtime = vm
        self.isoPath = isoPath
        self.retinaEnabled = retinaEnabled
        self.guestSystem = guestSystem
        self.backend = backend ?? VMBackend.defaultValue(for: guestSystem)
        self.creationDate = creationDate
        self.macOSPlatform = macOSPlatform

        precondition(vm == nil || self.backend == .hypervisor)
        observeRuntime()
    }

    convenience init(
        name: String,
        config: VMConfig,
        app: App,
        runtime: any VMRuntime,
        guestSystem: GuestSystem,
        backend: VMBackend
    ) {
        self.init(
            name: name,
            config: config,
            app: app,
            guestSystem: guestSystem,
            backend: backend
        )
        self.runtime = runtime
        observeRuntime()
    }

    public var state: VMState {
        runtime?.state ?? .stopped
    }

    public var vramMB: Int {
        Int(config.gpuMemoryBytes / (1024 * 1024))
    }

    public var guestToolsStatus: GuestToolsStatus {
        runtimeVM?.guestToolsStatus ?? .disconnected
    }

    public var isGuestManagementReady: Bool {
        runtimeVM?.isGuestManagementReady ?? false
    }

    var runtimeVM: VM? {
        runtime as? VM
    }

    var runtimeMacVM: MacVirtualMachine? {
        runtime as? MacVirtualMachine
    }

    var runtimeLinuxVZVM: LinuxVirtualMachine? {
        runtime as? LinuxVirtualMachine
    }

    public func start() throws {
        try backend.validate(guestSystem: guestSystem, config: ssh.applying(to: config))
        let runtime: any VMRuntime
        if let existing = self.runtime {
            runtime = existing
        } else {
            runtime = try makeRuntime()
            self.runtime = runtime
            observeRuntime()
        }
        try runtime.start()
    }

    public func restoreSnapshot(from directory: URL) throws {
        guard backend == .hypervisor, state == .stopped else {
            throw BobrvmError.invalidState
        }
        try backend.validate(guestSystem: guestSystem, config: ssh.applying(to: config))
        if runtime == nil {
            runtime = try makeRuntime()
            observeRuntime()
        }
        guard let vm = runtimeVM else { throw BobrvmError.invalidState }
        try vm.restoreSnapshot(from: directory)
    }

    public func stop() {
        runtime?.stop()
    }

    public func pause() {
        runtime?.pause()
    }

    public func resume() {
        runtime?.resume()
    }

    public func shutdownGracefully() {
        runtimeVM?.shutdownGracefully()
    }

    public func rebootGuest() {
        runtimeVM?.rebootGuest()
    }

    public func trimGuestFilesystems() {
        runtimeVM?.trimGuestFilesystems()
    }

    public func synchronizeGuestTime() {
        runtimeVM?.synchronizeGuestTime()
    }

    public func sendFileToGuest(_ file: URL) throws {
        guard let vm = runtimeVM else { throw BobrvmError.invalidState }
        try vm.sendFileToGuest(file)
    }

    public func snapshot(to directory: URL, quiesced: Bool) async throws {
        guard let vm = runtimeVM else { throw BobrvmError.invalidState }
        try await vm.snapshot(to: directory, quiesced: quiesced)
    }

    public func snapshotQuiesced(to directory: URL) async throws {
        guard let vm = runtimeVM else { throw BobrvmError.invalidState }
        try await vm.snapshotQuiesced(to: directory)
    }

    public func requireVM() throws -> VM {
        guard let vm = runtimeVM else { throw BobrvmError.invalidState }
        return vm
    }

    func applyLiveSettings(
        name: String,
        displayWidth: UInt32,
        displayHeight: UInt32,
        retinaEnabled: Bool
    ) {
        self.name = name
        config.displayWidth = displayWidth
        config.displayHeight = displayHeight
        self.retinaEnabled = retinaEnabled
    }

    func restoreLiveSettings(name: String, config: VMConfig, retinaEnabled: Bool) {
        self.name = name
        self.config = config
        self.retinaEnabled = retinaEnabled
    }

    public func destroy() {
        runtimeVM?.stop()
        runtime?.destroy()
        runtime = nil
        runtimeStateCancellable = nil
    }

    func destroyForDeletion() async {
        await runtime?.stopAndWait()
        destroy()
    }

    private func makeRuntime() throws -> any VMRuntime {
        if backend == .hypervisor {
            return try app.createVM(config: ssh.applying(to: config))
        }
        if guestSystem == .macOS {
            guard let macOSPlatform else {
                throw MacVirtualMachineError.missingPlatformMetadata
            }
            return MacVirtualMachine(
                config: config,
                metadata: macOSPlatform,
                retinaEnabled: retinaEnabled
            )
        }
        return LinuxVirtualMachine(id: id, config: config)
    }

    private func observeRuntime() {
        runtimeStateCancellable = runtime?.stateChanges.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        guestIPCancellable = runtimeVM?.$guestIPv4
            .removeDuplicates()
            .sink { [weak self] _ in self?.objectWillChange.send() }
        sshPortCancellable = runtimeVM?.$forwardedPorts
            .map { $0.first ?? 0 }
            .removeDuplicates()
            .sink { [weak self] port in
                guard let self, self.ssh.enabled, self.ssh.automatic,
                    port != 0, self.ssh.port != port
                else { return }
                self.ssh.port = port
                do { try VMStorage.saveVM(self) } catch {
                    self.sshError = error.localizedDescription
                }
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
        let gpu3DEnabled: Bool?
        let soundEnabled: Bool?
        let sharedFolderReadOnly: Bool?
        let displayWidth: UInt32?
        let displayHeight: UInt32?
        let retinaEnabled: Bool?
        let networkEnabled: Bool?
        let sharedNetworking: Bool?
        let networkMAC: [UInt8]?
        let touchIDEnabled: Bool?
        let ssh: SSHSettings?
        let portForwards: [TCPForward]?
        let sharedFolderPath: String?
        let guestSystem: GuestSystem?
        let backend: VMBackend?
        var createdAt: Date?
        let macOSPlatform: MacOSPlatformMetadata?

        var effectiveGuestSystem: GuestSystem {
            guestSystem ?? .linux
        }

        var effectiveBackend: VMBackend {
            backend ?? VMBackend.defaultValue(for: effectiveGuestSystem)
        }

        var effectiveCreationDate: Date {
            createdAt ?? .distantPast
        }

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
            let effectiveFirmwarePath =
                guestSystem == .macOS
                ? nil
                : kernelPath == nil ? storedFirmware ?? bundledFirmware : nil

            let effectiveVarsPath: String? =
                guestSystem == .macOS
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
                gpu3DEnabled: gpu3DEnabled ?? false,
                soundEnabled: soundEnabled ?? false,
                sharedFolderReadOnly: sharedFolderReadOnly ?? false,
                networkEnabled: networkEnabled ?? true,
                sharedNetworking: sharedNetworking ?? false,
                networkMAC: networkMAC,
                touchIDEnabled: touchIDEnabled ?? false,
                portForwards: portForwards ?? [],
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
            self.gpu3DEnabled = instance.config.gpu3DEnabled
            self.soundEnabled = instance.config.soundEnabled
            self.sharedFolderReadOnly = instance.config.sharedFolderReadOnly
            self.displayWidth = instance.config.displayWidth
            self.displayHeight = instance.config.displayHeight
            self.retinaEnabled = instance.retinaEnabled
            self.networkEnabled = instance.config.networkEnabled
            self.sharedNetworking = instance.config.sharedNetworking
            self.networkMAC = instance.config.networkMAC
            self.touchIDEnabled = instance.config.touchIDEnabled
            self.ssh = instance.ssh
            self.portForwards = instance.config.portForwards
            self.sharedFolderPath = instance.config.sharedFolderPath
            self.guestSystem = instance.guestSystem
            self.backend = instance.backend
            self.createdAt = instance.creationDate
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
            let files = try? fm.contentsOfDirectory(
                at: configDir,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
            )
        else {
            return []
        }

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                var stored = try? JSONDecoder().decode(StoredVM.self, from: data)
            else {
                continue
            }

            if stored.createdAt == nil {
                let values = try? file.resourceValues(
                    forKeys: [.creationDateKey, .contentModificationDateKey]
                )
                stored.createdAt = values?.creationDate ?? values?.contentModificationDate
            }

            if let diskPath = stored.diskPath, !fm.fileExists(atPath: diskPath) {
                continue
            }

            results.append(stored)
        }

        return results
    }

    static func deleteVM(id: UUID) {
        let filePath = configDir.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: filePath)
    }
}
