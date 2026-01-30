//
//  VMManager.swift
//  Bobrvm
//
//  Manages VM instances and coordinates with UI.
//

import Foundation
import Combine
import OSLog

@MainActor
public final class VMManager: ObservableObject {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.bobrvm.app",
        category: "VMManager"
    )
    
    @Published public var vms: [VMInstance] = []
    @Published public var selectedVM: VMInstance?
    @Published public var showingCreateVM = false
    @Published public var consoleOutput: String = ""
    
    private static let maxConsoleLength = 100_000
    
    weak var app: App?
    
    private var frameReadySubject = PassthroughSubject<Void, Never>()
    public var frameReadyPublisher: AnyPublisher<Void, Never> {
        frameReadySubject.eraseToAnyPublisher()
    }
    
    public init() {}

    private static func isIsoPath(_ path: String) -> Bool {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "iso"
    }

    private static func normalizeConfig(_ config: VMConfig) -> VMConfig {
        guard let diskPath = config.diskPath, isIsoPath(diskPath) else {
            return config
        }

        if config.diskReadOnly {
            return config
        }

        logger.info("Forcing disk read-only for ISO at \(diskPath, privacy: .private(mask: .hash))")

        var normalized = config
        normalized.diskReadOnly = true
        return normalized
    }
    
    public func loadExistingVMs() {
        guard let app = app else {
            Self.logger.warning("Cannot load VMs: app not initialized")
            return
        }
        
        let storedConfigs = VMStorage.loadAllVMs()
        Self.logger.info("Found \(storedConfigs.count) stored VM(s)")

        for stored in storedConfigs {
            do {
                let normalized = Self.normalizeConfig(stored.vmConfig)
                let vm = try app.createVM(config: normalized)
                let instance = VMInstance(
                    id: stored.id,
                    name: stored.name,
                    config: normalized,
                    vm: vm,
                    isoPath: stored.isoPath,
                    vramMB: stored.vramMB
                )
                vms.append(instance)
                Self.logger.info("Loaded VM: \(stored.name)")
            } catch {
                Self.logger.error("Failed to load VM '\(stored.name)': \(error.localizedDescription)")
            }
        }
        
        if selectedVM == nil {
            selectedVM = vms.first
        }
    }
    
    public func createVM(name: String, config: VMConfig, isoPath: String? = nil, vramMB: Int = 256) throws {
        guard let app = app else {
            throw BobrvmError.invalidArgument
        }

        let normalized = Self.normalizeConfig(config)
        let vm = try app.createVM(config: normalized)
        do {
            let instance = VMInstance(name: name, config: normalized, vm: vm, isoPath: isoPath, vramMB: vramMB)
            try VMStorage.saveVM(instance)
            vms.append(instance)
            selectedVM = instance
            Self.logger.info("Saved VM configuration: \(name)")
        } catch {
            vm.destroy()
            throw error
        }
    }
    
    public func deleteVM(_ instance: VMInstance) {
        instance.vm.stop()
        vms.removeAll { $0.id == instance.id }
        if selectedVM?.id == instance.id {
            selectedVM = vms.first
        }
        
        VMStorage.deleteVM(id: instance.id)
    }
    
    public func updateVM(
        _ instance: VMInstance,
        name: String,
        memoryGB: Int,
        vcpuCount: Int,
        vramMB: Int,
        isoPath: String?
    ) async throws {
        guard instance.state == .stopped else {
            throw BobrvmError.invalidState
        }
        
        // Create updated config
        let newConfig = VMConfig(
            memoryBytes: UInt64(memoryGB) * 1024 * 1024 * 1024,
            vcpuCount: UInt8(vcpuCount),
            kernelPath: instance.config.kernelPath,
            initrdPath: instance.config.initrdPath,
            cmdline: instance.config.cmdline,
            diskPath: instance.config.diskPath,
            diskReadOnly: instance.config.diskReadOnly
        )

        let normalized = Self.normalizeConfig(newConfig)
        
        // Find and update the instance in our list
        guard let index = vms.firstIndex(where: { $0.id == instance.id }) else {
            throw BobrvmError.invalidArgument
        }
        
        // Create new VM with updated config
        guard let app = app else {
            throw BobrvmError.invalidArgument
        }
        
        let newVM = try app.createVM(config: normalized)
        let updatedInstance = VMInstance(
            id: instance.id,
            name: name,
            config: normalized,
            vm: newVM,
            isoPath: isoPath,
            vramMB: vramMB
        )
        
        // Replace in list
        vms[index] = updatedInstance
        if selectedVM?.id == instance.id {
            selectedVM = updatedInstance
        }
        
        // Save to disk
        try VMStorage.saveVM(updatedInstance)
        Self.logger.info("Updated VM configuration: \(name)")
    }
    
    public func stopAllVMs() {
        for instance in vms {
            instance.vm.stop()
        }
    }
    
    func notifyFrameReady() {
        frameReadySubject.send()
    }
    
    public func appendConsoleOutput(_ text: String) {
        consoleOutput.append(text)
        
        // Trim if too long
        if consoleOutput.count > Self.maxConsoleLength {
            let dropCount = consoleOutput.count - Self.maxConsoleLength
            consoleOutput = String(consoleOutput.dropFirst(dropCount))
        }
    }
    
    public func clearConsoleOutput() {
        consoleOutput = ""
    }
}

// MARK: - VM Instance

@MainActor
public final class VMInstance: ObservableObject, Identifiable, Hashable {
    public static func == (lhs: VMInstance, rhs: VMInstance) -> Bool {
        lhs.id == rhs.id
    }
    
    public nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    public let id: UUID
    public let name: String
    public let config: VMConfig
    public let vm: VM
    public let isoPath: String?
    public let vramMB: Int
    
    @Published public var surface: Surface?
    
    private var vmStateCancellable: AnyCancellable?
    
    public init(id: UUID = UUID(), name: String, config: VMConfig, vm: VM, isoPath: String? = nil, vramMB: Int = 256) {
        self.id = id
        self.name = name
        self.config = config
        self.vm = vm
        self.isoPath = isoPath
        self.vramMB = vramMB
        
        // Forward VM state changes to trigger VMInstance updates
        vmStateCancellable = vm.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
    
    public var state: VMState {
        vm.state
    }
    
    public func start() throws {
        try vm.start()
    }
    
    public func stop() {
        vm.stop()
    }
    
    public func pause() {
        vm.pause()
    }
    
    public func resume() {
        vm.resume()
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
        
        var vmConfig: VMConfig {
            // Use stored firmware path, or fall back to bundled firmware
            // Treat empty string as nil
            let storedFirmware = (firmwarePath?.isEmpty == false) ? firmwarePath : nil
            let bundledFirmware = Bundle.main.path(forResource: "QEMU_EFI", ofType: "fd")
            
            // Debug: print to stderr so it shows in zig build run output
            FileHandle.standardError.write("[VMStorage] storedFirmware=\(storedFirmware ?? "nil"), bundledFirmware=\(bundledFirmware ?? "nil"), Bundle.main=\(Bundle.main.bundlePath)\n".data(using: .utf8)!)
            
            let effectiveFirmwarePath = storedFirmware ?? bundledFirmware
            
            // Generate vars path if not stored
            let effectiveVarsPath: String? = varsPath ?? {
                let safeName = name
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: " ", with: "_")
                return DiskManager.appSupportDir
                    .appendingPathComponent("\(safeName)_vars.fd")
                    .path
            }()
            
            return VMConfig(
                memoryBytes: memoryBytes,
                vcpuCount: vcpuCount,
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
        }
    }
    
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
        
        guard let files = try? fm.contentsOfDirectory(at: configDir, includingPropertiesForKeys: nil) else {
            return []
        }
        
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let stored = try? JSONDecoder().decode(StoredVM.self, from: data) else {
                continue
            }
            
            if let diskPath = stored.diskPath, !fm.fileExists(atPath: diskPath) {
                continue
            }
            
            results.append(stored)
        }
        
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    
    static func deleteVM(id: UUID) {
        let filePath = configDir.appendingPathComponent("\(id.uuidString).json")
        try? FileManager.default.removeItem(at: filePath)
    }
}
