import SwiftUI

struct SettingsView: View {
    @AppStorage("defaultMemoryGB") private var defaultMemoryGB = 4
    @AppStorage("defaultVCPUs") private var defaultVCPUs = 2

    private let systemInfo = SystemInfo()

    var body: some View {
        GeneralSettingsView(
            defaultMemoryGB: $defaultMemoryGB,
            defaultVCPUs: $defaultVCPUs,
            systemInfo: systemInfo
        )
        .frame(
            minWidth: 500,
            idealWidth: 540,
            maxWidth: 640,
            minHeight: 300,
            idealHeight: 340,
            maxHeight: 500
        )
    }
}

private struct GeneralSettingsView: View {
    @Binding var defaultMemoryGB: Int
    @Binding var defaultVCPUs: Int
    let systemInfo: SystemInfo

    var body: some View {
        Form {
            Section {
                Picker("Default memory", selection: $defaultMemoryGB) {
                    ForEach(memoryOptions, id: \.self) { gb in
                        Text("\(gb) GB").tag(gb)
                    }
                }
                .pickerStyle(.menu)

                Picker("Default CPU cores", selection: $defaultVCPUs) {
                    ForEach(cpuOptions, id: \.self) { count in
                        Text(coreCountLabel(count)).tag(count)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("New Virtual Machines")
            } footer: {
                Text("These values are preselected when you create a virtual machine.")
            }

            Section("This Mac") {
                LabeledContent("Installed memory") {
                    Text("\(systemInfo.totalMemoryGB) GB")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("CPU cores") {
                    Text("\(systemInfo.cpuCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .contentMargins(.horizontal, 24, for: .scrollContent)
        .contentMargins(.vertical, 20, for: .scrollContent)
        .onAppear(perform: normalizeDefaults)
    }

    private var memoryOptions: [Int] {
        systemInfo.defaultMemoryOptionsGB
    }

    private var cpuOptions: [Int] {
        Array(1...systemInfo.cpuCount)
    }

    private func coreCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "core" : "cores")"
    }

    private func normalizeDefaults() {
        defaultMemoryGB = systemInfo.clampDefaultMemoryGB(defaultMemoryGB)
        defaultVCPUs = systemInfo.clampDefaultVCPUCount(defaultVCPUs)
    }
}

#Preview {
    SettingsView()
}
