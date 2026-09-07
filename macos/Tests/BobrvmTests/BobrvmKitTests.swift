import Combine
import XCTest

@testable import Bobrvm

final class BobrvmKitTests: XCTestCase {
    @MainActor
    func testHardwareSettingsReachCoreAndSurviveStorage() throws {
        let app = try App()
        let config = VMConfig(
            gpu3DEnabled: true, soundEnabled: true, sharedFolderReadOnly: true,
            sharedFolderPath: "/shared", diskPath: "/disk.raw", diskReadOnly: true
        )
        let instance = VMInstance(name: "Hardware", config: config, app: app)
        let stored = try JSONDecoder().decode(
            VMStorage.StoredVM.self,
            from: JSONEncoder().encode(VMStorage.StoredVM(from: instance))
        )
        XCTAssertTrue(stored.vmConfig.gpu3DEnabled)
        XCTAssertTrue(stored.vmConfig.diskReadOnly)
        XCTAssertTrue(stored.vmConfig.soundEnabled)
        XCTAssertTrue(stored.vmConfig.sharedFolderReadOnly)
        try stored.vmConfig.withCConfig { pointer in
            XCTAssertTrue(pointer.pointee.enable_gpu3d)
            XCTAssertTrue(pointer.pointee.disk_read_only)
            XCTAssertTrue(pointer.pointee.enable_snd)
            XCTAssertTrue(pointer.pointee.share_read_only)
        }
    }

    func testCLIInventoryPreservesRecordsAndQuotesLaunchCommands() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(try CLIInventoryEntry.read(directory: directory).isEmpty)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("dev's vm.json")
        let data = Data(#"{"memory_mb":1024,"vcpu_count":4,"disk_path":"/missing-bobrvm-disk"}"#.utf8)
        try data.write(to: file)
        try Data("{".utf8).write(to: directory.appendingPathComponent("broken.json"))
        let entries = try CLIInventoryEntry.read(directory: directory)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, "cli:dev's vm")
        XCTAssertEqual(entry.memoryMB, 1024)
        XCTAssertEqual(entry.cpuCount, 4)
        XCTAssertFalse(entry.diskExists)
        XCTAssertEqual(entry.startCommand, "bobrvm start 'dev'\\''s vm'")
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(try CLIInventoryEntry.read(directory: directory).first?.id, entry.id)
    }

    @MainActor
    func testSnapshotRestoreFailureLeavesVMStopped() async throws {
        let app = try App()
        let vm = try app.createVM(config: VMConfig())
        defer { vm.destroy() }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try vm.restoreSnapshot(from: missing))
        XCTAssertEqual(vm.state, .stopped)
        do {
            try await vm.snapshot(to: missing)
            XCTFail("A stopped VM cannot be captured")
        } catch {
            XCTAssertEqual(vm.state, .stopped)
        }
    }

    func testBootConfigurationSelectsOneBootPath() throws {
        var config = VMConfig(firmwarePath: "/firmware", varsPath: "/variables")
        var boot = BootConfiguration(config: config)
        boot.mode = .kernel
        boot.kernel = "/kernel"
        boot.initrd = "/initrd"
        boot.arguments = "console=hvc0 root=/dev/vda"
        config = try boot.applying(to: config)
        XCTAssertNil(config.firmwarePath)
        XCTAssertNil(config.varsPath)
        XCTAssertEqual(config.kernelPath, "/kernel")
        XCTAssertEqual(config.initrdPath, "/initrd")
        XCTAssertEqual(config.cmdline, boot.arguments)
        try config.withCConfig { pointer in
            XCTAssertEqual(String(cString: pointer.pointee.kernel_path), "/kernel")
            XCTAssertNil(pointer.pointee.firmware_path)
        }
        XCTAssertThrowsError(try VMBackend.virtualization.validate(
            guestSystem: .linux, config: config
        ))
        boot.mode = .uefi
        config = try boot.applying(to: config)
        XCTAssertEqual(config.firmwarePath, "/firmware")
        XCTAssertEqual(config.varsPath, "/variables")
        XCTAssertNil(config.kernelPath)
        XCTAssertNil(config.initrdPath)
        XCTAssertNil(config.cmdline)
        boot.mode = .kernel
        boot.kernel = ""
        XCTAssertThrowsError(try boot.applying(to: config))
    }

    func testForwardingPreservesCSlotsAndCodableSettings() throws {
        var ssh = SSHSettings()
        ssh.enabled = true
        ssh.username = "alice"
        ssh.port = 2222
        var forward = TCPForward()
        forward.hostPort = 8443
        forward.guestPort = 443
        forward.allowLAN = true
        let config = try ssh.applying(to: VMConfig(networkEnabled: true, portForwards: [forward]))
        try config.withCConfig { pointer in
            XCTAssertEqual(pointer.pointee.port_forward_count, 2)
            let slots = pointer.pointee.port_forwards
            XCTAssertEqual(slots.0.host_port, 2222)
            XCTAssertEqual(slots.0.guest_port, 22)
            XCTAssertTrue(slots.0.automatic)
            XCTAssertFalse(slots.0.allow_lan)
            XCTAssertEqual(slots.1.host_port, 8443)
            XCTAssertEqual(slots.1.guest_port, 443)
            XCTAssertTrue(slots.1.allow_lan)
            XCTAssertEqual(slots.7.guest_port, 0)
        }
        XCTAssertEqual(
            try JSONDecoder().decode(SSHSettings.self, from: JSONEncoder().encode(ssh)), ssh
        )
        XCTAssertEqual(
            try JSONDecoder().decode(TCPForward.self, from: JSONEncoder().encode(forward)), forward
        )
    }

    func testSSHRejectsConfigInjectionAndInvalidForwarding() throws {
        var ssh = SSHSettings()
        ssh.enabled = true
        for username in ["", "-oProxyCommand=bad", "alice\nProxyCommand bad", "a b", "a'b"] {
            ssh.username = username
            XCTAssertFalse(ssh.validUsername)
            XCTAssertThrowsError(try ssh.applying(to: VMConfig()))
        }
        ssh.username = "alice"
        var config = VMConfig(networkEnabled: true)
        XCTAssertNoThrow(try VMBackend.hypervisor.validate(
            guestSystem: .linux, config: ssh.applying(to: config)
        ))
        XCTAssertThrowsError(try VMBackend.virtualization.validate(
            guestSystem: .linux, config: ssh.applying(to: config)
        ))
        config.networkEnabled = false
        XCTAssertThrowsError(try ssh.applying(to: config).validate())
        config.networkEnabled = true
        ssh.automatic = false
        XCTAssertThrowsError(try ssh.applying(to: config).validate())
        ssh.port = 8080
        config.portForwards = [TCPForward()]
        XCTAssertThrowsError(try ssh.applying(to: config).validate())
    }

    func testGenericForwardingUsesAllSlotsAndRejectsOverflow() throws {
        var config = VMConfig(networkEnabled: true)
        config.portForwards = (0..<8).map { index in
            var forward = TCPForward()
            forward.hostPort = UInt16(8000 + index)
            return forward
        }
        XCTAssertNoThrow(try config.validate())
        try config.withCConfig { pointer in
            XCTAssertEqual(pointer.pointee.port_forward_count, 8)
            XCTAssertEqual(pointer.pointee.port_forwards.0.guest_port, 8080)
            XCTAssertEqual(pointer.pointee.port_forwards.7.host_port, 8007)
        }
        config.portForwards.append(TCPForward())
        XCTAssertThrowsError(try config.validate())
    }

    func testStoredForwardingDefaultsToManualForLegacyRules() throws {
        let json = """
            {"id":"01234567-89AB-CDEF-0123-456789ABCDEF",
             "hostPort":8080,"guestPort":80,"allowLAN":false}
            """
        let forward = try JSONDecoder().decode(TCPForward.self, from: Data(json.utf8))
        XCTAssertFalse(forward.automatic)
        XCTAssertEqual(forward.guestPort, 80)
    }

    @MainActor
    func testStoredVMKeepsSSHSeparateFromRuntimeForwarding() throws {
        let app = try App()
        var ssh = SSHSettings()
        ssh.enabled = true
        ssh.username = "alice"
        ssh.port = 2222
        let config = VMConfig(networkEnabled: true, portForwards: [TCPForward()])
        let instance = VMInstance(name: "SSH", config: config, ssh: ssh, app: app)
        let stored = try JSONDecoder().decode(
            VMStorage.StoredVM.self,
            from: JSONEncoder().encode(VMStorage.StoredVM(from: instance))
        )
        XCTAssertEqual(stored.ssh, ssh)
        XCTAssertEqual(stored.vmConfig.portForwards, config.portForwards)
        let runtimeConfig = try XCTUnwrap(stored.ssh).applying(to: stored.vmConfig)
        XCTAssertEqual(runtimeConfig.portForwards.count, 2)
        XCTAssertEqual(runtimeConfig.portForwards[0].guestPort, 22)
        XCTAssertEqual(runtimeConfig.portForwards[0].hostPort, 2222)
        XCTAssertEqual(runtimeConfig.portForwards[1], config.portForwards[0])
    }

    func testErrorCodesMapToStableFailures() {
        let expected: [(Int32, String)] = [
            (1, "Invalid argument"),
            (2, "Out of memory"),
            (3, "Hypervisor initialization failed"),
            (4, "Failed to create VM"),
            (5, "Failed to create vCPU"),
            (6, "Failed to map memory"),
            (7, "Failed to create surface"),
            (8, "Metal error"),
            (9, "I/O error"),
            (10, "The file already exists"),
            (11, "Virtual disks cannot be safely shrunk"),
            (12, "The disk format is unsupported"),
            (13, "Operation not allowed in current state"),
            (99, "Unknown error (99)"),
        ]

        for (code, description) in expected {
            XCTAssertEqual(BobrvmError(code: code).errorDescription, description)
        }
    }

    func testSwiftLoggingUsesCompiledCLogLevel() {
        let compiled = bobrvm_log_level().rawValue

        XCTAssertEqual(
            BobrvmLogging.debugEnabled,
            BOBRVM_LOG_LEVEL_DEBUG.rawValue <= compiled
        )
        XCTAssertEqual(
            BobrvmLogging.infoEnabled,
            BOBRVM_LOG_LEVEL_INFO.rawValue <= compiled
        )
        XCTAssertEqual(
            BobrvmLogging.warningEnabled,
            BOBRVM_LOG_LEVEL_WARNING.rawValue <= compiled
        )
    }

    func testKeyEventsPreserveCFields() {
        let event = KeyEvent(keycode: UInt32.max, modifiers: 0xA5A5, pressed: true)
        let cEvent = event.toCStruct()

        XCTAssertEqual(cEvent.keycode, UInt32.max)
        XCTAssertEqual(cEvent.modifiers, 0xA5A5)
        XCTAssertTrue(cEvent.pressed)
    }

    func testGuestToolCapabilitiesAreIndependent() {
        let clipboard = UInt64(BOBRVM_GUEST_TOOLS_CLIPBOARD.rawValue)
        let authentication = UInt64(BOBRVM_GUEST_TOOLS_HOST_AUTHENTICATION.rawValue)
        let fingerprint = UInt64(BOBRVM_GUEST_TOOLS_AUTH_FINGERPRINT.rawValue)
        let management = UInt64(BOBRVM_GUEST_TOOLS_MANAGEMENT.rawValue)
        let status = GuestToolsStatus(
            connection: .ready,
            capabilities: clipboard | authentication | fingerprint | management
        )

        XCTAssertEqual(status.connection, .ready)
        XCTAssertTrue(status.supportsClipboard)
        XCTAssertFalse(status.supportsFileTransfer)
        XCTAssertTrue(status.supportsHostAuthentication)
        XCTAssertTrue(status.supportsFingerprintAuthentication)
        XCTAssertTrue(status.supportsManagement)
    }

    func testVMConfigPreservesScalarAndStringFields() throws {
        let config = VMConfig(
            memoryBytes: 3_221_225_472,
            vcpuCount: 7,
            displayWidth: 1_601,
            displayHeight: 901,
            gpuMemoryBytes: 257_949_696,
            networkEnabled: true,
            touchIDEnabled: true,
            sharedFolderPath: "/tmp/shared",
            firmwarePath: "/tmp/firmware.fd",
            varsPath: "/tmp/vars.fd",
            kernelPath: "/tmp/kernel",
            initrdPath: "/tmp/initrd",
            cmdline: "console=hvc0",
            diskPath: "/tmp/disk.raw",
            diskReadOnly: true,
            isoPath: "/tmp/install.iso",
            isoReadOnly: false
        )

        try config.withCConfig { pointer in
            let c = pointer.pointee
            XCTAssertEqual(c.memory_bytes, config.memoryBytes)
            XCTAssertEqual(c.vcpu_count, config.vcpuCount)
            XCTAssertEqual(c.display_width, config.displayWidth)
            XCTAssertEqual(c.display_height, config.displayHeight)
            XCTAssertEqual(c.gpu_memory_bytes, config.gpuMemoryBytes)
            XCTAssertEqual(c.enable_net, config.networkEnabled)
            XCTAssertEqual(c.enable_touch_id, config.touchIDEnabled)
            XCTAssertEqual(c.disk_read_only, config.diskReadOnly)
            XCTAssertEqual(c.disk2_read_only, config.isoReadOnly)
            XCTAssertEqual(String(cString: c.shared_dir), config.sharedFolderPath)
            XCTAssertEqual(String(cString: c.firmware_path), config.firmwarePath)
            XCTAssertEqual(String(cString: c.vars_path), config.varsPath)
            XCTAssertEqual(String(cString: c.kernel_path), config.kernelPath)
            XCTAssertEqual(String(cString: c.initrd_path), config.initrdPath)
            XCTAssertEqual(String(cString: c.cmdline), config.cmdline)
            XCTAssertEqual(String(cString: c.disk_path), config.diskPath)
            XCTAssertEqual(String(cString: c.disk2_path), config.isoPath)
        }
    }

    func testVMConfigKeepsAbsentStringsNull() throws {
        let config = VMConfig()

        try config.withCConfig { pointer in
            let c = pointer.pointee
            XCTAssertNil(c.shared_dir)
            XCTAssertNil(c.firmware_path)
            XCTAssertNil(c.vars_path)
            XCTAssertNil(c.kernel_path)
            XCTAssertNil(c.initrd_path)
            XCTAssertNil(c.cmdline)
            XCTAssertNil(c.disk_path)
            XCTAssertNil(c.disk2_path)
        }
    }

    func testVZLinuxConfigPreservesBackendFields() {
        let config = VZLinuxVMConfig(
            memoryBytes: 4 * 1024 * 1024 * 1024,
            vcpuCount: 4,
            displayWidth: 1920,
            displayHeight: 1080,
            networkEnabled: true,
            diskReadOnly: false,
            diskPath: "/tmp/linux.raw",
            installerPath: "/tmp/linux.iso",
            variableStorePath: "/tmp/efi-store",
            machineIdentifierPath: "/tmp/machine-id",
            macAddress: "02:01:02:03:04:05"
        )

        config.withCConfig { pointer in
            let c = pointer.pointee
            XCTAssertEqual(c.memory_bytes, config.memoryBytes)
            XCTAssertEqual(c.vcpu_count, config.vcpuCount)
            XCTAssertEqual(c.display_width, config.displayWidth)
            XCTAssertEqual(c.display_height, config.displayHeight)
            XCTAssertTrue(c.enable_net)
            XCTAssertFalse(c.disk_read_only)
            XCTAssertEqual(String(cString: c.disk_path), config.diskPath)
            XCTAssertEqual(String(cString: c.installer_path), config.installerPath)
            XCTAssertEqual(String(cString: c.variable_store_path), config.variableStorePath)
            XCTAssertEqual(String(cString: c.machine_id_path), config.machineIdentifierPath)
            XCTAssertEqual(String(cString: c.mac_address), config.macAddress)
        }
    }

    func testBackendCompatibilityMatrixAndDefaults() {
        XCTAssertTrue(VMBackend.hypervisor.supports(.linux))
        XCTAssertTrue(VMBackend.virtualization.supports(.linux))
        XCTAssertFalse(VMBackend.hypervisor.supports(.macOS))
        XCTAssertTrue(VMBackend.virtualization.supports(.macOS))
        XCTAssertTrue(VMBackend.hypervisor.supports(.windows))
        XCTAssertFalse(VMBackend.virtualization.supports(.windows))
        XCTAssertEqual(VMBackend.defaultValue(for: .linux), .hypervisor)
        XCTAssertEqual(VMBackend.defaultValue(for: .windows), .hypervisor)
        XCTAssertEqual(VMBackend.defaultValue(for: .macOS), .virtualization)
    }

    func testVirtualizationBackendRejectsNonRawLinuxDisk() {
        let config = VMConfig(diskPath: "/tmp/linux.qcow2")
        XCTAssertThrowsError(
            try VMBackend.virtualization.validate(guestSystem: .linux, config: config)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Apple Virtualization supports raw Linux disk images only.")
        }
    }

    func testTouchIDRequiresLinuxHypervisorBackend() {
        var config = VMConfig(diskPath: "/tmp/linux.raw")
        config.touchIDEnabled = true
        XCTAssertNoThrow(try VMBackend.hypervisor.validate(guestSystem: .linux, config: config))
        XCTAssertThrowsError(
            try VMBackend.virtualization.validate(guestSystem: .linux, config: config)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Mac Touch ID requires a Linux VM using Bobrvm Hypervisor."
            )
        }
    }

    func testLegacyStoredVMMigratesToGuestDefaultBackend() throws {
        let data = Data(
            """
            {
              "id": "83BD9E0C-D6A6-414A-81F2-53A70C013DFC",
              "name": "Legacy Linux",
              "memoryBytes": 4294967296,
              "vcpuCount": 4,
              "diskReadOnly": false,
              "vramMB": 512,
              "guestSystem": "linux"
            }
            """.utf8
        )
        let stored = try JSONDecoder().decode(VMStorage.StoredVM.self, from: data)

        XCTAssertNil(stored.backend)
        XCTAssertEqual(stored.effectiveBackend, .hypervisor)
        XCTAssertFalse(stored.vmConfig.gpu3DEnabled)
        XCTAssertFalse(stored.vmConfig.soundEnabled)
        XCTAssertFalse(stored.vmConfig.sharedFolderReadOnly)
    }

    @MainActor
    func testVMSortOrderSupportsNameAndCreationDate() throws {
        let app = try App()
        let older = VMInstance(
            name: "Alpha",
            config: VMConfig(),
            app: app,
            creationDate: Date(timeIntervalSince1970: 100)
        )
        let newer = VMInstance(
            name: "Zulu",
            config: VMConfig(),
            app: app,
            creationDate: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(VMSortOrder.name.sorted([newer, older]).map(\.name), ["Alpha", "Zulu"])
        XCTAssertEqual(VMSortOrder.date.sorted([older, newer]).map(\.name), ["Zulu", "Alpha"])
    }

    @MainActor
    func testVirtualizationMACAddressIsStableAndLocallyAdministered() {
        let id = UUID(uuidString: "83BD9E0C-D6A6-414A-81F2-53A70C013DFC")!
        let first = LinuxVirtualMachine.macAddress(for: id)

        XCTAssertEqual(first, LinuxVirtualMachine.macAddress(for: id))
        XCTAssertTrue(first.hasPrefix("02:"))
        XCTAssertEqual(first.split(separator: ":").count, 6)
    }

    @MainActor
    func testLiveSettingsRejectStoppedVM() throws {
        let app = try App()
        let manager = VMManager()
        let instance = VMInstance(name: "Stopped", config: VMConfig(), app: app)

        do {
            try manager.updateLiveSettings(
                instance,
                name: "Renamed",
                displayWidth: 1920,
                displayHeight: 1080,
                retinaEnabled: true
            )
            XCTFail("Expected stopped VM to reject live settings")
        } catch BobrvmError.invalidState {
            // Expected lifecycle rejection.
        } catch {
            XCTFail("Expected invalidState, got \(error)")
        }
    }

    @MainActor
    func testVMInstanceLiveSettingsTransitionCanBeReverted() throws {
        let app = try App()
        let originalConfig = VMConfig(displayWidth: 1280, displayHeight: 800)
        let instance = VMInstance(
            name: "Original",
            config: originalConfig,
            app: app,
            retinaEnabled: false
        )

        instance.applyLiveSettings(
            name: "Renamed",
            displayWidth: 1920,
            displayHeight: 1080,
            retinaEnabled: true
        )

        XCTAssertEqual(instance.name, "Renamed")
        XCTAssertEqual(instance.config.displayWidth, 1920)
        XCTAssertEqual(instance.config.displayHeight, 1080)
        XCTAssertTrue(instance.retinaEnabled)

        instance.restoreLiveSettings(
            name: "Original",
            config: originalConfig,
            retinaEnabled: false
        )

        XCTAssertEqual(instance.name, "Original")
        XCTAssertEqual(instance.config.displayWidth, 1280)
        XCTAssertEqual(instance.config.displayHeight, 800)
        XCTAssertFalse(instance.retinaEnabled)
    }

    @MainActor
    func testVMInstanceRoutesLifecycleThroughOneRuntime() throws {
        let app = try App()
        let runtime = RecordingVMRuntime()
        let instance = VMInstance(
            name: "Runtime",
            config: VMConfig(),
            app: app,
            runtime: runtime,
            guestSystem: .linux,
            backend: .hypervisor
        )

        try instance.start()
        instance.pause()
        instance.resume()
        instance.stop()
        instance.destroy()

        XCTAssertEqual(runtime.calls, ["start", "pause", "resume", "stop", "destroy"])
        XCTAssertEqual(instance.state, .stopped)
    }
}

@MainActor
private final class RecordingVMRuntime: VMRuntime {
    private let changes = PassthroughSubject<Void, Never>()
    private(set) var calls: [String] = []
    private(set) var state: VMState = .stopped

    var stateChanges: AnyPublisher<Void, Never> {
        changes.eraseToAnyPublisher()
    }

    func start() throws {
        calls.append("start")
        state = .running
        changes.send()
    }

    func stop() {
        calls.append("stop")
        state = .stopped
        changes.send()
    }

    func pause() {
        calls.append("pause")
        state = .paused
        changes.send()
    }

    func resume() {
        calls.append("resume")
        state = .running
        changes.send()
    }

    func destroy() {
        calls.append("destroy")
        state = .stopped
        changes.send()
    }
}
