import SwiftUI
import UniformTypeIdentifiers

struct EditVMView: View {
    @EnvironmentObject var vmManager: VMManager
    @Environment(\.dismiss) var dismiss

    let vmInstance: VMInstance

    @State private var name: String
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
        VStack(spacing: 0) {
            if isRunning {
                RunningVMBanner(state: vmInstance.state)
            }

            Form {
                Section("General") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _ in hasChanges = true }

                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(vmInstance.state.presentationColor)
                                .frame(width: 8, height: 8)
                            Text(vmInstance.state.presentationName)
                        }
                    }
                }

                Section {
                    if let diskPath = vmInstance.config.diskPath {
                        LabeledContent("Disk Image") {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(URL(fileURLWithPath: diskPath).lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                if let capacity = DiskManager.logicalSize(path: diskPath) {
                                    let allocated =
                                        DiskManager.allocatedSize(path: diskPath) ?? capacity
                                    Text(
                                        "\(formatBytes(allocated)) used of \(formatBytes(capacity))"
                                    )
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
                            }
                        }

                        if canGrowDisk && !isRunning {
                            SettingSlider(
                                title: "Maximum disk size",
                                valueText: "\(Int(diskSizeGB)) GB",
                                value: $diskSizeGB,
                                range: Double(
                                    currentDiskSizeGB)...Double(max(1024, currentDiskSizeGB)),
                                step: 1,
                                footer: "The disk can grow, but cannot be safely shrunk."
                            )
                            .onChange(of: diskSizeGB) { _ in hasChanges = true }
                        }
                    }

                    if vmInstance.guestSystem == .linux {
                        FilePickerField(
                            label: "CD/DVD Image",
                            path: $isoPath,
                            types: [.iso]
                        )
                        .onChange(of: isoPath) { _ in hasChanges = true }

                        FilePickerField(
                            label: "Shared Folder",
                            path: $sharedFolderPath,
                            types: [],
                            selectDirectories: true
                        )
                        .disabled(isRunning)
                        .onChange(of: sharedFolderPath) { _ in hasChanges = true }
                    }
                } header: {
                    Text("Storage")
                } footer: {
                    Text(
                        canGrowDisk
                            ? "Raw disk capacity may only be increased while the VM is stopped."
                            : "This disk format cannot be resized by Bobrvm."
                    )
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                if isRunning {
                    Section {
                        ReadOnlyConfigRow(
                            label: "Memory",
                            value: "\(Int(memoryGB)) GB",
                            icon: "memorychip"
                        )

                        ReadOnlyConfigRow(
                            label: "CPU Cores",
                            value: "\(Int(vcpuCount))",
                            icon: "cpu"
                        )
                    } header: {
                        HStack {
                            Text("CPU & Memory")
                            Spacer()
                            LockedBadge()
                        }
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Memory")
                                Spacer()
                                Text("\(Int(memoryGB)) GB")
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: $memoryGB, in: 1...Double(systemInfo.maxMemoryGB), step: 1
                            )
                            .onChange(of: memoryGB) { _ in hasChanges = true }
                            Text("\(systemInfo.totalMemoryGB) GB total on this Mac")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("CPU Cores")
                                Spacer()
                                Text("\(Int(vcpuCount))")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $vcpuCount, in: 1...Double(systemInfo.cpuCount), step: 1)
                                .onChange(of: vcpuCount) { _ in hasChanges = true }
                            Text("\(systemInfo.cpuCount) cores available")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } header: {
                        Text("CPU & Memory")
                    }
                }

                if isRunning {
                    Section {
                        if vmInstance.guestSystem == .macOS {
                            ReadOnlyConfigRow(
                                label: "Graphics",
                                value: "Apple accelerated graphics",
                                icon: "gpu"
                            )
                        } else {
                            ReadOnlyConfigRow(
                                label: "Shared Graphics Memory",
                                value: "\(Int(vramMB)) MB",
                                icon: "gpu"
                            )
                        }
                        ReadOnlyConfigRow(
                            label: "Maximum Resolution",
                            value: resolution.label,
                            icon: "display"
                        )
                    } header: {
                        HStack {
                            Text("Graphics")
                            Spacer()
                            LockedBadge()
                        }
                    }
                } else {
                    Section {
                        if vmInstance.guestSystem == .macOS {
                            LabeledContent("Graphics") {
                                Text("Apple accelerated graphics")
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Shared Graphics Memory")
                                    Spacer()
                                    Text("\(Int(vramMB)) MB")
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: $vramMB, in: 64...2048, step: 64)
                                    .onChange(of: vramMB) { _ in hasChanges = true }
                            }
                        }

                        Picker("Maximum Guest Resolution", selection: $resolution) {
                            ForEach(DisplayResolution.presets) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .onChange(of: resolution) { _ in hasChanges = true }

                        Toggle("Use full resolution for Retina display", isOn: $retinaEnabled)
                            .onChange(of: retinaEnabled) { _ in hasChanges = true }
                    } header: {
                        Text("Graphics")
                    }
                }

                Section {
                    Toggle("Connect Network Adapter", isOn: $networkEnabled)
                        .disabled(isRunning)
                        .onChange(of: networkEnabled) { _ in hasChanges = true }

                    LabeledContent("Network") {
                        Text("Share with my Mac")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Network Adapter")
                        if isRunning {
                            Spacer()
                            LockedBadge()
                        }
                    }
                } footer: {
                    Text(
                        isRunning
                            ? "Stop the VM to connect or disconnect its network adapter."
                            : "Uses Bobrvm’s built-in NAT to share the Mac’s "
                                + "internet connection."
                    )
                }

                Section("Information") {
                    LabeledContent("VM ID") {
                        Text(vmInstance.id.uuidString)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundColor(.secondary)
                    }

                    if let diskPath = vmInstance.config.diskPath {
                        LabeledContent("Disk Path") {
                            Text(diskPath)
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(2)
                                .textSelection(.enabled)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)

            Divider()

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

                Spacer()

                if isSaving {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 8)
                }

                if isRunning {
                    Button("Done") {
                        if hasChanges {
                            saveChanges()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                } else {
                    Button("Save") {
                        saveChanges()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges || !isValid || isSaving)
                }
            }
            .padding()
        }
        .frame(width: 520, height: isRunning ? 640 : 720)
        .alert("Error", isPresented: $showingError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
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

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func saveChanges() {
        isSaving = true

        do {
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
                diskSizeGB: canGrowDisk ? Int(diskSizeGB) : nil
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showingError = true
            isSaving = false
        }
    }
}

// MARK: - Running VM Banner

struct RunningVMBanner: View {
    let state: VMState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state == .paused ? "pause.circle.fill" : "play.circle.fill")
                .font(.title2)
                .foregroundColor(state == .paused ? .orange : .green)

            VStack(alignment: .leading, spacing: 2) {
                Text(state == .paused ? "VM is Paused" : "VM is Running")
                    .font(.headline)

                Text("Stop the VM to change hardware settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "lock.fill")
                .foregroundColor(.secondary)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(state == .paused ? Color.orange.opacity(0.1) : Color.green.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    state == .paused ? Color.orange.opacity(0.3) : Color.green.opacity(0.3),
                    lineWidth: 1)
        )
        .padding()
    }
}

// MARK: - Read-Only Config Row

struct ReadOnlyConfigRow: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        LabeledContent {
            Text(value)
                .foregroundColor(.primary)
                .fontWeight(.medium)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                    .frame(width: 20)
                Text(label)
            }
        }
    }
}

// MARK: - Locked Badge

struct LockedBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
                .font(.caption2)
            Text("Locked")
                .font(.caption2)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.15))
        )
    }
}
