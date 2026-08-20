import SwiftUI
import UniformTypeIdentifiers

struct EditVMView: View {
    @EnvironmentObject var vmManager: VMManager
    @Environment(\.dismiss) var dismiss

    let vmInstance: VMInstance

    @State private var name: String
    @State private var backend: VMBackend
    @State private var isoPath: String
    @State private var memoryGB: Double
    @State private var vcpuCount: Double
    @State private var vramMB: Double
    @State private var resolution: DisplayResolution
    @State private var retinaEnabled: Bool
    @State private var networkEnabled: Bool
    @State private var sharedFolderPath: String
    @State private var diskSizeGB: Double
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isSaving = false
    @State private var hasChanges = false

    private let systemInfo = SystemInfo()

    private var isRunning: Bool {
        vmInstance.state != .stopped
    }

    init(vmInstance: VMInstance) {
        self.vmInstance = vmInstance
        _name = State(initialValue: vmInstance.name)
        _backend = State(initialValue: vmInstance.backend)
        _isoPath = State(initialValue: vmInstance.isoPath ?? "")
        _memoryGB = State(
            initialValue: Double(vmInstance.config.memoryBytes) / (1024 * 1024 * 1024))
        _vcpuCount = State(initialValue: Double(vmInstance.config.vcpuCount))
        _vramMB = State(initialValue: Double(vmInstance.vramMB))
        _resolution = State(
            initialValue: DisplayResolution(
                width: vmInstance.config.displayWidth,
                height: vmInstance.config.displayHeight
            ))
        _retinaEnabled = State(initialValue: vmInstance.retinaEnabled)
        _networkEnabled = State(initialValue: vmInstance.config.networkEnabled)
        _sharedFolderPath = State(initialValue: vmInstance.config.sharedFolderPath ?? "")
        _diskSizeGB = State(
            initialValue: Double(
                vmInstance.config.diskPath.flatMap(DiskManager.sizeGB(path:)) ?? 8
            ))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isRunning {
                    RunningVMBanner(state: vmInstance.state)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }

                Form {
                    generalSection
                    backendSection
                    storageSection
                    resourcesSection
                    graphicsSection
                    networkSection
                    informationSection
                }
                .formStyle(.grouped)
                .disabled(isSaving)
            }
            .navigationTitle("Virtual Machine Settings")
            .navigationSubtitle(vmInstance.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                }

                ToolbarItemGroup(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Saving changes")
                    }

                    Button(saveButtonTitle) {
                        saveChanges()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || !isValid || isSaving)
                }
            }
        }
        .frame(
            minWidth: 560,
            idealWidth: 620,
            minHeight: 580,
            idealHeight: isRunning ? 660 : 740
        )
        .alert("Error", isPresented: $showingError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }

    private var saveButtonTitle: String {
        isRunning ? "Apply" : "Save"
    }

    private var generalSection: some View {
        Section("General") {
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onChange(of: name) { hasChanges = true }

            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(vmInstance.state.presentationColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(vmInstance.state.presentationName)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var backendSection: some View {
        Section {
            VMBackendSelectionView(
                selection: $backend,
                guestSystem: vmInstance.guestSystem,
                disabled: isRunning
            )
            .onChange(of: backend) { _, selected in
                if selected == .virtualization {
                    sharedFolderPath = ""
                }
                hasChanges = true
            }
        } header: {
            LockableSectionHeader(title: "Virtualization Backend", isLocked: isRunning)
        } footer: {
            Text("Changing backend performs a cold boot; backend-specific state is not reused.")
        }
    }

    private var storageSection: some View {
        Section {
            if let diskPath = vmInstance.config.diskPath {
                diskImageRow(path: diskPath)

                if canGrowDisk && !isRunning {
                    SettingSlider(
                        title: "Maximum disk size",
                        valueText: "\(Int(diskSizeGB)) GB",
                        value: $diskSizeGB,
                        range: Double(currentDiskSizeGB)...Double(max(1024, currentDiskSizeGB)),
                        step: 1,
                        footer: "The disk can grow, but cannot be safely shrunk."
                    )
                    .onChange(of: diskSizeGB) { hasChanges = true }
                }
            }

            if vmInstance.guestSystem != .macOS {
                FilePickerField(label: "CD/DVD image", path: $isoPath, types: [.iso])
                    .disabled(isRunning)
                    .onChange(of: isoPath) { hasChanges = true }

                if backend == .hypervisor {
                    FilePickerField(
                        label: "Shared folder",
                        path: $sharedFolderPath,
                        types: [],
                        selectDirectories: true
                    )
                    .disabled(isRunning)
                    .onChange(of: sharedFolderPath) { hasChanges = true }
                } else {
                    LabeledContent("Shared folder") {
                        Text("Not available with Apple Virtualization")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text(storageFooter)
        }
    }

    private var resourcesSection: some View {
        Section {
            if isRunning {
                ReadOnlyConfigRow(
                    label: "Memory",
                    value: "\(Int(memoryGB)) GB",
                    icon: "memorychip"
                )
                ReadOnlyConfigRow(
                    label: "CPU cores",
                    value: "\(Int(vcpuCount))",
                    icon: "cpu"
                )
            } else {
                SettingSlider(
                    title: "Memory",
                    valueText: "\(Int(memoryGB)) GB",
                    value: $memoryGB,
                    range: memoryRangeGB,
                    step: 1,
                    footer: "\(systemInfo.totalMemoryGB) GB installed on this Mac."
                )
                .onChange(of: memoryGB) { hasChanges = true }

                SettingSlider(
                    title: "CPU cores",
                    valueText: "\(Int(vcpuCount))",
                    value: $vcpuCount,
                    range: vcpuRange,
                    step: 1,
                    footer: "\(systemInfo.cpuCount) cores available on this Mac."
                )
                .onChange(of: vcpuCount) { hasChanges = true }
            }
        } header: {
            LockableSectionHeader(title: "CPU & Memory", isLocked: isRunning)
        }
    }

    private var graphicsSection: some View {
        Section {
            graphicsMemoryRow
            displayControls
        } header: {
            LockableSectionHeader(
                title: "Graphics",
                isLocked: isRunning && backend == .virtualization
            )
        } footer: {
            if isRunning {
                Text(graphicsFooter)
            }
        }
    }

    @ViewBuilder
    private var graphicsMemoryRow: some View {
        if vmInstance.guestSystem == .macOS {
            LabeledContent("Graphics") {
                Text("Apple accelerated graphics")
                    .foregroundStyle(.secondary)
            }
        } else if backend == .virtualization {
            LabeledContent("Graphics") {
                Text("Apple compatibility display")
                    .foregroundStyle(.secondary)
            }
        } else if isRunning {
            ReadOnlyConfigRow(
                label: "Shared graphics memory",
                value: "\(Int(vramMB)) MB",
                icon: "gpu"
            )
        } else {
            SettingSlider(
                title: "Shared graphics memory",
                valueText: "\(Int(vramMB)) MB",
                value: $vramMB,
                range: vramRangeMB,
                step: 64,
                footer: "Memory reserved for the virtual graphics device."
            )
            .onChange(of: vramMB) { hasChanges = true }
        }
    }

    @ViewBuilder
    private var displayControls: some View {
        if isRunning && backend == .virtualization {
            ReadOnlyConfigRow(
                label: "Maximum resolution",
                value: resolution.label,
                icon: "display"
            )
            ReadOnlyConfigRow(
                label: "Retina resolution",
                value: retinaEnabled ? "Full" : "Standard",
                icon: "display.2"
            )
        } else {
            Picker("Maximum guest resolution", selection: $resolution) {
                ForEach(DisplayResolution.presets) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: resolution) { hasChanges = true }

            Toggle("Use full resolution on Retina displays", isOn: $retinaEnabled)
                .onChange(of: retinaEnabled) { hasChanges = true }
        }
    }

    private var networkSection: some View {
        Section {
            Toggle("Connect network adapter", isOn: $networkEnabled)
                .disabled(isRunning)
                .onChange(of: networkEnabled) { hasChanges = true }

            LabeledContent("Connection") {
                Text(backend == .virtualization ? "Apple NAT" : "Share with my Mac")
                    .foregroundStyle(.secondary)
            }
        } header: {
            LockableSectionHeader(title: "Network", isLocked: isRunning)
        } footer: {
            Text(networkFooter)
        }
    }

    private var informationSection: some View {
        Section("Information") {
            LabeledContent("VM ID") {
                Text(vmInstance.id.uuidString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            LabeledContent("Backend") {
                Text(backend.displayName)
                    .foregroundStyle(.secondary)
            }

            if let diskPath = vmInstance.config.diskPath {
                LabeledContent("Disk path") {
                    Text(diskPath)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func diskImageRow(path: String) -> some View {
        LabeledContent("Disk image") {
            VStack(alignment: .trailing, spacing: 3) {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let capacity = DiskManager.logicalSize(path: path) {
                    let allocated = DiskManager.allocatedSize(path: path) ?? capacity
                    Text("\(formatBytes(allocated)) used of \(formatBytes(capacity))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var currentDiskSizeGB: Int {
        vmInstance.config.diskPath.flatMap(DiskManager.sizeGB(path:)) ?? 8
    }

    private var canGrowDisk: Bool {
        vmInstance.config.diskPath.map {
            URL(fileURLWithPath: $0).pathExtension.lowercased() == "raw"
        } ?? false
    }

    private var memoryRangeGB: ClosedRange<Double> {
        let configuredGB = Double(vmInstance.config.memoryBytes) / (1024 * 1024 * 1024)
        return min(1, configuredGB)...max(Double(systemInfo.maxMemoryGB), configuredGB)
    }

    private var vcpuRange: ClosedRange<Double> {
        let configured = Double(vmInstance.config.vcpuCount)
        return min(1, configured)...max(Double(systemInfo.cpuCount), configured)
    }

    private var vramRangeMB: ClosedRange<Double> {
        let configuredMB = Double(vmInstance.vramMB)
        return min(64, configuredMB)...max(2048, configuredMB)
    }

    private var storageFooter: String {
        if vmInstance.guestSystem == .macOS {
            return "Bobrvm doesn’t currently support changing storage for macOS virtual machines."
        }
        if isRunning {
            return "Stop the VM to change attached storage or shared folders."
        }
        if canGrowDisk {
            return "Raw disk capacity may only be increased while the VM is stopped."
        }
        return "This disk format cannot be resized by Bobrvm."
    }

    private var graphicsFooter: String {
        if backend == .virtualization {
            return "Stop the VM to change its display configuration."
        }
        return "Resolution and Retina scaling apply immediately. "
            + "Stop the VM to change graphics memory."
    }

    private var networkFooter: String {
        if isRunning {
            return "Stop the VM to connect or disconnect its network adapter."
        }
        return backend == .virtualization
            ? "Uses Apple’s NAT to share this Mac’s internet connection."
            : "Uses Bobrvm’s built-in NAT to share this Mac’s internet connection."
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func saveChanges() {
        isSaving = true

        do {
            if isRunning {
                try vmManager.updateLiveSettings(
                    vmInstance,
                    name: name,
                    displayWidth: resolution.width,
                    displayHeight: resolution.height,
                    retinaEnabled: retinaEnabled
                )
            } else {
                try vmManager.updateVM(
                    vmInstance,
                    name: name,
                    memoryGB: Int(memoryGB),
                    vcpuCount: Int(vcpuCount),
                    vramMB: Int(vramMB),
                    isoPath: isoPath.isEmpty ? nil : isoPath,
                    displayWidth: Int(resolution.width),
                    displayHeight: Int(resolution.height),
                    retinaEnabled: retinaEnabled,
                    networkEnabled: networkEnabled,
                    sharedFolderPath: sharedFolderPath.isEmpty ? nil : sharedFolderPath,
                    diskSizeGB: canGrowDisk ? Int(diskSizeGB) : nil,
                    backend: backend
                )
            }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
            isSaving = false
        }
    }
}

private struct RunningVMBanner: View {
    let state: VMState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)

                Text("Live-safe settings remain editable; stop the VM to change hardware.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        state == .paused ? "pause.circle.fill" : "play.circle.fill"
    }

    private var title: String {
        state == .paused ? "VM is paused" : "VM is running"
    }

    private var tint: Color {
        state == .paused ? .orange : .green
    }
}

private struct ReadOnlyConfigRow: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        LabeledContent {
            Text(value)
                .fontWeight(.medium)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(label)
            }
        }
    }
}

private struct LockableSectionHeader: View {
    let title: String
    let isLocked: Bool

    var body: some View {
        HStack {
            Text(title)
            if isLocked {
                Spacer()
                LockedBadge()
            }
        }
    }
}

private struct LockedBadge: View {
    var body: some View {
        Label("Locked", systemImage: "lock.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}
