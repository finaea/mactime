import SwiftUI
import ServiceManagement

struct SettingsView: View {
    let store: Store

    @AppStorage(Settings.Key.trackingEnabled) private var trackingEnabled = true
    @AppStorage(Settings.Key.browserTrackingEnabled) private var browserTrackingEnabled = true
    @AppStorage(Settings.Key.captureFullURLs) private var captureFullURLs = false
    @AppStorage(Settings.Key.idleThresholdSeconds) private var idleThresholdSeconds = 300.0
    @AppStorage(Settings.Key.screenshotsEnabled) private var screenshotsEnabled = true
    @AppStorage(Settings.Key.screenshotIntervalSeconds) private var screenshotIntervalSeconds = 15.0
    @AppStorage(Settings.Key.screenshotRetentionDays) private var screenshotRetentionDays = 14
    @AppStorage(Settings.Key.screenshotQuality) private var screenshotQuality = 0.6
    @AppStorage(Settings.Key.showAllDisplays) private var showAllDisplays = false
    @AppStorage(Settings.Key.hoverPreviewOffsetX) private var hoverPreviewOffsetX = -8.0
    @AppStorage(Settings.Key.hoverPreviewOffsetY) private var hoverPreviewOffsetY = -8.0

    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var diskUsage: String = "…"

    @State private var eraseScope: EraseScope = .day
    @State private var eraseFrom = Calendar.current.startOfDay(for: Date())
    @State private var eraseTo = Calendar.current.startOfDay(for: Date())
    @State private var confirmingErase = false
    @State private var confirmTitle = ""
    @State private var confirmMessage = ""
    @State private var erasing = false
    @State private var eraseResult: String?

    var body: some View {
        Form {
            Section("Activity tracking") {
                Toggle("Track active application and window", isOn: $trackingEnabled)
                Toggle("Track browser tab URLs (Safari, Chrome, Firefox)", isOn: $browserTrackingEnabled)
                Picker("Record", selection: $captureFullURLs) {
                    Text("The site only (mail.google.com)").tag(false)
                    Text("The full URL, query string included").tag(true)
                }
                .disabled(!browserTrackingEnabled)
                Text("Query strings routinely carry session tokens, password-reset and sign-in links, and whatever you typed into a search box. \"Site only\" drops everything after the host at the moment of capture, so the rest is never written down in the first place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Picker("Show", selection: $showAllDisplays) {
                    Text("Active display only").tag(false)
                    Text("All displays, side by side").tag(true)
                }
                Text("Every display is always captured — this only changes how many are shown in the strip, hover preview and viewer. \"Active\" is the display that held the focused window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            deleteSection
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .task { await computeDiskUsage() }
        .confirmationDialog(confirmTitle, isPresented: $confirmingErase, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await performErase() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    // ------------------------------------------------------------- delete data

    /// What "Delete" is aimed at. Each resolves to a pair of timestamps, never
    /// to a day key — see `Store`'s erasure section for why that matters.
    private enum EraseScope: String, CaseIterable, Identifiable {
        case day = "A single day"
        case range = "A date range"
        case all = "Everything"
        var id: String { rawValue }
    }

    private var deleteSection: some View {
        Section("Delete data") {
            Picker("Delete", selection: $eraseScope) {
                ForEach(EraseScope.allCases) { Text($0.rawValue).tag($0) }
            }
            switch eraseScope {
            case .day:
                DatePicker("Day", selection: $eraseFrom, in: ...Date(),
                           displayedComponents: .date)
            case .range:
                DatePicker("From", selection: $eraseFrom, in: ...Date(),
                           displayedComponents: .date)
                DatePicker("To", selection: $eraseTo, in: ...Date(),
                           displayedComponents: .date)
            case .all:
                EmptyView()
            }

            Text(eraseScope == .all
                 ? "Removes every screenshot and the whole activity history — window titles and URLs included — and compacts the database so the deleted rows aren't left readable in it."
                 : "Removes the screenshots and the activity history — window titles and URLs — recorded in the selected days. An activity entry that runs across the edge of the range goes with it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                if erasing {
                    ProgressView().controlSize(.small)
                }
                Button("Delete…", role: .destructive) { confirmErase() }
                    .disabled(erasing)
            }
            if let eraseResult {
                Text(eraseResult).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Half-open [from, to) the current scope stands for; nil bounds mean
    /// unbounded, so "Everything" is nil/nil. The To picker names the last
    /// *included* day, matching the statistics range header.
    private var eraseRange: (from: Date?, to: Date?) {
        let cal = Calendar.current
        func endOf(_ d: Date) -> Date? { cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: d)) }
        switch eraseScope {
        case .all:
            return (nil, nil)
        case .day:
            return (cal.startOfDay(for: eraseFrom), endOf(eraseFrom))
        case .range:
            // Pickers dragged past each other shouldn't silently erase nothing.
            let lo = min(eraseFrom, eraseTo), hi = max(eraseFrom, eraseTo)
            return (cal.startOfDay(for: lo), endOf(hi))
        }
    }

    /// Count first, so the prompt names what will actually go rather than
    /// asking the user to confirm an unknown. The title says which days, the
    /// message says how much — "Everything" has to be unmistakably different
    /// from "this one day" at the moment of confirming.
    private func confirmErase() {
        let range = eraseRange
        let counts = store.counts(from: range.from, to: range.to)
        eraseResult = nil
        guard counts.screenshots + counts.spans > 0 else {
            eraseResult = "Nothing recorded in that range."
            return
        }
        switch eraseScope {
        case .all:
            confirmTitle = "Delete all MacTime data?"
        case .day:
            confirmTitle = "Delete everything recorded on \(Format.dayHeading.string(from: eraseFrom))?"
        case .range:
            let lo = min(eraseFrom, eraseTo), hi = max(eraseFrom, eraseTo)
            confirmTitle = "Delete everything recorded from \(Format.dayHeading.string(from: lo)) "
                + "to \(Format.dayHeading.string(from: hi))?"
        }
        confirmMessage = "\(counts.screenshots) screenshot\(counts.screenshots == 1 ? "" : "s") and "
            + "\(counts.spans) activity entr\(counts.spans == 1 ? "y" : "ies"), including window "
            + "titles and URLs. This can't be undone."
        confirmingErase = true
    }

    private func performErase() async {
        erasing = true
        let range = eraseRange
        let summary = await Erase.data(from: range.from, to: range.to, in: store)
        erasing = false
        eraseResult = summary.failedFiles == 0
            ? "Deleted \(summary.screenshots) screenshots and \(summary.spans) activity entries."
            : "Deleted \(summary.screenshots) screenshots and \(summary.spans) activity entries; "
                + "\(summary.failedFiles) files couldn't be removed."
        await computeDiskUsage()
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
