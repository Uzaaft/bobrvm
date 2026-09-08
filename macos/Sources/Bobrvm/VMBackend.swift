import AppKit
import Combine
import Foundation
import SwiftUI

public enum VMBackend: String, Codable, CaseIterable, Identifiable {
    case hypervisor
    case virtualization

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .hypervisor: return "Bobrvm Hypervisor"
        case .virtualization: return "Apple Virtualization"
        }
    }

    var frameworkName: String {
        switch self {
        case .hypervisor: return "Hypervisor.framework"
        case .virtualization: return "Virtualization.framework"
        }
    }

    var gpuTitle: String {
        switch self {
        case .hypervisor: return "Best GPU support"
        case .virtualization: return "Compatibility display"
        }
    }

    var gpuDescription: String {
        switch self {
        case .hypervisor:
            return "Accelerated OpenGL and Vulkan through Bobrvm’s Metal renderer."
        case .virtualization:
            return "Apple-managed display without Bobrvm’s OpenGL or Vulkan acceleration."
        }
    }

    var selectionDescription: String {
        switch self {
        case .hypervisor:
            return "Custom virtio devices, guest tools, shared folders, and accelerated graphics."
        case .virtualization:
            return "Apple-managed EFI, devices, networking, display, and lifecycle."
        }
    }

    static func defaultValue(for guestSystem: GuestSystem) -> VMBackend {
        guestSystem == .macOS ? .virtualization : .hypervisor
    }

    func supports(_ guestSystem: GuestSystem) -> Bool {
        switch (self, guestSystem) {
        case (.hypervisor, .linux), (.hypervisor, .windows),
            (.virtualization, .linux), (.virtualization, .macOS):
            return true
        case (.hypervisor, .macOS), (.virtualization, .windows):
            return false
        }
    }

    func validate(guestSystem: GuestSystem, config: VMConfig) throws {
        guard supports(guestSystem) else {
            throw VMBackendError.unsupportedGuest(backend: self, guest: guestSystem)
        }
        if config.kernelPath != nil && (self != .hypervisor || guestSystem != .linux) {
            throw VMBackendError.directBootRequiresLinuxHypervisor
        }
        if config.gpu3DEnabled && self != .hypervisor {
            throw VMBackendError.gpu3DRequiresHypervisor
        }
        if config.soundEnabled && self != .hypervisor {
            throw VMBackendError.soundRequiresHypervisor
        }
        if !config.portForwards.isEmpty {
            guard self == .hypervisor else { throw VMBackendError.invalidForwarding }
            do { try config.validate() } catch { throw VMBackendError.invalidForwarding }
        }
        guard !config.touchIDEnabled || (self == .hypervisor && guestSystem == .linux) else {
            throw VMBackendError.touchIDRequiresLinuxHypervisor
        }
        guard self == .virtualization, guestSystem == .linux else { return }
        guard let diskPath = config.diskPath else {
            throw VMBackendError.diskRequired
        }
        let pathExtension = URL(fileURLWithPath: diskPath).pathExtension.lowercased()
        guard pathExtension == "raw" || pathExtension == "img" else {
            throw VMBackendError.rawDiskRequired
        }
    }
}

enum VMBackendError: LocalizedError {
    case unsupportedGuest(backend: VMBackend, guest: GuestSystem)
    case diskRequired
    case directBootRequiresLinuxHypervisor
    case gpu3DRequiresHypervisor
    case soundRequiresHypervisor
    case bootImageRequired
    case rawDiskRequired
    case touchIDRequiresLinuxHypervisor
    case invalidForwarding
    case invalidSSHUsername

    var errorDescription: String? {
        switch self {
        case .invalidSSHUsername:
            return "Enter a valid guest SSH username."
        case .invalidForwarding:
            return "Forwarding requires Bobrvm Hypervisor, networking, "
                + "and distinct host ports from 1024 to 65535. Guest ports must be nonzero."
        case .unsupportedGuest(let backend, let guest):
            return "\(backend.displayName) does not support \(guest.displayName) guests."
        case .directBootRequiresLinuxHypervisor:
            return "Direct kernel boot requires Linux with Bobrvm Hypervisor."
        case .gpu3DRequiresHypervisor:
            return "This 3D acceleration setting requires Bobrvm Hypervisor."
        case .soundRequiresHypervisor:
            return "This sound playback setting requires Bobrvm Hypervisor."
        case .bootImageRequired:
            return "Choose a kernel for direct boot or firmware for UEFI boot."
        case .diskRequired:
            return "Apple Virtualization requires a boot disk."
        case .rawDiskRequired:
            return "Apple Virtualization supports raw Linux disk images only."
        case .touchIDRequiresLinuxHypervisor:
            return "Mac Touch ID requires a Linux VM using Bobrvm Hypervisor."
        }
    }
}

extension GuestSystem {
    var supportedBackends: [VMBackend] {
        VMBackend.allCases.filter { $0.supports(self) }
    }
}

struct VMBackendSelectionView: View {
    @Binding var selection: VMBackend
    let guestSystem: GuestSystem
    var disabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Backend", selection: $selection) {
                ForEach(guestSystem.supportedBackends) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .disabled(disabled || guestSystem.supportedBackends.count == 1)

            VStack(alignment: .leading, spacing: 6) {
                Label(gpuTitle, systemImage: "gpu")
                    .font(.headline)
                    .foregroundStyle(selection == .hypervisor ? Color.green : Color.orange)
                Text(gpuDescription)
                    .font(.callout)
                    .foregroundStyle(.primary)
                Text(selection.selectionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                (selection == .hypervisor ? Color.green : Color.orange).opacity(0.09),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .accessibilityElement(children: .contain)
    }

    private var gpuTitle: String {
        if guestSystem == .macOS { return "Apple accelerated graphics" }
        if guestSystem == .windows { return "Bobrvm virtual GPU" }
        return selection.gpuTitle
    }

    private var gpuDescription: String {
        if guestSystem == .macOS {
            return "Apple provides the supported accelerated display for virtual Macs."
        }
        if guestSystem == .windows {
            return "Uses Bobrvm’s custom GPU device; acceleration depends on guest drivers."
        }
        return selection.gpuDescription
    }
}

@MainActor
final class LinuxVirtualMachine: ObservableObject {
    @Published private(set) var state: VMState = .stopped

    var displayView: NSView? { runtime?.displayView }

    private let id: UUID
    private let config: VMConfig
    private var runtime: VZLinuxVM?
    private var stateCancellable: AnyCancellable?

    init(id: UUID, config: VMConfig) {
        self.id = id
        self.config = config
    }

    func start() throws {
        guard state == .stopped else { return }
        let runtime = try runtime ?? makeRuntime()
        self.runtime = runtime
        stateCancellable = runtime.$state.sink { [weak self] state in
            self?.state = state
        }
        try runtime.start()
    }

    func stop() {
        runtime?.stop()
    }

    func pause() {
        runtime?.pause()
    }

    func resume() {
        runtime?.resume()
    }

    func destroy() {
        runtime?.destroy()
        runtime = nil
        stateCancellable = nil
        state = .stopped
    }

    private func makeRuntime() throws -> VZLinuxVM {
        guard let diskPath = config.diskPath else { throw VMBackendError.diskRequired }
        let directory = DiskManager.appSupportDir
            .appendingPathComponent("virtualization", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return try VZLinuxVM(
            config: VZLinuxVMConfig(
                memoryBytes: config.memoryBytes,
                vcpuCount: config.vcpuCount,
                displayWidth: config.displayWidth,
                displayHeight: config.displayHeight,
                networkEnabled: config.networkEnabled,
                diskReadOnly: config.diskReadOnly,
                diskPath: diskPath,
                installerPath: config.isoPath,
                variableStorePath: directory.appendingPathComponent("efi-variable-store").path,
                machineIdentifierPath: directory.appendingPathComponent("machine-id").path,
                macAddress: Self.macAddress(for: id)
            )
        )
    }

    static func macAddress(for id: UUID) -> String {
        var value = id.uuid
        let bytes = withUnsafeBytes(of: &value) { Array($0.prefix(5)) }
        return ([UInt8(0x02)] + bytes).map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}

struct LinuxVirtualMachineView: NSViewRepresentable {
    @ObservedObject var machine: LinuxVirtualMachine

    func makeNSView(context: Context) -> NSView {
        machine.displayView ?? NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

public struct SSHSettings: Codable, Equatable {
    public init() {}
    public var enabled = false
    public var automatic = true
    public var port: UInt16 = 0
    public var username = "user"

    public var validUsername: Bool {
        !username.isEmpty && username.utf8.count <= 64
            && username.utf8.allSatisfy {
                (65...90).contains($0) || (97...122).contains($0)
                    || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
            }
            && username.first != "-"
    }

    func applying(to config: VMConfig) throws -> VMConfig {
        guard enabled || config.sharedNetworking else { return config }
        guard validUsername else { throw VMBackendError.invalidSSHUsername }
        if config.sharedNetworking { return config }
        var result = config
        var forward = TCPForward()
        forward.hostPort = port
        forward.guestPort = 22
        forward.automatic = automatic
        result.portForwards.insert(forward, at: 0)
        return result
    }
}

/// Editable boot inputs; applying a mode clears inputs for the other boot path.
public struct BootConfiguration {
    enum Mode: String, CaseIterable, Identifiable {
        case uefi = "UEFI"
        case kernel = "Linux kernel"
        var id: Self { self }
    }

    var mode: Mode
    var firmware: String
    var variables: String
    var kernel: String
    var initrd: String
    var arguments: String

    init(config: VMConfig) {
        mode = config.kernelPath == nil ? .uefi : .kernel
        firmware =
            config.firmwarePath ?? Bundle.main.path(forResource: "QEMU_EFI", ofType: "fd") ?? ""
        variables = config.varsPath ?? ""
        kernel = config.kernelPath ?? ""
        initrd = config.initrdPath ?? ""
        arguments = config.cmdline ?? "console=hvc0 earlycon=pl011,0x09000000"
    }

    func applying(to config: VMConfig) throws -> VMConfig {
        guard !(mode == .kernel ? kernel : firmware).isEmpty else {
            throw VMBackendError.bootImageRequired
        }
        var result = config
        result.firmwarePath = mode == .uefi ? firmware : nil
        result.varsPath = mode == .uefi && !variables.isEmpty ? variables : nil
        result.kernelPath = mode == .kernel ? kernel : nil
        result.initrdPath = mode == .kernel && !initrd.isEmpty ? initrd : nil
        result.cmdline = mode == .kernel ? arguments : nil
        return result
    }
}

struct BootConfigurationFields: View {
    @Binding var boot: BootConfiguration
    var allowsModeChange = true

    var body: some View {
        if allowsModeChange {
            Picker("Boot method", selection: $boot.mode) {
                ForEach(BootConfiguration.Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
        }
        if boot.mode == .kernel {
            FilePickerField(label: "Kernel image", path: $boot.kernel, types: [])
            FilePickerField(label: "Initrd (optional)", path: $boot.initrd, types: [])
            TextField("Kernel arguments", text: $boot.arguments, axis: .vertical)
                .lineLimit(2...6)
            Text("Use an ARM64 Linux kernel. Set root= for disk-backed guests.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            FilePickerField(label: "UEFI firmware", path: $boot.firmware, types: [])
            FilePickerField(label: "UEFI variables", path: $boot.variables, types: [])
        }
    }
}

/// Installation is the only privileged app operation. The daemon authenticates
/// packet clients using the installing user's kernel-provided UID.
@MainActor
struct NetworkHelperControls: View {
    @State private var installed = FileManager.default.fileExists(
        atPath: "/Library/PrivilegedHelperTools/as.polymath.bobrvm.network")
    @Environment(\.scenePhase) private var scenePhase
    @State private var helperStatus: bobrvm_network_helper_status_e?
    @State private var statusGeneration = 0
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusMessage)
                .font(.caption)
                .foregroundStyle(needsUpdate ? Color.orange : Color.secondary)
            HStack {
                Button(installed ? "Update networking…" : "Install networking…") {
                    manage(remove: false)
                }
                if installed {
                    Button("Remove networking…") { manage(remove: true) }
                }
            }
            .disabled(working)
            Text(
                "Administrator approval is required. Updating or removing networking disconnects shared VMs."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await refreshStatus() }
        }
    }

    private var needsUpdate: Bool {
        helperStatus == BOBRVM_NETWORK_HELPER_MISMATCH
            || helperStatus == BOBRVM_NETWORK_HELPER_UNVERIFIED
    }

    private var statusMessage: String {
        switch helperStatus {
        case BOBRVM_NETWORK_HELPER_CURRENT:
            return "Shared networking is running the version included with this app."
        case BOBRVM_NETWORK_HELPER_MISMATCH:
            return "The running networking helper differs from this app. Update networking."
        case BOBRVM_NETWORK_HELPER_UNVERIFIED:
            return "The networking helper version could not be verified. Update networking."
        case BOBRVM_NETWORK_HELPER_UNAVAILABLE:
            return installed
                ? "Shared networking is installed but unavailable. Try updating networking."
                : "Install shared networking to connect this Mac directly to guest IP addresses."
        default:
            return "Checking the running networking helper…"
        }
    }

    private func refreshStatus() async {
        guard !working else { return }
        statusGeneration += 1
        let generation = statusGeneration
        let status = await Task.detached { bobrvm_network_helper_status() }.value
        guard !working, generation == statusGeneration, !Task.isCancelled else { return }
        helperStatus = status
        installed = FileManager.default.fileExists(
            atPath: "/Library/PrivilegedHelperTools/as.polymath.bobrvm.network")
    }

    private func manage(remove: Bool) {
        guard let script = Bundle.main.path(forResource: "manage-network-helper", ofType: "sh"),
            let helper = Bundle.main.path(forResource: "bobrvm-network-helper", ofType: nil)
        else {
            failure =
                "This build does not include the networking helper. Rebuild the app dependencies."
            return
        }
        let command =
            "/bin/sh \(Self.shellQuote(script)) "
            + (remove ? "remove" : "install \(Self.shellQuote(helper)) \(getuid())")
        let appleScript =
            "do shell script \""
            + command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\" with administrator privileges"
        statusGeneration += 1
        working = true
        failure = nil
        Task {
            let result = await Task.detached {
                let process = Process()
                let errors = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", appleScript]
                process.standardError = errors
                do {
                    try process.run()
                    let data = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    return process.terminationStatus == 0
                        ? nil
                        : String(data: data, encoding: .utf8) ?? "Networking installation failed."
                } catch { return error.localizedDescription }
            }.value
            working = false
            failure = result
            await refreshStatus()
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
