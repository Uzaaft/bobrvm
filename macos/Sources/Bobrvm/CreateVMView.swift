import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CreateVMView: View {
    @EnvironmentObject private var vmManager: VMManager
    @Environment(\.dismiss) private var dismiss

    @State private var step = CreationStep.operatingSystem
    @State private var operatingSystem: CreationOperatingSystem?
    @State private var source = VMSource.installFromISO
    @State private var name = "Linux"
    @State private var isoPath = ""
    @State private var ipswPath = ""
    @State private var macOSRestoreSource = MacOSRestoreSource.latest
    @State private var existingDiskPath = ""
    @State private var memoryGB = 4.0
    @State private var vcpuCount = 2.0
    @State private var vramMB = 512.0
    @State private var resolution = DisplayResolution.defaultValue
    @State private var retinaEnabled = true
    @State private var diskSizeGB = 64.0
    @State private var isCreating = false
    @State private var installationProgress = 0.0
    @State private var errorMessage: String?

    private let systemInfo = SystemInfo()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                CreationStepSidebar(step: step)
                    .frame(width: 180)
                Divider()
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 540)
        .disabled(isCreating)
        .onChange(of: operatingSystem) { selected in
            guard let selected else { return }
            switch selected {
            case .linux:
                source = .installFromISO
                if name == "macOS" { name = "Linux" }
            case .macOS:
                source = .installMacOS
                if name == "Linux" { name = "macOS" }
                memoryGB = max(memoryGB, 8)
                vcpuCount = max(vcpuCount, 4)
                diskSizeGB = max(diskSizeGB, 80)
            case .windows:
                break
            }
        }
        .alert(
            "Couldn’t Create Virtual Machine",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "An unknown error occurred.")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .operatingSystem:
            OperatingSystemStepView(selection: $operatingSystem)
        case .installation:
            InstallationStepView(
                operatingSystem: operatingSystem ?? .linux,
                source: $source,
                isoPath: $isoPath,
                ipswPath: $ipswPath,
                macOSRestoreSource: $macOSRestoreSource,
                existingDiskPath: $existingDiskPath
            )
        case .hardware:
            HardwareStepView(
                memoryGB: $memoryGB,
                vcpuCount: $vcpuCount,
                vramMB: $vramMB,
                resolution: $resolution,
                retinaEnabled: $retinaEnabled,
                guestSystem: source.guestSystem,
                systemInfo: systemInfo
            )
        case .storage:
            StorageStepView(
                source: source,
                existingDiskPath: existingDiskPath,
                diskSizeGB: $diskSizeGB
            )
        case .summary:
            SummaryStepView(
                name: $name,
                source: source,
                isoPath: isoPath,
                ipswPath: ipswPath,
                macOSRestoreSource: macOSRestoreSource,
                existingDiskPath: existingDiskPath,
                memoryGB: Int(memoryGB),
                vcpuCount: Int(vcpuCount),
                vramMB: Int(vramMB),
                resolution: resolution,
                retinaEnabled: retinaEnabled,
                diskSizeGB: Int(diskSizeGB)
            )
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if step != .operatingSystem {
                Button("Back") { step = step.previous }
            }
            if isCreating {
                if source == .installMacOS {
                    Text(installationProgress < 0.70 ? "Downloading macOS" : "Installing macOS")
                        .foregroundStyle(.secondary)
                    ProgressView(value: installationProgress)
                        .frame(width: 160)
                    Text("\(Int(installationProgress * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            Button(step == .summary ? "Create" : "Continue") {
                if step == .summary {
                    createVM()
                } else {
                    step = step.next
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
        .padding(16)
    }

    private var canContinue: Bool {
        if isCreating { return false }
        switch step {
        case .operatingSystem:
            return operatingSystem?.isAvailable == true
        case .installation:
            switch source {
            case .installFromISO: return !isoPath.isEmpty
            case .existingDisk: return !existingDiskPath.isEmpty
            case .installMacOS:
                return macOSRestoreSource == .latest || !ipswPath.isEmpty
            }
        case .hardware, .storage:
            return true
        case .summary:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func createVM() {
        isCreating = true
        installationProgress = 0

        if source == .installMacOS {
            Task { @MainActor in
                do {
                    try await vmManager.createMacOSVM(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        ipswPath: macOSRestoreSource == .local ? ipswPath : nil,
                        memoryBytes: UInt64(memoryGB * 1024 * 1024 * 1024),
                        vcpuCount: UInt8(vcpuCount),
                        displayWidth: resolution.width,
                        displayHeight: resolution.height,
                        diskSizeGB: Int(diskSizeGB),
                        retinaEnabled: retinaEnabled,
                        progress: { installationProgress = $0 }
                    )
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                    isCreating = false
                }
            }
            return
        }

        var createdDiskPath: String?
        do {
            let diskPath: String
            if source == .installFromISO {
                diskPath = try DiskManager.createSparseDisk(
                    name: name,
                    sizeGB: Int(diskSizeGB)
                )
                createdDiskPath = diskPath
            } else {
                diskPath = existingDiskPath
            }

            let config = makeConfig(diskPath: diskPath)
            try vmManager.createVM(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                config: config,
                isoPath: source == .installFromISO ? isoPath : nil,
                retinaEnabled: retinaEnabled
            )
            dismiss()
        } catch {
            if let createdDiskPath {
                try? FileManager.default.removeItem(atPath: createdDiskPath)
            }
            errorMessage = error.localizedDescription
            isCreating = false
        }
    }

    private func makeConfig(diskPath: String) -> VMConfig {
        let safeName = DiskManager.safeFilename(name)
        let varsPath = DiskManager.appSupportDir
            .appendingPathComponent("\(safeName)_vars.fd")
            .path
        return VMConfig(
            memoryBytes: UInt64(memoryGB * 1024 * 1024 * 1024),
            vcpuCount: UInt8(vcpuCount),
            displayWidth: resolution.width,
            displayHeight: resolution.height,
            gpuMemoryBytes: UInt64(vramMB) * 1024 * 1024,
            networkEnabled: true,
            firmwarePath: Bundle.main.path(forResource: "QEMU_EFI", ofType: "fd"),
            varsPath: varsPath,
            diskPath: diskPath,
            diskReadOnly: false,
            isoPath: source == .installFromISO ? isoPath : nil,
            isoReadOnly: true
        )
    }
}

private enum CreationStep: Int, CaseIterable {
    case operatingSystem
    case installation
    case hardware
    case storage
    case summary

    var title: String {
        switch self {
        case .operatingSystem: return "Operating System"
        case .installation: return "Installation"
        case .hardware: return "Hardware"
        case .storage: return "Storage"
        case .summary: return "Finish"
        }
    }

    var icon: String {
        switch self {
        case .operatingSystem: return "desktopcomputer"
        case .installation: return "opticaldisc"
        case .hardware: return "cpu"
        case .storage: return "internaldrive"
        case .summary: return "checkmark.circle"
        }
    }

    var previous: CreationStep {
        CreationStep(rawValue: max(0, rawValue - 1)) ?? self
    }

    var next: CreationStep {
        CreationStep(rawValue: min(Self.allCases.count - 1, rawValue + 1)) ?? self
    }
}

private enum CreationOperatingSystem: String, CaseIterable, Identifiable {
    case macOS
    case linux
    case windows

    var id: Self { self }
    var isAvailable: Bool { self != .windows }

    var title: String {
        switch self {
        case .macOS: return "macOS"
        case .linux: return "Linux"
        case .windows: return "Windows"
        }
    }

    var detail: String {
        switch self {
        case .macOS: return "Create a native Apple silicon virtual Mac."
        case .linux: return "Install Linux or attach an existing virtual disk."
        case .windows: return "Windows virtualization is coming soon."
        }
    }

    var icon: String {
        switch self {
        case .macOS: return "apple.logo"
        case .linux: return "terminal"
        case .windows: return "rectangle.split.2x2"
        }
    }
}

private enum VMSource: String, CaseIterable, Identifiable {
    case installFromISO
    case existingDisk
    case installMacOS

    var id: Self { self }

    var guestSystem: GuestSystem {
        self == .installMacOS ? .macOS : .linux
    }
}

private enum MacOSRestoreSource: String, CaseIterable, Identifiable {
    case latest
    case local

    var id: Self { self }
}

struct DisplayResolution: Hashable, Identifiable {
    let width: UInt32
    let height: UInt32

    var id: String { "\(width)x\(height)" }
    var label: String { "\(width) × \(height)" }

    static let defaultValue = DisplayResolution(width: 1920, height: 1080)
    static let presets = [
        DisplayResolution(width: 1280, height: 800),
        DisplayResolution(width: 1440, height: 900),
        defaultValue,
        DisplayResolution(width: 2560, height: 1440),
        DisplayResolution(width: 2560, height: 1600),
        DisplayResolution(width: 3840, height: 2160),
    ]
}

private struct CreationStepSidebar: View {
    let step: CreationStep

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New Virtual Machine")
                .font(.headline)
                .padding(.bottom, 16)
            ForEach(CreationStep.allCases, id: \.rawValue) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .frame(width: 20)
                    Text(item.title)
                    Spacer()
                }
                .foregroundStyle(item.rawValue <= step.rawValue ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(item == step ? Color.accentColor.opacity(0.14) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            Spacer()
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct OperatingSystemStepView: View {
    @Binding var selection: CreationOperatingSystem?

    var body: some View {
        WizardPage(
            title: "Choose an operating system",
            subtitle: "Select the operating system for this virtual machine."
        ) {
            ForEach(CreationOperatingSystem.allCases) { operatingSystem in
                SourceCard(
                    title: operatingSystem.title,
                    detail: operatingSystem.detail,
                    icon: operatingSystem.icon,
                    selected: selection == operatingSystem,
                    badge: operatingSystem.isAvailable ? nil : "Coming soon",
                    enabled: operatingSystem.isAvailable
                ) {
                    selection = operatingSystem
                }
            }
        }
    }
}

private struct InstallationStepView: View {
    let operatingSystem: CreationOperatingSystem
    @Binding var source: VMSource
    @Binding var isoPath: String
    @Binding var ipswPath: String
    @Binding var macOSRestoreSource: MacOSRestoreSource
    @Binding var existingDiskPath: String

    var body: some View {
        WizardPage(
            title: "Choose an installation method",
            subtitle: operatingSystem == .macOS
                ? "Choose where Bobrvm should obtain the macOS restore image."
                : "Install Linux from an ISO or use an existing virtual disk."
        ) {
            if operatingSystem == .macOS {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("macOS Version", selection: $macOSRestoreSource) {
                        Text("Download latest supported macOS").tag(MacOSRestoreSource.latest)
                        Text("Use a local IPSW").tag(MacOSRestoreSource.local)
                    }
                    if macOSRestoreSource == .local {
                        FilePickerField(
                            label: "Restore Image",
                            path: $ipswPath,
                            types: [.ipsw]
                        )
                    }
                    Text(
                        macOSRestoreSource == .latest
                            ? "Apple’s restore image is roughly 15–25 GB and is cached after download."
                            : "Select an Apple restore image compatible with this Mac."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text("Installation can take an hour and the VM must remain open.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                SourceCard(
                    title: "Install from ISO image",
                    detail: "Create a new disk and boot from installation media.",
                    icon: "opticaldisc",
                    selected: source == .installFromISO
                ) { source = .installFromISO }
                if source == .installFromISO {
                    FilePickerField(label: "ISO Image", path: $isoPath, types: [.iso])
                        .padding(.leading, 44)
                }
                SourceCard(
                    title: "Use an existing virtual disk",
                    detail: "Boot a raw or QCOW2 disk that already contains Linux.",
                    icon: "externaldrive",
                    selected: source == .existingDisk
                ) { source = .existingDisk }
                if source == .existingDisk {
                    FilePickerField(
                        label: "Virtual Disk",
                        path: $existingDiskPath,
                        types: [.rawDisk, .qcow2, .diskImage]
                    )
                    .padding(.leading, 44)
                }
            }
        }
    }
}

private struct HardwareStepView: View {
    @Binding var memoryGB: Double
    @Binding var vcpuCount: Double
    @Binding var vramMB: Double
    @Binding var resolution: DisplayResolution
    @Binding var retinaEnabled: Bool
    let guestSystem: GuestSystem
    let systemInfo: SystemInfo

    var body: some View {
        WizardPage(
            title: "Configure virtual hardware",
            subtitle: "These settings can be changed later while the virtual machine is stopped."
        ) {
            SettingSlider(
                title: "Processor cores",
                valueText: "\(Int(vcpuCount))",
                value: $vcpuCount,
                range: 1...Double(systemInfo.cpuCount),
                step: 1,
                footer: "\(systemInfo.cpuCount) cores available"
            )
            SettingSlider(
                title: "Memory",
                valueText: "\(Int(memoryGB)) GB",
                value: $memoryGB,
                range: 1...Double(systemInfo.maxMemoryGB),
                step: 1,
                footer: "\(systemInfo.totalMemoryGB) GB installed on this Mac"
            )
            if guestSystem == .linux {
                SettingSlider(
                    title: "Shared graphics memory",
                    valueText: "\(Int(vramMB)) MB",
                    value: $vramMB,
                    range: 128...2048,
                    step: 128,
                    footer: "Reserved from host memory for the virtual GPU"
                )
            } else {
                Label("Apple accelerated graphics", systemImage: "gpu")
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("Maximum guest resolution")
                Spacer()
                Picker("Maximum guest resolution", selection: $resolution) {
                    ForEach(DisplayResolution.presets) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Text("The guest display follows the VM window up to this framebuffer size.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Use full resolution for Retina display", isOn: $retinaEnabled)
            Text(
                retinaEnabled
                    ? "Renders one guest pixel per Retina pixel for sharper output."
                    : "Renders at standard scale to reduce GPU and memory use."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

private struct StorageStepView: View {
    let source: VMSource
    let existingDiskPath: String
    @Binding var diskSizeGB: Double

    var body: some View {
        WizardPage(
            title: "Configure storage",
            subtitle: source != .existingDisk
                ? "The disk is sparse and consumes space only as data is written."
                : "Bobrvm will attach the selected disk without changing its contents."
        ) {
            if source != .existingDisk {
                SettingSlider(
                    title: "Maximum disk size",
                    valueText: "\(Int(diskSizeGB)) GB",
                    value: $diskSizeGB,
                    range: 8...512,
                    step: 1,
                    footer: "You can grow this disk later, but it cannot be shrunk safely."
                )
                Label(
                    "A sparse raw disk will be stored in Bobrvm’s Application Support folder.",
                    systemImage: "internaldrive"
                )
                .foregroundStyle(.secondary)
            } else {
                SummaryRow(
                    label: "Virtual disk",
                    value: URL(fileURLWithPath: existingDiskPath).lastPathComponent
                )
                Text(existingDiskPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct SummaryStepView: View {
    @Binding var name: String
    let source: VMSource
    let isoPath: String
    let ipswPath: String
    let macOSRestoreSource: MacOSRestoreSource
    let existingDiskPath: String
    let memoryGB: Int
    let vcpuCount: Int
    let vramMB: Int
    let resolution: DisplayResolution
    let retinaEnabled: Bool
    let diskSizeGB: Int

    var body: some View {
        WizardPage(
            title: "Ready to create",
            subtitle: "Review the configuration, then create the virtual machine."
        ) {
            LabeledContent("Name") {
                TextField("Virtual machine name", text: $name)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 240)
            }
            Divider()
            SummaryRow(label: "Processors & Memory", value: "\(vcpuCount) cores, \(memoryGB) GB")
            SummaryRow(
                label: "Graphics",
                value: source == .installMacOS
                    ? "Apple accelerated, \(resolution.label)"
                    : "\(vramMB) MB, \(resolution.label)"
            )
            SummaryRow(label: "Retina", value: retinaEnabled ? "Full resolution" : "Standard scale")
            SummaryRow(
                label: "Disk",
                value: source != .existingDisk
                    ? "\(diskSizeGB) GB sparse disk"
                    : URL(fileURLWithPath: existingDiskPath).lastPathComponent
            )
            SummaryRow(
                label: source == .installMacOS ? "Restore Image" : "CD/DVD",
                value: installationMediaName
            )
        }
    }

    private var installationMediaName: String {
        switch source {
        case .installFromISO:
            return URL(fileURLWithPath: isoPath).lastPathComponent
        case .installMacOS:
            return macOSRestoreSource == .latest
                ? "Latest supported macOS"
                : URL(fileURLWithPath: ipswPath).lastPathComponent
        case .existingDisk:
            return "Empty"
        }
    }
}

private struct WizardPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.title2.bold())
                Text(subtitle).foregroundStyle(.secondary)
                content
                Spacer(minLength: 0)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SourceCard: View {
    let title: String
    let detail: String
    let icon: String
    let selected: Bool
    var badge: String? = nil
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title2).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let badge {
                    Text(badge)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                } else {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(12)
            .background(selected ? Color.accentColor.opacity(0.08) : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.25))
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.62)
    }
}

struct SettingSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let footer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            Text(footer).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SummaryRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            Text(value).foregroundStyle(.secondary)
        }
    }
}

enum DiskManager {
    static let appSupportDir: URL = {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return root.appendingPathComponent("Bobrvm", isDirectory: true)
    }()

    enum DiskError: LocalizedError {
        case directoryCreationFailed

        var errorDescription: String? {
            switch self {
            case .directoryCreationFailed:
                return "Failed to create the Bobrvm application support directory."
            }
        }
    }

    static func safeFilename(_ name: String) -> String {
        VMFilename.sanitize(name)
    }

    static func createSparseDisk(name: String, sizeGB: Int) throws -> String {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        } catch {
            throw DiskError.directoryCreationFailed
        }

        let path = appSupportDir.appendingPathComponent("\(safeFilename(name)).raw").path
        try VirtualDisk.createSparse(path: path, sizeBytes: bytes(forGB: sizeGB))
        return path
    }

    static func macOSBundleURL(id: UUID) -> URL {
        appSupportDir
            .appendingPathComponent("Mac", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func createMacOSAssets(
        id: UUID,
        diskSizeGB: Int
    ) throws -> (disk: URL, auxiliaryStorage: URL) {
        let fileManager = FileManager.default
        let bundle = macOSBundleURL(id: id)
        do {
            try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        } catch {
            throw DiskError.directoryCreationFailed
        }

        let disk = bundle.appendingPathComponent("disk.img")
        guard fileManager.createFile(atPath: disk.path, contents: nil) else {
            throw BobrvmError.ioError
        }
        let handle = try FileHandle(forWritingTo: disk)
        do {
            try handle.truncate(atOffset: bytes(forGB: diskSizeGB))
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        return (
            disk: disk,
            auxiliaryStorage: bundle.appendingPathComponent("auxiliary-storage")
        )
    }

    static func growRawDisk(path: String, sizeGB: Int) throws {
        try VirtualDisk.growRaw(path: path, sizeBytes: bytes(forGB: sizeGB))
    }

    static func logicalSize(path: String) -> Int64? {
        (try? VirtualDisk.logicalSize(path: path)).flatMap(Int64.init(exactly:))
    }

    static func allocatedSize(path: String) -> Int64? {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.totalFileAllocatedSizeKey]
        )
        return values?.totalFileAllocatedSize.map(Int64.init)
    }

    static func sizeGB(path: String) -> Int? {
        guard let size = logicalSize(path: path) else { return nil }
        let gib = Int64(1024 * 1024 * 1024)
        return Int((size + gib - 1) / gib)
    }

    private static func bytes(forGB sizeGB: Int) -> UInt64 {
        UInt64(sizeGB) * 1024 * 1024 * 1024
    }

}

struct SystemInfo {
    let totalMemoryGB: Int
    let maxMemoryGB: Int
    let cpuCount: Int

    init() {
        let processInfo = ProcessInfo.processInfo
        totalMemoryGB = Int(processInfo.physicalMemory / (1024 * 1024 * 1024))
        maxMemoryGB = max(1, totalMemoryGB - 4)
        cpuCount = max(1, processInfo.processorCount)
    }
}

struct FilePickerField: View {
    let label: String
    @Binding var path: String
    let types: [UTType]
    var selectDirectories = false

    var body: some View {
        LabeledContent(label) {
            HStack {
                Text(path.isEmpty ? "None selected" : URL(fileURLWithPath: path).lastPathComponent)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !path.isEmpty {
                    Button {
                        path = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear selection")
                }
                Button("Choose…", action: selectFile)
            }
        }
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = selectDirectories
        panel.canChooseFiles = !selectDirectories
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

extension UTType {
    static var iso: UTType { UTType(filenameExtension: "iso") ?? .diskImage }
    static var ipsw: UTType { UTType(filenameExtension: "ipsw") ?? .data }
    static var rawDisk: UTType { UTType(filenameExtension: "raw") ?? .data }
    static var qcow2: UTType { UTType(filenameExtension: "qcow2") ?? .data }
}

#Preview {
    CreateVMView().environmentObject(VMManager())
}
