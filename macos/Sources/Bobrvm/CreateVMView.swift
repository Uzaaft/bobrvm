//
//  CreateVMView.swift
//  Bobrvm
//
//  VM creation wizard - simplified VMware-style flow.
//

import SwiftUI
import UniformTypeIdentifiers

struct CreateVMView: View {
    @EnvironmentObject var vmManager: VMManager
    @Environment(\.dismiss) var dismiss
    
    @State private var name = "New VM"
    @State private var diskMode: DiskMode = .createNew
    @State private var existingDiskPath = ""
    @State private var newDiskSizeGB: Double = 64
    @State private var isoPath = ""
    @State private var memoryGB: Double = 4
    @State private var vcpuCount: Double = 2
    @State private var vramMB: Double = 256
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isCreating = false
    
    private let systemInfo = SystemInfo()
    
    enum DiskMode: String, CaseIterable {
        case createNew = "Create new disk"
        case useExisting = "Use existing disk"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Form {
                // Step 1: General
                Section("General") {
                    TextField("Name", text: $name)
                }
                
                // Step 2: Storage
                Section {
                    Picker("Disk", selection: $diskMode) {
                        ForEach(DiskMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    if diskMode == .createNew {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Disk Size")
                                Spacer()
                                Text("\(Int(newDiskSizeGB)) GB")
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $newDiskSizeGB, in: 8...512, step: 8)
                            Text("Disk will be created as a sparse file (only uses space as needed)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        FilePickerField(
                            label: "Disk Image",
                            path: $existingDiskPath,
                            types: [.diskImage, .rawDisk, .qcow2]
                        )
                    }
                    
                    FilePickerField(
                        label: "Installation ISO",
                        path: $isoPath,
                        types: [.iso]
                    )
                } header: {
                    Text("Storage")
                } footer: {
                    if diskMode == .createNew {
                        Text("A new disk image will be created in ~/Library/Application Support/Bobrvm/")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                // Step 3: CPU & Memory
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Memory")
                            Spacer()
                            Text("\(Int(memoryGB)) GB")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $memoryGB, in: 1...Double(systemInfo.maxMemoryGB), step: 1)
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
                        Text("\(systemInfo.cpuCount) cores available")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("CPU & Memory")
                }
                
                // Step 4: GPU
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Shared Graphics Memory")
                            Spacer()
                            Text("\(Int(vramMB)) MB")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $vramMB, in: 64...2048, step: 64)
                    }
                } header: {
                    Text("Graphics")
                } footer: {
                    Text("Amount of system memory shared with the virtual GPU.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)
            
            Divider()
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)
                
                Spacer()
                
                if isCreating {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 8)
                }
                
                Button("Create") {
                    createVM()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || isCreating)
            }
            .padding()
        }
        .frame(width: 480, height: 560)
        .alert("Error", isPresented: $showingError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
    }
    
    private var isValid: Bool {
        guard !name.isEmpty else { return false }
        if diskMode == .useExisting && existingDiskPath.isEmpty {
            return false
        }
        return true
    }
    
    private func createVM() {
        isCreating = true
        
        Task {
            var createdDiskPath: String?
            do {
                let diskPath: String
                
                if diskMode == .createNew {
                    diskPath = try await DiskManager.createSparseDisk(
                        name: name,
                        sizeGB: Int(newDiskSizeGB)
                    )
                    createdDiskPath = diskPath
                } else {
                    diskPath = existingDiskPath
                }
                
                // UEFI firmware path - bundled with app
                let firmwarePath = Bundle.main.path(forResource: "QEMU_EFI", ofType: "fd")
                
                // UEFI variables file - per-VM persistent storage (sanitize name for filename)
                let safeName = name
                    .replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: " ", with: "_")
                let varsPath = DiskManager.appSupportDir
                    .appendingPathComponent("\(safeName)_vars.fd")
                    .path
                
                let config = VMConfig(
                    memoryBytes: UInt64(memoryGB * 1024 * 1024 * 1024),
                    vcpuCount: UInt8(vcpuCount),
                    firmwarePath: firmwarePath,
                    varsPath: varsPath,
                    kernelPath: nil,
                    initrdPath: nil,
                    cmdline: nil,
                    diskPath: diskPath,
                    diskReadOnly: false,
                    isoPath: isoPath.isEmpty ? nil : isoPath,
                    isoReadOnly: true
                )
                
                try vmManager.createVM(
                    name: name,
                    config: config,
                    isoPath: isoPath.isEmpty ? nil : isoPath,
                    vramMB: Int(vramMB)
                )
                
                await MainActor.run {
                    dismiss()
                }
            } catch {
                if let diskPath = createdDiskPath {
                    try? FileManager.default.removeItem(atPath: diskPath)
                }
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showingError = true
                    isCreating = false
                }
            }
        }
    }
}

// MARK: - Disk Manager

enum DiskManager {
    static let appSupportDir: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Bobrvm", isDirectory: true)
    }()
    
    enum DiskError: LocalizedError {
        case directoryCreationFailed
        case diskCreationFailed(String)
        case diskAlreadyExists
        
        var errorDescription: String? {
            switch self {
            case .directoryCreationFailed:
                return "Failed to create application support directory"
            case .diskCreationFailed(let reason):
                return "Failed to create disk: \(reason)"
            case .diskAlreadyExists:
                return "A disk with this name already exists"
            }
        }
    }
    
    /// Creates a sparse disk image (like Lima/Fusion).
    /// Only allocates space as data is written.
    static func createSparseDisk(name: String, sizeGB: Int) async throws -> String {
        let fm = FileManager.default
        
        // Create directory if needed
        if !fm.fileExists(atPath: appSupportDir.path) {
            do {
                try fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
            } catch {
                throw DiskError.directoryCreationFailed
            }
        }
        
        // Sanitize name for filename
        let safeName = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        
        let diskPath = appSupportDir
            .appendingPathComponent("\(safeName).raw")
            .path
        
        // Check if already exists
        if fm.fileExists(atPath: diskPath) {
            throw DiskError.diskAlreadyExists
        }
        
        // Create sparse file using truncate (like Lima)
        let sizeBytes = Int64(sizeGB) * 1024 * 1024 * 1024
        
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    // Create empty file
                    fm.createFile(atPath: diskPath, contents: nil)
                    
                    // Open and truncate to desired size (sparse)
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: diskPath))
                    try handle.truncate(atOffset: UInt64(sizeBytes))
                    try handle.close()
                    
                    continuation.resume(returning: diskPath)
                } catch {
                    // Clean up on failure
                    try? fm.removeItem(atPath: diskPath)
                    continuation.resume(throwing: DiskError.diskCreationFailed(error.localizedDescription))
                }
            }
        }
        
        return result
    }
    
    /// Get actual disk usage of a sparse file
    static func actualDiskUsage(path: String) -> Int64? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else {
            return nil
        }
        return size
    }
}

// MARK: - System Info

struct SystemInfo {
    let totalMemoryGB: Int
    let maxMemoryGB: Int
    let cpuCount: Int
    
    init() {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        totalMemoryGB = Int(physicalMemory / (1024 * 1024 * 1024))
        // Reserve 4GB for macOS, minimum 1GB for VM
        maxMemoryGB = max(1, totalMemoryGB - 4)
        cpuCount = ProcessInfo.processInfo.processorCount
    }
}

// MARK: - File Picker Field

struct FilePickerField: View {
    let label: String
    @Binding var path: String
    let types: [UTType]
    
    var body: some View {
        LabeledContent(label) {
            HStack {
                Text(path.isEmpty ? "None" : URL(fileURLWithPath: path).lastPathComponent)
                    .foregroundColor(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
                
                Button("Choose...") {
                    selectFile()
                }
                .buttonStyle(.bordered)
            }
        }
    }
    
    private func selectFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

// MARK: - UTType Extensions

extension UTType {
    static var iso: UTType {
        UTType(filenameExtension: "iso") ?? .diskImage
    }
    
    static var rawDisk: UTType {
        UTType(filenameExtension: "raw") ?? .data
    }
    
    static var qcow2: UTType {
        UTType(filenameExtension: "qcow2") ?? .data
    }
}

#Preview {
    CreateVMView()
        .environmentObject(VMManager())
}
