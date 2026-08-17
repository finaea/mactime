import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let store: Store

    @AppStorage(Settings.Key.trackingEnabled) private var trackingEnabled = true
    @AppStorage(Settings.Key.browserTrackingEnabled) private var browserTrackingEnabled = true
    @AppStorage(Settings.Key.idleThresholdSeconds) private var idleThresholdSeconds = 300.0
    @AppStorage(Settings.Key.screenshotsEnabled) private var screenshotsEnabled = true
    @AppStorage(Settings.Key.screenshotIntervalSeconds) private var screenshotIntervalSeconds = 15.0
    @AppStorage(Settings.Key.screenshotRetentionDays) private var screenshotRetentionDays = 14
    @AppStorage(Settings.Key.screenshotQuality) private var screenshotQuality = 0.6
    @AppStorage(Settings.Key.hoverPreviewOffsetX) private var hoverPreviewOffsetX = -8.0
    @AppStorage(Settings.Key.hoverPreviewOffsetY) private var hoverPreviewOffsetY = -8.0

    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var diskUsage: String = "…"

    var body: some View {
        Form {
            Section("Activity tracking") {
                Toggle("Track active application and window", isOn: $trackingEnabled)
                Toggle("Track browser tab URLs (Safari, Chrome, Firefox)", isOn: $browserTrackingEnabled)
                Picker("Away after idle", selection: $idleThresholdSeconds) {
                    Text("1 minute").tag(60.0)
                    Text("3 minutes").tag(180.0)
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                }
            }

            Section("Screenshots") {
                Toggle("Capture screenshots", isOn: $screenshotsEnabled)
                Picker("Interval", selection: $screenshotIntervalSeconds) {
                    Text("10 seconds").tag(10.0)
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                }
                Picker("Keep for", selection: $screenshotRetentionDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                Picker("JPEG quality", selection: $screenshotQuality) {
                    Text("Low (smaller files)").tag(0.4)
                    Text("Medium").tag(0.6)
                    Text("High").tag(0.8)
                }
            }

            Section("Timeline hover preview") {
                offsetRow("Offset X", value: $hoverPreviewOffsetX)
                offsetRow("Offset Y", value: $hoverPreviewOffsetY)
                HStack {
                    Button("Reset to default") {
                        hoverPreviewOffsetX = -8
                        hoverPreviewOffsetY = -8
                    }
                    Spacer()
                }
                Text("Position of the preview's bottom-right corner relative to the cursor. "
                     + "Negative values sit left of / above the pointer; -8, -8 is tight to the top-left. "
                     + "Near a boundary the preview stops at the edge of the timeline pane.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Start at login", isOn: $startAtLogin)
                    .onChange(of: startAtLogin) { applyLoginItem() }
                if let loginItemError {
                    Text(loginItemError).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Permissions") {
                permissionRow("Screen Recording (screenshots)",
                              granted: CGPreflightScreenCaptureAccess(),
                              pane: "Privacy_ScreenCapture")
                permissionRow("Accessibility (window titles)",
                              granted: AX.trusted,
                              pane: "Privacy_Accessibility")
                permissionRow("Automation (browser URLs)",
                              granted: nil,
                              pane: "Privacy_Automation")
            }

            Section("Data") {
                LabeledContent("Location") {
                    Text(store.dataDir.path)
                        .font(.caption)
                        .textSelection(.enabled)
                }
                LabeledContent("Screenshots on disk", value: diskUsage)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.dataDir])
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .task { await computeDiskUsage() }
    }

    /// Typed field plus a stepper — nudging by 4pt while watching the preview
    /// beats guessing a number.
    private func offsetRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .multilineTextAlignment(.trailing)
            Stepper("", value: value, in: -4000...4000, step: 4)
                .labelsHidden()
            Text("pt").foregroundStyle(.secondary)
        }
    }

    private func permissionRow(_ label: String, granted: Bool?, pane: String) -> some View {
        HStack {
            if let granted {
                Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
            }
            Text(label)
            Spacer()
            Button("Open Settings") {
                let url = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
                if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            }
            .controlSize(.small)
        }
    }

    private func applyLoginItem() {
        do {
            if startAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn't update login item: \(error.localizedDescription). " +
                "The app must be in /Applications for this to stick."
            startAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func computeDiskUsage() async {
        let dir = store.screenshotsDir
        let count = store.screenshotCount()
        let usage: String = await Task.detached(priority: .utility) {
            var bytes: Int64 = 0
            if let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in walker {
                    bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                }
            }
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }.value
        diskUsage = "\(usage)  (\(count) captures)"
    }
}
