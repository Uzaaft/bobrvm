import AppKit
import SwiftUI

struct VMLibraryHomeView: View {
    @EnvironmentObject private var vmManager: VMManager
    @Environment(\.openWindow) private var openWindow
    let searchText: String
    @Binding var selectedVMID: UUID?
    let showDetails: (VMInstance) -> Void

    @State private var startError: String?

    private let columns = [
        GridItem(.adaptive(minimum: 290, maximum: 380), spacing: 18)
    ]

    var body: some View {
        Group {
            if vmManager.vms.isEmpty {
                emptyLibrary
            } else if filteredVMs.isEmpty {
                ContentUnavailableView.search(text: searchText)
            } else {
                libraryGrid
            }
        }
        .navigationTitle("Library")
        .navigationSubtitle(librarySubtitle)
        .alert(
            "Unable to Start Virtual Machine",
            isPresented: startErrorPresented
        ) {
            Button("OK") { startError = nil }
        } message: {
            Text(startError ?? "An unknown error occurred.")
        }
    }

    private var libraryGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(filteredVMs) { vm in
                    VMLibraryCard(
                        vmInstance: vm,
                        isSelected: selectedVMID == vm.id,
                        select: { selectedVMID = vm.id },
                        showDetails: { showDetails(vm) },
                        open: { open(vm) },
                        pause: { vm.pause() },
                        stop: { vm.stop() },
                        edit: { vmManager.vmPendingEdit = vm }
                    )
                }
            }
            .padding(24)
        }
        .contentShape(Rectangle())
        .onTapGesture { selectedVMID = nil }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No Virtual Machines", systemImage: "shippingbox")
        } description: {
            Text("Create a virtual machine from an image or attach an existing disk.")
        } actions: {
            Button {
                vmManager.showingCreateVM = true
            } label: {
                Label("New Virtual Machine", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var filteredVMs: [VMInstance] {
        guard !searchText.isEmpty else { return vmManager.vms }
        return vmManager.vms.filter {
            $0.name.localizedStandardContains(searchText)
                || $0.guestSystem.displayName.localizedStandardContains(searchText)
        }
    }

    private var librarySubtitle: String {
        let count = vmManager.vms.count
        return count == 1 ? "1 virtual machine" : "\(count) virtual machines"
    }

    private var startErrorPresented: Binding<Bool> {
        Binding(
            get: { startError != nil },
            set: { if !$0 { startError = nil } }
        )
    }

    private func open(_ vm: VMInstance) {
        do {
            if vm.state == .stopped {
                try vm.start()
            } else if vm.state == .paused {
                vm.resume()
            }
            openWindow(id: "vm-display", value: vm.id)
        } catch {
            startError = error.localizedDescription
        }
    }
}

struct VMOverviewView: View {
    @ObservedObject var vmInstance: VMInstance
    @EnvironmentObject private var vmManager: VMManager
    @Environment(\.openWindow) private var openWindow
    @State private var startError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                overviewHeader
                detailsGrid
            }
            .padding(28)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle(vmInstance.name)
        .navigationSubtitle(vmInstance.guestSystem.displayName)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    vmManager.vmPendingEdit = vmInstance
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Virtual machine settings")
            }
            ToolbarSpacer(.fixed)
            ToolbarItemGroup(placement: .primaryAction) {
                lifecycleToolbarItems
            }
        }
        .alert(
            "Unable to Start Virtual Machine",
            isPresented: startErrorPresented
        ) {
            Button("OK") { startError = nil }
        } message: {
            Text(startError ?? "An unknown error occurred.")
        }
        .focusedSceneValue(\.vmID, vmInstance.id)
    }

    private var overviewHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            GuestSystemIcon(system: vmInstance.guestSystem, size: 72)

            VStack(alignment: .leading, spacing: 6) {
                Text(vmInstance.name)
                    .font(.largeTitle.weight(.semibold))
                    .lineLimit(2)
                HStack(spacing: 10) {
                    VMStateBadge(state: vmInstance.state)
                    Text("\(vmInstance.guestSystem.displayName) virtual machine")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var detailsGrid: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 18) {
            GridRow {
                DetailPanel(title: "Hardware", systemImage: "cpu") {
                    DetailRow(label: "Processors", value: "\(vmInstance.config.vcpuCount) cores")
                    DetailRow(label: "Memory", value: memoryText)
                    DetailRow(label: "Graphics", value: graphicsText)
                }
                DetailPanel(title: "Display", systemImage: "display") {
                    DetailRow(label: "Maximum resolution", value: displayText)
                    DetailRow(
                        label: "Retina",
                        value: vmInstance.retinaEnabled ? "Full resolution" : "Standard scale"
                    )
                    DetailRow(
                        label: "Network",
                        value: vmInstance.config.networkEnabled ? "Connected" : "Disconnected"
                    )
                }
            }

            GridRow {
                DetailPanel(title: "Storage", systemImage: "internaldrive") {
                    DetailRow(label: "Disk", value: diskText)
                    DetailRow(label: "Installation media", value: opticalDriveText)
                }
                DetailPanel(title: "Identity", systemImage: "info.circle") {
                    DetailRow(label: "Guest", value: vmInstance.guestSystem.displayName)
                    DetailRow(label: "Identifier", value: shortIdentifier)
                }
            }
        }
    }

    @ViewBuilder
    private var lifecycleToolbarItems: some View {
        switch vmInstance.state {
        case .stopped:
            Button(action: primaryAction) {
                Label("Start", systemImage: "play.fill")
            }
        case .paused:
            Button(action: primaryAction) {
                Label("Resume", systemImage: "play.fill")
            }
            Button(role: .destructive) {
                vmInstance.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        case .running:
            Button {
                openWindow(id: "vm-display", value: vmInstance.id)
            } label: {
                Label("Open Display", systemImage: "macwindow")
            }
            Button {
                vmInstance.pause()
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            Button(role: .destructive) {
                vmInstance.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        }
    }

    private var memoryText: String {
        let bytesPerGB = UInt64(1024 * 1024 * 1024)
        return "\(vmInstance.config.memoryBytes / bytesPerGB) GB"
    }

    private var graphicsText: String {
        if vmInstance.guestSystem == .macOS {
            return "Apple accelerated"
        }
        return "\(vmInstance.vramMB) MB shared memory"
    }

    private var displayText: String {
        "\(vmInstance.config.displayWidth) × \(vmInstance.config.displayHeight)"
    }

    private var diskText: String {
        guard let path = vmInstance.config.diskPath else { return "None" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        guard let size = DiskManager.sizeGB(path: path) else { return name }
        return "\(name) · \(size) GB"
    }

    private var opticalDriveText: String {
        if vmInstance.guestSystem == .macOS { return "Apple restore image" }
        guard let path = vmInstance.isoPath else { return "Empty" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var shortIdentifier: String {
        String(vmInstance.id.uuidString.prefix(8)).uppercased()
    }

    private var startErrorPresented: Binding<Bool> {
        Binding(
            get: { startError != nil },
            set: { if !$0 { startError = nil } }
        )
    }

    private func primaryAction() {
        do {
            if vmInstance.state == .stopped {
                try vmInstance.start()
            } else if vmInstance.state == .paused {
                vmInstance.resume()
            }
            openWindow(id: "vm-display", value: vmInstance.id)
        } catch {
            startError = error.localizedDescription
        }
    }
}

private struct VMLibraryCard: View {
    @ObservedObject var vmInstance: VMInstance
    let isSelected: Bool
    let select: () -> Void
    let showDetails: () -> Void
    let open: () -> Void
    let pause: () -> Void
    let stop: () -> Void
    let edit: () -> Void

    var body: some View {
        Button(action: handleActivation) {
            VStack(alignment: .leading, spacing: 16) {
                cardHeader
                Divider()
                metrics
                Spacer(minLength: 0)
                controls
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 224, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .contextMenu { contextMenuItems }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "Show Details", showDetails)
    }

    // SwiftUI's TapGesture(count: 2) never fires when layered on a Button,
    // so double-clicks are detected from AppKit's own click counting.
    private func handleActivation() {
        let event = NSApp.currentEvent
        if let event,
            event.type == .leftMouseUp || event.type == .leftMouseDown,
            event.clickCount >= 2
        {
            open()
        } else {
            select()
        }
    }

    private var cardHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            GuestSystemIcon(system: vmInstance.guestSystem, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(vmInstance.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(vmInstance.guestSystem.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VMStateBadge(state: vmInstance.state)
        }
    }

    private var metrics: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
            GridRow {
                MetricLabel(icon: "cpu", value: "\(vmInstance.config.vcpuCount) cores")
                MetricLabel(icon: "memorychip", value: memoryText)
            }
            GridRow {
                MetricLabel(icon: "internaldrive", value: diskText)
                MetricLabel(icon: "display", value: displayText)
            }
            GridRow {
                MetricLabel(icon: "opticaldisc", value: opticalDriveText)
                    .gridCellColumns(2)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button(action: edit) {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .help("Virtual machine settings")

            Spacer()

            if vmInstance.state == .running {
                Button(action: pause) {
                    Label("Pause", systemImage: "pause.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help("Pause")
            }

            if vmInstance.state != .stopped {
                Button(action: stop) {
                    Label("Stop", systemImage: "stop.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .help("Stop")
            }

            Button(action: open) {
                Label(primaryTitle, systemImage: primaryIcon)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button(primaryTitle, systemImage: primaryIcon, action: open)
        if vmInstance.state == .running {
            Button("Pause", systemImage: "pause.fill", action: pause)
        }
        if vmInstance.state != .stopped {
            Button("Stop", systemImage: "stop.fill", role: .destructive, action: stop)
        }
        Divider()
        if vmInstance.guestSystem != .macOS {
            ISOMediaActions(vmInstance: vmInstance)
            Divider()
        }
        Button("Show Details", systemImage: "sidebar.right", action: showDetails)
        Button("Settings…", systemImage: "gearshape", action: edit)
    }

    private var primaryTitle: String {
        switch vmInstance.state {
        case .stopped: return "Start"
        case .paused: return "Resume"
        case .running: return "Open"
        }
    }

    private var primaryIcon: String {
        vmInstance.state == .running ? "macwindow" : "play.fill"
    }

    private var memoryText: String {
        let bytesPerGB = UInt64(1024 * 1024 * 1024)
        return "\(vmInstance.config.memoryBytes / bytesPerGB) GB"
    }

    private var diskText: String {
        guard let path = vmInstance.config.diskPath,
            let size = DiskManager.sizeGB(path: path)
        else {
            return "No disk"
        }
        return "\(size) GB"
    }

    private var displayText: String {
        "\(vmInstance.config.displayWidth) × \(vmInstance.config.displayHeight)"
    }

    private var opticalDriveText: String {
        if vmInstance.guestSystem == .macOS { return "Apple Virtualization" }
        guard let path = vmInstance.isoPath else { return "CD/DVD: Empty" }
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

private struct DetailPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Divider()
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

private struct MetricLabel: View {
    let icon: String
    let value: String

    var body: some View {
        Label(value, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

struct VMStateBadge: View {
    let state: VMState

    var body: some View {
        Label {
            Text(state.presentationName)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: state.presentationIcon)
                .foregroundStyle(state.presentationColor)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.secondary.opacity(0.1), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(state.presentationColor.opacity(0.28))
        }
        .accessibilityLabel("Status: \(state.presentationName)")
    }
}

struct GuestSystemIcon: View {
    let system: GuestSystem
    let size: CGFloat

    var body: some View {
        Image(systemName: system.presentationIcon)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(system.presentationColor.gradient, in: .rect(cornerRadius: size * 0.24))
            .accessibilityHidden(true)
    }
}

extension GuestSystem {
    var presentationIcon: String {
        switch self {
        case .linux: return "terminal.fill"
        case .macOS: return "apple.logo"
        case .windows: return "rectangle.split.2x2.fill"
        }
    }

    var presentationColor: Color {
        switch self {
        case .linux: return .orange
        case .macOS: return .blue
        case .windows: return .indigo
        }
    }
}
