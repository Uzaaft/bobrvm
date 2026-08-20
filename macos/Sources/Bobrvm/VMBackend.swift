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
    case rawDiskRequired

    var errorDescription: String? {
        switch self {
        case .unsupportedGuest(let backend, let guest):
            return "\(backend.displayName) does not support \(guest.displayName) guests."
        case .diskRequired:
            return "Apple Virtualization requires a boot disk."
        case .rawDiskRequired:
            return "Apple Virtualization supports raw Linux disk images only."
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
