import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers

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
    @AppStorage(Settings.Key.requireAuthentication) private var requireAuthentication = false
    @AppStorage(Settings.Key.showAllDisplays) private var showAllDisplays = false
    @AppStorage(Settings.Key.hoverPreviewOffsetX) private var hoverPreviewOffsetX = -8.0
    @AppStorage(Settings.Key.hoverPreviewOffsetY) private var hoverPreviewOffsetY = -8.0

    @State private var startAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var diskUsage: String = "…"

    /// Mirrors the defaults array, which `@AppStorage` can't bind. Written
    /// straight back through `Settings` on every edit, so the trackers pick a
    /// change up on their next tick without anything having to tell them.
    @State private var excludedBundleIDs = Array(Settings.excludedBundleIDs)
    @AppStorage(Settings.Key.excludedAppsReviewed) private var excludedAppsReviewed = false

    @State private var eraseScope: EraseScope = .day
    @State private var eraseFrom = Calendar.current.startOfDay(for: Date())
    @State private var eraseTo = Calendar.current.startOfDay(for: Date())
    @State private var confirmingErase = false
    @State private var confirmTitle = ""
    @State private var confirmMessage = ""
    @State private var erasing = false
    @State private var eraseResult: String?

    // ----------------------------------------------------------- backup
    @State private var lastExported: Date? = Settings.lastExportedAt
    /// Non-nil while an export or import is running; the string is what to show.
    @State private var busy: String?
    @State private var busyFraction: Double = 0
    @State private var cancelRequested = false
    @State private var backupResult: String?
    @State private var confirmingImport = false
    @State private var importTitle = ""
    @State private var importMessage = ""
    @State private var pendingImport: PendingImport?

    /// An archive the user picked, held between the confirmation and the work.
    struct PendingImport {
        let url: URL
        let preview: ArchiveImport.Preview
    }

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

            excludedAppsSection

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
                encryptionStatus
                appLock
            }

            backupSection
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
        .confirmationDialog(importTitle, isPresented: $confirmingImport, titleVisibility: .visible) {
            Button("Replace and Restart", role: .destructive) { Task { await performImport() } }
            Button("Cancel", role: .cancel) { pendingImport = nil }
        } message: {
            Text(importMessage)
        }
    }

    // ----------------------------------------------------------- backup

    private var backupSection: some View {
        Section("Backup") {
            Text("Export writes your whole history to a single zip — screenshots as JPEGs, "
                 + "activity as JSON. Import replaces everything on this Mac with the contents "
                 + "of one. Both ask for Touch ID or your password first.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Last exported", value: lastExportedDescription)

            // Said here rather than only at the save panel. MacTime has no
            // recovery code, so this export is the only copy of the history that
            // survives the login keychain going away — and the archive it writes
            // is unencrypted, which is the trade that buys the portability.
            Text(lastExported == nil
                 ? "MacTime's history can only be read on this Mac, with this Mac's keychain. An export is the only copy that survives losing either — and it is not encrypted, so keep it somewhere you trust."
                 : "An export is the only copy of your history that survives losing this Mac's keychain. Exports are not encrypted, so keep them somewhere you trust.")
                .font(.caption)
                .foregroundStyle(lastExportedIsStale ? .orange : .secondary)

            if let busy {
                HStack(spacing: 8) {
                    ProgressView(value: busyFraction).frame(width: 140)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { cancelRequested = true }
                        .controlSize(.small)
                        .disabled(cancelRequested)
                }
            } else {
                HStack {
                    Button("Export…") { beginExport() }
                    Button("Import…") { beginImport() }
                    Spacer()
                }
            }

            if let backupResult {
                Text(backupResult).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var lastExportedDescription: String {
        guard let lastExported else { return "Never" }
        let days = Calendar.current.dateComponents([.day], from: lastExported, to: Date()).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(days) days ago"
        }
    }

    /// Four weeks. Not a rule about how often anyone should export — just the
    /// point where "how much would a dead keychain cost me" stops being a
    /// rhetorical question.
    private var lastExportedIsStale: Bool {
        guard let lastExported else { return true }
        return Date().timeIntervalSince(lastExported) > 28 * 24 * 3600
    }

    /// Touch ID on the way out as well as in.
    ///
    /// Export only reads, but what it produces is every screenshot and window
    /// title in the clear in one file — the difference between someone at an
    /// unlocked Mac being able to *look* at the history and being able to *take*
    /// it. Deliberately not wired to `Settings.requireAuthentication`, which is
    /// off by default: a gate most users never turn on is not a gate.
    private func authenticated(_ reason: String, then work: @escaping () -> Void) {
        backupResult = nil
        AppLock.authenticate(reason: reason) { ok in
            guard ok else { return }
            work()
        }
    }

    private func beginExport() {
        authenticated("export your MacTime history") {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "MacTime-\(Format.dayKey.string(from: Date())).zip"
            panel.allowedContentTypes = [.zip]
            panel.message = "This archive is not encrypted. It holds every screenshot and "
                + "window title MacTime has recorded, readable by anything that opens it."
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                Task { await runExport(to: url) }
            }
        }
    }

    @MainActor
    private func runExport(to url: URL) async {
        busy = "Starting…"
        busyFraction = 0
        cancelRequested = false
        defer { busy = nil }
        do {
            let summary = try await ArchiveExport.run(
                store: store, to: url,
                progress: { fraction, label in
                    busyFraction = fraction
                    busy = label
                },
                isCancelled: { cancelRequested })
            lastExported = Settings.lastExportedAt
            let size = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
            backupResult = "Exported \(summary.captures) screenshots and "
                + "\(summary.spans) activity entries — \(size)."
        } catch {
            backupResult = message(for: error)
        }
    }

    private func beginImport() {
        authenticated("replace your MacTime history from a backup") {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.zip]
            panel.allowsMultipleSelection = false
            panel.message = "Choose a MacTime export. Everything currently recorded on this Mac "
                + "will be replaced."
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                prepareImport(from: url)
            }
        }
    }

    /// Read the archive's manifest and count both sides *before* asking.
    ///
    /// The same shape as `confirmErase`: the prompt names what will actually
    /// go and what will arrive, rather than asking someone to confirm an
    /// unknown. The restart is named too — an app that vanishes mid-operation
    /// without having said it would is indistinguishable from a crash.
    private func prepareImport(from url: URL) {
        do {
            let preview = try ArchiveImport.preview(url)
            let here = store.counts(from: nil, to: nil)
            pendingImport = PendingImport(url: url, preview: preview)
            importTitle = "Replace everything recorded on this Mac?"

            let arriving = "\(preview.manifest.captureCount) screenshots and "
                + "\(preview.manifest.spanCount) activity entries"
            let leaving = here.screenshots + here.spans == 0
                ? "Nothing is recorded here yet"
                : "This replaces \(here.screenshots) screenshots and \(here.spans) activity entries"
            let span = [preview.manifest.firstRecord, preview.manifest.lastRecord]
                .compactMap { $0 }
            let range = span.count == 2
                ? " recorded between \(Format.dayHeading.string(from: span[0])) and "
                    + "\(Format.dayHeading.string(from: span[1]))"
                : ""
            importMessage = "\(leaving). The archive holds \(arriving)\(range). "
                + "MacTime will restart to finish. This can't be undone."
            confirmingImport = true
        } catch {
            backupResult = message(for: error)
        }
    }

    @MainActor
    private func performImport() async {
        guard let pending = pendingImport else { return }
        pendingImport = nil
        busy = "Starting…"
        busyFraction = 0
        cancelRequested = false
        do {
            let staging = try await ArchiveImport.stage(
                store: store, from: pending.url, preview: pending.preview,
                progress: { fraction, label in
                    busyFraction = fraction
                    busy = label
                },
                isCancelled: { cancelRequested })
            busy = "Restarting MacTime…"
            busyFraction = 1
            // Everything up to here has been reversible. This is the line that
            // isn't: it swaps the directories and relaunches, so nothing below
            // it runs in this process.
            try (NSApp.delegate as? AppDelegate)?.commitImport(
                staging: staging, incoming: pending.preview.settings,
                expected: pending.preview.manifest)
        } catch {
            busy = nil
            backupResult = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // ----------------------------------------------------------- excluded apps

    private var excludedAppsSection: some View {
        Section("Excluded apps") {
            Text("These apps' windows are cut out of screenshots — whatever sits behind one is still captured — and their window titles and browser URLs are never recorded. The app itself still counts towards your totals.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(ExcludedApps.named(excludedBundleIDs)) { app in
                HStack {
                    if let icon = ExcludedApps.icon(for: app.bundleID) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                        Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") { removeExclusion(app.bundleID) }
                        .controlSize(.small)
                }
            }

            HStack {
                Menu("Add app…") {
                    ForEach(addableApps) { app in
                        Button(app.name) { addExclusion(app.bundleID) }
                    }
                    if !addableApps.isEmpty { Divider() }
                    Button("Choose from Applications…") { chooseAppToExclude() }
                }
                .fixedSize()
                Spacer()
                if excludedBundleIDs.isEmpty {
                    Text("Nothing excluded.").font(.caption).foregroundStyle(.secondary)
                }
            }

            suggestedExclusions
            exclusionLimits
        }
    }

    /// Running apps that aren't excluded yet. Running rather than installed
    /// because enumerating every app on the disk to fill a menu is a lot of work
    /// for a list the user is about to pick one item from — "Choose from
    /// Applications…" covers anything that isn't open at the moment.
    private var addableApps: [ExcludedApps.App] {
        let already = Set(excludedBundleIDs)
        return ExcludedApps.running().filter { !already.contains($0.bundleID) }
    }

    @ViewBuilder
    private var suggestedExclusions: some View {
        let suggestions = excludedAppsReviewed
            ? []
            : ExcludedApps.suggestions(alreadyExcluded: Set(excludedBundleIDs))
        if !suggestions.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("You have \(suggestions.map(\.name).formatted(.list(type: .and))) installed. Exclude them?")
                    .font(.caption)
                HStack {
                    Button("Exclude these") {
                        for app in suggestions { addExclusion(app.bundleID) }
                        excludedAppsReviewed = true
                    }
                    Button("No thanks") { excludedAppsReviewed = true }
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }

    /// Stated here rather than left to be discovered. Each one is a way the
    /// feature can look like it is working while something still gets through,
    /// and a user who reads "excluded" as "never on my disk" is owed the
    /// difference in the same place they turned it on.
    private var exclusionLimits: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What excluding an app does not do:")
            Text("• It doesn't remove anything already recorded — use Delete data below for that.")
            Text("• It can't stop the app's contents appearing in some other window: a notification banner, a screen-share preview, Mission Control.")
            Text("• A window opening in the moment between MacTime listing what's on screen and taking the shot can still land in that one frame.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func addExclusion(_ bundleID: String) {
        guard !excludedBundleIDs.contains(bundleID) else { return }
        excludedBundleIDs.append(bundleID)
        Settings.setExcludedBundleIDs(excludedBundleIDs)
    }

    private func removeExclusion(_ bundleID: String) {
        excludedBundleIDs.removeAll { $0 == bundleID }
        Settings.setExcludedBundleIDs(excludedBundleIDs)
    }

    private func chooseAppToExclude() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Exclude"
        panel.message = "Choose an app to leave out of screenshots and activity detail."
        guard panel.runModal() == .OK, let url = panel.url,
              let app = ExcludedApps.app(at: url) else { return }
        addExclusion(app.bundleID)
    }

    // ------------------------------------------------- encryption and locking

    /// Said in Settings and not only as a chip in the day view, because this is
    /// where someone goes to find out what is on their disk. It also quietly
    /// answers the question the Finder raises: the captures still end in `.jpg`
    /// and no longer open, because they aren't images any more.
    @ViewBuilder
    private var encryptionStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Screenshots, window titles and web addresses are encrypted on disk.",
                  systemImage: "lock.fill")
            Text("The key is kept in your login keychain rather than beside the data, so anything that reads this folder gets ciphertext. The screenshot files keep their .jpg names but are no longer images, which is why Finder can't preview them.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)

        if let why = Crypto.shared.unavailableReason {
            // Same words and the same orange as the day view's chip: a user who
            // has seen one and then comes looking here should find the problem
            // they already met, not a second one worded differently.
            VStack(alignment: .leading, spacing: 4) {
                Label("Data key unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                Text(why).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Kept next to the encryption line above precisely so the two can't be
    /// read as the same promise. One stops a person; the other stops a process.
    @ViewBuilder
    private var appLock: some View {
        Toggle("Require Touch ID or password to open MacTime", isOn: $requireAuthentication)
        Text("Asks before the MacTime window or these settings will open, so someone sitting at your unlocked Mac can't click the menu bar icon and scroll through your history. It stops a person using the app; it does nothing about a program reading the files, which is what the encryption above is for. Either way it never changes what is being recorded.")
            .font(.caption)
            .foregroundStyle(.secondary)
        if requireAuthentication && !AppLock.isAvailable {
            Text("This Mac has no login password set, so there is nothing for MacTime to check and it will open without asking.")
                .font(.caption)
                .foregroundStyle(.orange)
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
        if eraseScope == .all {
            // The one thing "everything" doesn't take, said at the moment of
            // confirming rather than left to be discovered in Keychain Access.
            // What the erase does remove is the key-*check* file, which is the
            // interlock that stops a launch minting a new key over data sealed
            // with one it can't reach — see `Erase.data`. Removing it is how a
            // user whose key went missing gets a working app back.
            confirmMessage += " Your encryption key stays in your keychain; MacTime carries on "
                + "with it for whatever you record next."
        }
        confirmingErase = true
    }

    private func performErase() async {
        erasing = true
        let range = eraseRange
        // The user asked for this one, named the range and confirmed a count, so
        // it takes both halves — unlike the retention sweep, which is on a timer
        // nobody confirms and takes captures only.
        let summary = await Erase.data(from: range.from, to: range.to, in: store,
                                       contents: .capturesAndActivity)
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
