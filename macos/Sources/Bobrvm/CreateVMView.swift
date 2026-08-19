import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CreateVMView: View {
    @EnvironmentObject private var vmManager: VMManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("defaultMemoryGB") private var defaultMemoryGB = 4
    @AppStorage("defaultVCPUs") private var defaultVCPUs = 2

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
    @State private var didApplyDefaults = false
    @State private var creationTask: Task<Void, Never>?

    private let systemInfo = SystemInfo()

    var body: some View {
        HStack(spacing: 0) {
            CreationStepSidebar(step: step)
                .frame(width: 228)
            Divider()
            VStack(spacing: 0) {
                stepContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .disabled(isCreating)
                footer
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: 760,
            idealWidth: 860,
            maxWidth: 1040,
            minHeight: 580,
            idealHeight: 660,
            maxHeight: 820
        )
        .presentationSizing(.fitted)
        .interactiveDismissDisabled(isCreating)
        .onAppear(perform: applyDefaults)
        .onChange(of: operatingSystem) { _, selected in
            guard let selected else { return }
            switch selected {
            case .linux:
                source = .installFromISO
                updateDefaultName(to: selected)
            case .macOS:
                guard systemInfo.supportsMacOSGuest else {
                    operatingSystem = nil
                    return
                }
                source = .installMacOS
                updateDefaultName(to: selected)
                memoryGB = min(max(memoryGB, 8), Double(systemInfo.maxMemoryGB))
                vcpuCount = max(vcpuCount, 4)
                diskSizeGB = max(diskSizeGB, 80)
            case .windows:
                source = .installFromISO
                updateDefaultName(to: selected)
                memoryGB = max(memoryGB, 4)
                vcpuCount = max(vcpuCount, 2)
                diskSizeGB = max(diskSizeGB, 64)
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
            OperatingSystemStepView(selection: $operatingSystem, systemInfo: systemInfo)
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
                guestSystem: (operatingSystem ?? .linux).guestSystem,
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
                operatingSystem: operatingSystem ?? .linux,
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
        HStack(spacing: 12) {
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 24)
            if isCreating {
                creationProgress
            } else {
                if step != .operatingSystem {
                    Button("Back") { step = step.previous }
                        .accessibilityHint("Returns to \(step.previous.title)")
                }
                Button(step == .summary ? "Create" : "Continue") {
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private func cancel() {
        creationTask?.cancel()
        creationTask = nil
        dismiss()
    }

    @ViewBuilder
    private var creationProgress: some View {
        if isCreating {
            if source == .installMacOS {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(
                            installationProgress < 0.70
                                ? "Downloading macOS"
                                : "Installing macOS"
                        )
                        Text("\(Int(installationProgress * 100))%")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    ProgressView(value: installationProgress)
                        .frame(width: 172)
                }
                .accessibilityElement(children: .combine)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Creating virtual machine")
            }
        }
    }

    private func advance() {
        if step == .summary {
            createVM()
        } else {
            step = step.next
        }
    }

    private func applyDefaults() {
        guard !didApplyDefaults else { return }
        didApplyDefaults = true
        let memoryDefaultGB = systemInfo.clampDefaultMemoryGB(defaultMemoryGB)
        let vcpuDefault = systemInfo.clampDefaultVCPUCount(defaultVCPUs)
        defaultMemoryGB = memoryDefaultGB
        defaultVCPUs = vcpuDefault
        memoryGB = Double(memoryDefaultGB)
        vcpuCount = Double(vcpuDefault)
    }

    private var canContinue: Bool {
        if isCreating { return false }
        switch step {
        case .operatingSystem:
            return operatingSystem.map(systemInfo.supports) ?? false
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
            creationTask = Task { @MainActor in
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
                } catch is CancellationError {
                    // The user cancelled; the manager removes partial assets.
                } catch {
                    errorMessage = error.localizedDescription
                    isCreating = false
                }
                creationTask = nil
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
                retinaEnabled: retinaEnabled,
                guestSystem: (operatingSystem ?? .linux).guestSystem
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

    private func updateDefaultName(to operatingSystem: CreationOperatingSystem) {
        let defaultNames = CreationOperatingSystem.allCases.map(\.title)
        if defaultNames.contains(name) {
            name = operatingSystem.title
        }
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
    var guestSystem: GuestSystem {
        switch self {
        case .linux: return .linux
        case .macOS: return .macOS
        case .windows: return .windows
        }
    }

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
        case .windows: return "Install Windows for Arm or attach an existing virtual disk."
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
        VStack(alignment: .leading, spacing: 0) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Virtual Machine")
                        .font(.headline)
                    Text("Setup Assistant")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 18)

            VStack(spacing: 6) {
                ForEach(CreationStep.allCases, id: \.rawValue) { item in
                    stepRow(item)
                }
            }

            Spacer()

            Text("Step \(step.rawValue + 1) of \(CreationStep.allCases.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .padding(.horizontal, 8)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func stepRow(_ item: CreationStep) -> some View {
        HStack(spacing: 11) {
            Image(systemName: indicatorIcon(for: item))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(indicatorColor(for: item))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .fontWeight(item == step ? .semibold : .regular)
                if item == step {
                    Text("Current step")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(item.rawValue <= step.rawValue ? .primary : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background {
            if item == step {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.title), \(accessibilityState(for: item))")
    }

    private func indicatorIcon(for item: CreationStep) -> String {
        if item.rawValue < step.rawValue {
            return "checkmark.circle.fill"
        }
        return item == step ? "circle.inset.filled" : "circle"
    }

    private func indicatorColor(for item: CreationStep) -> Color {
        item.rawValue <= step.rawValue ? .accentColor : .secondary
    }

    private func accessibilityState(for item: CreationStep) -> String {
        if item.rawValue < step.rawValue {
            return "completed"
        }
        return item == step ? "current step" : "not yet completed"
    }
}

private struct OperatingSystemStepView: View {
    @Binding var selection: CreationOperatingSystem?
    let systemInfo: SystemInfo

    var body: some View {
        WizardPage(
            title: "Choose an operating system",
            subtitle: "Select the operating system for this virtual machine."
        ) {
            VStack(spacing: 12) {
                ForEach(CreationOperatingSystem.allCases) { operatingSystem in
                    SourceCard(
                        title: operatingSystem.title,
                        detail: detail(for: operatingSystem),
                        icon: operatingSystem.icon,
                        selected: selection == operatingSystem,
                        badge: systemInfo.supports(operatingSystem) ? nil : "Unavailable",
                        enabled: systemInfo.supports(operatingSystem)
                    ) {
                        selection = operatingSystem
                    }
                }
            }
        }
    }

    private func detail(for operatingSystem: CreationOperatingSystem) -> String {
        guard operatingSystem == .macOS, !systemInfo.supportsMacOSGuest else {
            return operatingSystem.detail
        }
        return "Requires at least 12 GB of installed memory."
    }
}

private struct InstallationStepView: View {
    let operatingSystem: CreationOperatingSystem
    @Binding var source: VMSource
    @Binding var isoPath: String
    @Binding var ipswPath: String
    @Binding var macOSRestoreSource: MacOSRestoreSource
    @Binding var existingDiskPath: String
    @State private var showingWindowsDownloader = false

    var body: some View {
        WizardPage(
            title: "Choose an installation method",
            subtitle: installationSubtitle
        ) {
            installationOptions
        }
        .sheet(isPresented: $showingWindowsDownloader) {
            WindowsMediaDownloadView { url in
                isoPath = url.path
            }
        }
    }

    @ViewBuilder
    private var installationOptions: some View {
        if operatingSystem == .macOS {
            macOSInstallationOptions
        } else {
            diskInstallationOptions
        }
    }

    private var macOSInstallationOptions: some View {
        SettingsGroup(title: "Restore Image", systemImage: "shippingbox") {
            Picker("macOS Version", selection: $macOSRestoreSource) {
                Text("Download latest supported macOS").tag(MacOSRestoreSource.latest)
                Text("Use a local IPSW").tag(MacOSRestoreSource.local)
            }
            .pickerStyle(.radioGroup)
            if macOSRestoreSource == .local {
                Divider()
                FilePickerField(label: "Restore Image", path: $ipswPath, types: [.ipsw])
            }
            Divider()
            InformationLabel(text: macOSRestoreDescription)
        }
    }

    private var diskInstallationOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 12) {
                isoInstallationOption
                existingDiskOption
            }
            if operatingSystem == .windows {
                InformationLabel(text: "Windows installation media must support Arm64.")
            }
        }
    }

    private var isoInstallationOption: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourceCard(
                title: "Install from ISO image",
                detail: "Create a new disk and boot from installation media.",
                icon: "opticaldisc",
                selected: source == .installFromISO
            ) { source = .installFromISO }
            if source == .installFromISO {
                VStack(alignment: .leading, spacing: 12) {
                    FilePickerField(label: "ISO Image", path: $isoPath, types: [.iso])
                    windowsDownloadButton
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
    private var windowsDownloadButton: some View {
        if operatingSystem == .windows {
            Button {
                showingWindowsDownloader = true
            } label: {
                Label(
                    "Download Windows 11 from Microsoft…",
                    systemImage: "arrow.down.circle"
                )
            }
        }
    }

    private var existingDiskOption: some View {
        VStack(alignment: .leading, spacing: 12) {
            SourceCard(
                title: "Use an existing virtual disk",
                detail: "Boot a raw or QCOW2 disk that already contains "
                    + "\(operatingSystem.title).",
                icon: "externaldrive",
                selected: source == .existingDisk
            ) { source = .existingDisk }
            if source == .existingDisk {
                FilePickerField(
                    label: "Virtual Disk",
                    path: $existingDiskPath,
                    types: [.rawDisk, .qcow2, .diskImage]
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
        }
    }

    private var macOSRestoreDescription: String {
        if macOSRestoreSource == .latest {
            return "Apple’s restore image is roughly 15–25 GB and is cached after download. "
                + "Installation can take up to an hour and the VM must remain open."
        }
        return "Choose an Apple restore image compatible with this Mac. Installation can take "
            + "up to an hour and the VM must remain open."
    }

    private var installationSubtitle: String {
        switch operatingSystem {
        case .macOS:
            return "Choose where Bobrvm should obtain the macOS restore image."
        case .linux:
            return "Install Linux from an ISO or use an existing virtual disk."
        case .windows:
            return "Install Windows for Arm from an ISO or use an existing virtual disk."
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
            performanceSettings
            displaySettings
        }
    }

    private var performanceSettings: some View {
        SettingsGroup(title: "Performance", systemImage: "cpu") {
            SettingSlider(
                title: "Processor cores",
                valueText: "\(Int(vcpuCount))",
                value: $vcpuCount,
                range: 1...Double(systemInfo.cpuCount),
                step: 1,
                footer: "\(systemInfo.cpuCount) cores available"
            )
            Divider()
            SettingSlider(
                title: "Memory",
                valueText: "\(Int(memoryGB)) GB",
                value: $memoryGB,
                range: 1...Double(systemInfo.maxMemoryGB),
                step: 1,
                footer: "\(systemInfo.totalMemoryGB) GB installed on this Mac"
            )
            if guestSystem != .macOS {
                Divider()
                SettingSlider(
                    title: "Shared graphics memory",
                    valueText: "\(Int(vramMB)) MB",
                    value: $vramMB,
                    range: 128...2048,
                    step: 128,
                    footer: "Reserved from host memory for the virtual GPU"
                )
            }
        }
    }

    private var displaySettings: some View {
        SettingsGroup(title: "Display", systemImage: "display") {
            if guestSystem == .macOS {
                Label("Apple accelerated graphics", systemImage: "gpu")
                    .foregroundStyle(.secondary)
                Divider()
            }
            LabeledContent("Maximum guest resolution") {
                Picker("Maximum guest resolution", selection: $resolution) {
                    ForEach(DisplayResolution.presets) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 168)
            }
            Text("The guest display follows the VM window up to this framebuffer size.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Toggle("Use full resolution for Retina display", isOn: $retinaEnabled)
            Text(retinaDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var retinaDescription: String {
        retinaEnabled
            ? "Renders one guest pixel per Retina pixel for sharper output."
            : "Renders at standard scale to reduce GPU and memory use."
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
            SettingsGroup(title: "Virtual Disk", systemImage: "internaldrive") {
                if source != .existingDisk {
                    SettingSlider(
                        title: "Maximum disk size",
                        valueText: "\(Int(diskSizeGB)) GB",
                        value: $diskSizeGB,
                        range: 8...512,
                        step: 1,
                        footer: "You can grow this disk later, but it cannot be shrunk safely."
                    )
                    Divider()
                    InformationLabel(
                        text: "A sparse raw disk will be stored in Bobrvm’s Application "
                            + "Support folder.",
                        systemImage: "internaldrive"
                    )
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
}

private struct SummaryStepView: View {
    @Binding var name: String
    let operatingSystem: CreationOperatingSystem
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
            SettingsGroup(title: "Identity", systemImage: "text.cursor") {
                LabeledContent("Name") {
                    TextField("Virtual machine name", text: $name)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 180, idealWidth: 240, maxWidth: 280)
                        .accessibilityHint("Used in the virtual machine library and disk name")
                }
            }
            SettingsGroup(title: "Configuration", systemImage: "gearshape") {
                SummaryRow(label: "Operating System", value: operatingSystem.title)
                Divider()
                SummaryRow(
                    label: "Processors & Memory",
                    value: "\(vcpuCount) cores, \(memoryGB) GB"
                )
                Divider()
                SummaryRow(
                    label: "Graphics",
                    value: source == .installMacOS
                        ? "Apple accelerated, \(resolution.label)"
                        : "\(vramMB) MB, \(resolution.label)"
                )
                Divider()
                SummaryRow(
                    label: "Retina",
                    value: retinaEnabled ? "Full resolution" : "Standard scale"
                )
                Divider()
                SummaryRow(
                    label: "Disk",
                    value: source != .existingDisk
                        ? "\(diskSizeGB) GB sparse disk"
                        : URL(fileURLWithPath: existingDiskPath).lastPathComponent
                )
            }
            SettingsGroup(title: "Installation Media", systemImage: "opticaldisc") {
                SummaryRow(
                    label: source == .installMacOS ? "Restore Image" : "CD/DVD",
                    value: installationMediaName
                )
            }
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
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title)
                        .font(.title)
                        .fontWeight(.semibold)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 18) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 34)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .top)
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
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
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
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if selected {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: selected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.62)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                content
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }
}

private struct InformationLabel: View {
    let text: String
    var systemImage = "info.circle"

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
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
                    .fontWeight(.medium)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(valueText)
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    var defaultMemoryOptionsGB: [Int] {
        [1, 2, 4, 8, 16, 32, 64, 128].filter { $0 <= maxMemoryGB }
    }

    var supportsMacOSGuest: Bool {
        maxMemoryGB >= 8
    }

    init() {
        let processInfo = ProcessInfo.processInfo
        totalMemoryGB = Int(processInfo.physicalMemory / (1024 * 1024 * 1024))
        maxMemoryGB = max(1, totalMemoryGB - 4)
        cpuCount = max(1, processInfo.processorCount)
    }

    func clampDefaultMemoryGB(_ value: Int) -> Int {
        defaultMemoryOptionsGB.last(where: { $0 <= value }) ?? defaultMemoryOptionsGB[0]
    }

    func clampDefaultVCPUCount(_ value: Int) -> Int {
        min(max(1, value), cpuCount)
    }

    fileprivate func supports(_ operatingSystem: CreationOperatingSystem) -> Bool {
        operatingSystem != .macOS || supportsMacOSGuest
    }
}

struct FilePickerField: View {
    let label: String
    @Binding var path: String
    let types: [UTType]
    var selectDirectories = false

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text(path.isEmpty ? "None selected" : URL(fileURLWithPath: path).lastPathComponent)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                if !path.isEmpty {
                    Button {
                        path = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear selection")
                    .accessibilityLabel("Clear \(label) selection")
                }
                Button("Choose…", action: selectFile)
                    .accessibilityLabel("Choose \(label)")
            }
        }
        .accessibilityValue(path.isEmpty ? "No file selected" : path)
    }

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose \(label)"
        panel.prompt = "Choose"
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
