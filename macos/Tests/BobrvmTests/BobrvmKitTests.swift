import XCTest

@testable import Bobrvm

final class BobrvmKitTests: XCTestCase {
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
        let management = UInt64(BOBRVM_GUEST_TOOLS_MANAGEMENT.rawValue)
        let status = GuestToolsStatus(
            connection: .ready,
            capabilities: clipboard | management
        )

        XCTAssertEqual(status.connection, .ready)
        XCTAssertTrue(status.supportsClipboard)
        XCTAssertFalse(status.supportsFileTransfer)
        XCTAssertTrue(status.supportsManagement)
    }

    func testVMConfigPreservesScalarAndStringFields() {
        let config = VMConfig(
            memoryBytes: 3_221_225_472,
            vcpuCount: 7,
            displayWidth: 1_601,
            displayHeight: 901,
            gpuMemoryBytes: 257_949_696,
            networkEnabled: true,
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

        config.withCConfig { pointer in
            let c = pointer.pointee
            XCTAssertEqual(c.memory_bytes, config.memoryBytes)
            XCTAssertEqual(c.vcpu_count, config.vcpuCount)
            XCTAssertEqual(c.display_width, config.displayWidth)
            XCTAssertEqual(c.display_height, config.displayHeight)
            XCTAssertEqual(c.gpu_memory_bytes, config.gpuMemoryBytes)
            XCTAssertEqual(c.enable_net, config.networkEnabled)
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

    func testVMConfigKeepsAbsentStringsNull() {
        let config = VMConfig()

        config.withCConfig { pointer in
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
}
