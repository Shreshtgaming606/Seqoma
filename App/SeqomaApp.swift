import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor final class SeqomaModel: ObservableObject {
    @Published var selectedApp: URL?
    @Published var report: AnalysisReport?
    @Published var plan: RebuildPlan?
    @Published var rebuild: RebuildResult?
    @Published var test: TestResult?
    @Published var busy = false
    @Published var canCancel = false
    @Published var workTitle = ""
    @Published var workDetail = ""
    @Published var message = "Choose a Mac app to begin."
    @Published var planIssue: String?
    @Published var observationSeconds = 5.0
    @Published var sourceRecipe: SourceRecipe?
    @Published var sourceDirectory: URL?
    @Published var functionalityNotes = ""
    private var cancellation = CancellationToken()

    var appName: String { selectedApp?.deletingPathExtension().lastPathComponent ?? "app" }
    var destination: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Seqoma", isDirectory: true)
    }
    var plainReasons: [String] {
        guard let report else { return [] }
        var reasons: [String] = []
        if report.issues.contains(where: { $0.contains("no x86_64") || $0.contains("lacks x86_64") }) {
            reasons.append("This app does not include an Intel version for every required part.")
        }
        if report.issues.contains(where: { $0.contains("deployment target exceeds Sonoma") }) {
            reasons.append("Some parts of this app were built for a newer version of macOS.")
        }
        if report.issues.contains(where: { $0.contains("Missing absolute dependencies") }) {
            reasons.append("It needs system libraries that are unavailable on this Mac.")
        }
        if reasons.isEmpty && plan == nil { reasons.append("There is no tested rebuild method for this version yet.") }
        return reasons
    }

    func chooseApp() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.prompt = "Choose App"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.select(url) }
        }
    }

    func select(_ url: URL) {
        guard !busy else { return }
        guard url.pathExtension.lowercased() == "app" else {
            message = "Choose a Mac application ending in .app."
            return
        }
        selectedApp = url
        report = nil
        plan = nil
        rebuild = nil
        test = nil
        sourceRecipe = nil
        sourceDirectory = nil
        planIssue = nil
        message = "Checking \(appName)…"
        analyze()
    }

    func cancel() {
        cancellation.cancel()
        message = "Stopping after the current check…"
    }

    func analyze() {
        guard let app = selectedApp, !busy else { return }
        busy = true
        canCancel = true
        cancellation = CancellationToken()
        workTitle = "Checking \(appName)…"
        workDetail = "Seqoma is reading the app and choosing a safe rebuild method. This may take a few minutes."
        let token = cancellation
        let recipe = sourceRecipe
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let found = try Analyzer().analyze(app, cancelled: { token.isCancelled })
                var readyPlan: RebuildPlan?
                var planningError: String?
                do { readyPlan = try Rebuilder().plan(found, sourceRecipe: recipe) }
                catch { planningError = error.localizedDescription }
                if let database = try? CompatibilityDatabase(url: CompatibilityDatabase.defaultURL) {
                    try? database.save(found)
                }
                let finalPlan = readyPlan
                let finalPlanningError = planningError
                await MainActor.run {
                    self.report = found
                    self.plan = finalPlan
                    self.planIssue = finalPlanningError
                    self.busy = false
                    self.canCancel = false
                    self.message = finalPlan == nil
                        ? "Seqoma cannot safely rebuild this version yet."
                        : "Ready to rebuild a separate copy of \(self.appName)."
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.canCancel = false
                    self.message = error.localizedDescription
                }
            }
        }
    }

    func chooseSourceRecipe() {
        guard report != nil, !busy else { return }
        let filePanel = NSOpenPanel()
        filePanel.canChooseFiles = true
        filePanel.canChooseDirectories = false
        filePanel.allowedContentTypes = [.json]
        filePanel.prompt = "Choose Recipe"
        guard filePanel.runModal() == .OK, let recipeURL = filePanel.url else { return }
        let folderPanel = NSOpenPanel()
        folderPanel.canChooseDirectories = true
        folderPanel.canChooseFiles = false
        folderPanel.prompt = "Choose Source Folder"
        guard folderPanel.runModal() == .OK, let folder = folderPanel.url else { return }
        do {
            let recipe = try JSONFile.read(SourceRecipe.self, from: recipeURL)
            guard let report else { return }
            let plan = try Rebuilder().plan(report, sourceRecipe: recipe)
            sourceRecipe = recipe
            sourceDirectory = folder
            self.plan = plan
            planIssue = nil
            message = "Source recipe accepted. Ready to rebuild a copy."
        } catch {
            message = "This source recipe cannot rebuild the selected app."
            planIssue = error.localizedDescription
        }
    }

    func rebuildApp() {
        guard let report, let plan, !busy else { return }
        busy = true
        canCancel = true
        cancellation = CancellationToken()
        workTitle = "Rebuilding \(appName)…"
        workDetail = "Seqoma is making a separate copy, applying the supported method, and checking the result."
        message = workTitle
        let token = cancellation
        let source = sourceDirectory
        let recipe = sourceRecipe
        let destination = self.destination
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let result = try Rebuilder().rebuild(report, plan: plan, destination: destination,
                                                     sourceDirectory: source, recipe: recipe,
                                                     cancelled: { token.isCancelled })
                if let database = try? CompatibilityDatabase(url: CompatibilityDatabase.defaultURL) {
                    try? database.save(result, report: report)
                }
                await MainActor.run {
                    self.rebuild = result
                    self.test = nil
                    self.busy = false
                    self.canCancel = false
                    self.message = "Rebuilt copy saved. Test it before relying on it."
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.canCancel = false
                    self.message = error.localizedDescription
                }
            }
        }
    }

    func testApp() {
        guard let report, let rebuild, !busy else { return }
        busy = true
        canCancel = false
        workTitle = "Testing \(appName)…"
        workDetail = "Seqoma is opening the rebuilt copy and watching for an immediate crash."
        let seconds = observationSeconds
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let result = try ApplicationTester().test(URL(fileURLWithPath: rebuild.outputPath),
                                                          launch: true, observationSeconds: seconds)
                if let database = try? CompatibilityDatabase(url: CompatibilityDatabase.defaultURL) {
                    try? database.save(result, report: report)
                }
                await MainActor.run {
                    self.test = result
                    self.busy = false
                    self.message = result.launched
                        ? "The rebuilt app opened. Check its features yourself."
                        : "The rebuilt app did not open successfully."
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.message = error.localizedDescription
                }
            }
        }
    }

    func exportReport() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Seqoma-\(report.appName)-report.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONFile.write(report, to: url); message = "Report exported." }
        catch { message = error.localizedDescription }
    }

    func markFunctionality(_ status: CompatibilityStatus) {
        guard let previous = test, previous.launched, let report else { return }
        let updated = TestResult(date: Date(), appPath: previous.appPath,
                                 bundleValid: previous.bundleValid, architectureValid: previous.architectureValid,
                                 signatureValid: previous.signatureValid, missingDependencies: previous.missingDependencies,
                                 launched: previous.launched, remainedRunning: previous.remainedRunning,
                                 exitCode: previous.exitCode, status: status,
                                 diagnostic: previous.diagnostic + "\nUser notes: " + functionalityNotes)
        do {
            try CompatibilityDatabase(url: CompatibilityDatabase.defaultURL).save(updated, report: report)
            test = updated
            message = "Your functionality result was saved."
        } catch { message = error.localizedDescription }
    }
}

private enum SeqomaIcon {
    static let image: NSImage = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else {
            return NSApplication.shared.applicationIconImage
        }
        return icon
    }()
}

@main struct SeqomaApp: App {
    @StateObject private var model = SeqomaModel()
    @State private var isDropTarget = false
    @State private var showDetails = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        appCard
                        Button(action: model.rebuildApp) {
                            Label("Rebuild App", systemImage: "arrow.triangle.2.circlepath")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.plan == nil || model.busy)
                        Text(model.message).foregroundStyle(.secondary)
                        if let result = model.rebuild {
                            rebuiltCard(result)
                        } else if let report = model.report {
                            readinessCard(report)
                        }
                        if let test = model.test { testCard(test) }
                        if model.report != nil { technicalDetails }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: 740, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                if model.busy { loadingScreen }
            }
            .frame(minWidth: 620, minHeight: 540)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget) { providers in
                guard !model.busy, let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.select(url) } }
                }
                return true
            }
            .onAppear { NSApplication.shared.applicationIconImage = SeqomaIcon.image }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: SeqomaIcon.image).resizable().frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text("Seqoma").font(.largeTitle.bold())
                Text("Rebuild an app for macOS Sonoma").foregroundStyle(.secondary)
            }
        }
    }

    private var appCard: some View {
        HStack(spacing: 14) {
            if let selected = model.selectedApp {
                Image(nsImage: NSWorkspace.shared.icon(forFile: selected.path))
                    .resizable().frame(width: 52, height: 52)
            } else {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(model.selectedApp?.lastPathComponent ?? "Choose a Mac app")
                    .font(.headline)
                Text(model.selectedApp?.path ?? "Select an .app in Finder, or drag one into this window.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Choose App…") { model.chooseApp() }.disabled(model.busy)
        }
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(isDropTarget ? Color.accentColor : Color.clear, lineWidth: 2))
    }

    private func readinessCard(_ report: AnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(model.plan == nil ? "This version is not supported yet" : "Ready to rebuild a copy",
                  systemImage: model.plan == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.title3.bold())
                .foregroundStyle(model.plan == nil ? Color.orange : Color.green)
            if model.plan == nil {
                ForEach(model.plainReasons, id: \.self) { Text($0) }
                if report.bundleID == "com.bohemiancoding.sketch3" {
                    Text("Sketch provides older releases that support macOS Sonoma.")
                    Link("See compatible Sketch releases", destination: URL(string: "https://www.sketch.com/releases/mac/")!)
                }
                Text("Your original app has not been changed.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Seqoma found a supported method for \(report.appName). The rebuilt copy will be saved in your Applications/Seqoma folder.")
                Text("A rebuild still needs a real launch and feature test.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func rebuiltCard(_ result: RebuildResult) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Rebuilt copy is ready", systemImage: "checkmark.circle.fill")
                .font(.title3.bold()).foregroundStyle(.green)
            Text("Saved in Applications/Seqoma. Your original app is unchanged.")
            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.outputPath)])
                }
                Button("Test and Open App") { model.testApp() }
                    .buttonStyle(.borderedProminent)
            }
            Text("Opening the app is a separate test. It may still have features that do not work on Sonoma.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func testCard(_ test: TestResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(test.launched ? "App opened" : "App did not open",
                  systemImage: test.launched ? "checkmark.circle" : "xmark.circle")
                .font(.headline)
            Text(test.diagnostic).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var technicalDetails: some View {
        DisclosureGroup(isExpanded: $showDetails) {
            VStack(alignment: .leading, spacing: 10) {
                if let report = model.report {
                    LabeledContent("App version", value: report.version)
                    LabeledContent("Required macOS", value: report.declaredMinimum)
                    LabeledContent("Components checked", value: "\(report.binaries.count)")
                    ForEach(Array(report.issues.enumerated()), id: \.offset) { _, issue in
                        Text("• \(issue)").font(.caption)
                    }
                    if let issue = model.planIssue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button("Export Full Report…") { model.exportReport() }
                        Button("Use Rebuild Recipe…") { model.chooseSourceRecipe() }
                    }
                }
                HStack {
                    Text("App test duration")
                    Slider(value: $model.observationSeconds, in: 1...30, step: 1).frame(maxWidth: 160)
                    Text("\(Int(model.observationSeconds)) seconds")
                }
                if let test = model.test, test.launched {
                    TextField("Notes about what worked", text: $model.functionalityNotes)
                    HStack {
                        Button("Mark Basic Features Working") { model.markFunctionality(.basicFunctionalityVerified) }
                        Button("Mark Partly Working") { model.markFunctionality(.partiallyFunctional) }
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            Text("Technical details and options")
        }
    }

    private var loadingScreen: some View {
        ZStack {
            Color.black.opacity(0.38).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(model.workTitle).font(.title2.bold())
                Text(model.workDetail).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary).frame(maxWidth: 330)
                if model.canCancel { Button("Stop") { model.cancel() } }
            }
            .padding(32)
            .frame(width: 430)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 20)
        }
    }
}
