import AppKit
import SwiftUI

/// A read-only projection: the CLI JSON remains the authoritative configuration.
struct CLIInventoryEntry: Identifiable, Sendable {
    let name: String
    let file: URL
    let memoryMB: UInt64
    let cpuCount: UInt8
    let disk: String?
    let diskExists: Bool

    var id: String { "cli:\(name)" }
    var startCommand: String {
        "bobrvm start '" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct Record: Decodable {
        let memory_mb: UInt64?
        let vcpu_count: UInt8?
        let disk_path: String?
    }

    static func read(directory: URL) throws -> [CLIInventoryEntry] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let files = try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true, let size = values.fileSize, size <= 1024 * 1024,
                let data = try? Data(contentsOf: file),
                let record = try? JSONDecoder().decode(Record.self, from: data)
            else { return nil }
            return CLIInventoryEntry(
                name: file.deletingPathExtension().lastPathComponent,
                file: file, memoryMB: record.memory_mb ?? 512,
                cpuCount: record.vcpu_count ?? 2, disk: record.disk_path,
                diskExists: record.disk_path.map { manager.fileExists(atPath: $0) } ?? true
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct CLIInventoryView: View {
    let searchText: String
    @State private var entries: [CLIInventoryEntry] = []
    @State private var errorMessage: String?
    @State private var refreshID = UUID()

    private var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/bobrvm/vms", isDirectory: true)
    }

    var body: some View {
        List {
            Section {
                Text("Start these VMs from Terminal using the commands below.")
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            }
            ForEach(entries.filter {
                searchText.isEmpty || $0.name.localizedStandardContains(searchText)
            }) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Label(entry.name, systemImage: "terminal")
                        .font(.headline)
                    Text("\(entry.memoryMB) MB · \(entry.cpuCount) CPUs")
                        .foregroundStyle(.secondary)
                    if let disk = entry.disk {
                        Text(disk).font(.caption).textSelection(.enabled)
                    }
                    if !entry.diskExists {
                        Label("Disk not found", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text(entry.startCommand)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    HStack {
                        Button("Copy Start Command", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(entry.startCommand, forType: .string)
                        }
                        Button("Show Configuration", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.file])
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            if entries.isEmpty && errorMessage == nil {
                Text("No command-line VMs found.").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Command Line VMs")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { refreshID = UUID() }
        }
        .task(id: refreshID) {
            let path = directory
            do {
                let found = try await Task.detached {
                    try CLIInventoryEntry.read(directory: path)
                }.value
                guard !Task.isCancelled else { return }
                entries = found
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) {
            _ in refreshID = UUID()
        }
    }
}
