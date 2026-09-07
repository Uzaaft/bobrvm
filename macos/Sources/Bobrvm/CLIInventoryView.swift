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

    private final class Collector {
        var entries: [CLIInventoryEntry] = []
    }

    static func read(directory: URL? = nil) throws -> [CLIInventoryEntry] {
        let collector = Collector()
        let receive: bobrvm_inventory_callback_f = { context, pointer in
            guard let context, let pointer else { return }
            let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
            let entry = pointer.pointee
            guard entry.source == 0 else { return }
            collector.entries.append(CLIInventoryEntry(
                name: String(cString: entry.name),
                file: URL(fileURLWithPath: String(cString: entry.config_path)),
                memoryMB: entry.memory_bytes / (1024 * 1024), cpuCount: entry.cpus,
                disk: entry.disk_path.map { String(cString: $0) },
                diskExists: entry.disk_status == 0 || entry.disk_status == 1
            ))
        }
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let code: bobrvm_error_e
        if let directory {
            code = directory.path.withCString {
                bobrvm_inventory_read($0, nil, receive, context)
            }
        } else {
            code = bobrvm_inventory_read(nil, nil, receive, context)
        }
        guard code.rawValue == BOBRVM_OK.rawValue else {
            throw BobrvmError(code: Int32(code.rawValue))
        }
        return collector.entries
    }
}

struct CLIInventoryView: View {
    let searchText: String
    @State private var entries: [CLIInventoryEntry] = []
    @State private var errorMessage: String?
    @State private var refreshID = UUID()

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
            do {
                let found = try await Task.detached {
                    try CLIInventoryEntry.read()
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
