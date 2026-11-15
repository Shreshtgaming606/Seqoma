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
    @Published var message = "Choose an application to begin."
    @Published var records: [[String: String]] = []
    @Published var observationSeconds = 5.0
    @Published var sourceRecipe: SourceRecipe?
    @Published var sourceDirectory: URL?
    @Published var functionalityNotes = ""
    private var cancellation = CancellationToken()

    func chooseApp() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.treatsFilePackagesAsDirectories = false
        panel.prompt = "Analyze Application"
        if panel.runModal() == .OK, let url = panel.url { select(url) }
    }
    func select(_ url: URL) {
        selectedApp = url; report = nil; plan = nil; rebuild = nil; test = nil; sourceRecipe = nil; sourceDirectory = nil
        message = "Ready to analyze \(url.lastPathComponent)."
        analyze()
    }
    func cancel() { cancellation.cancel(); message = "Cancelling after current inspection step…" }
    func analyze() {
        guard let app = selectedApp, !busy else { return }
        busy = true; cancellation = CancellationToken(); message = "Inspecting bundle and Mach-O files…"
        let token = cancellation
        Task.detached { [self] in
            do {
                let result = try Analyzer().analyze(app, cancelled: { token.isCancelled })
                let db = try CompatibilityDatabase(url: CompatibilityDatabase.defaultURL); try db.save(result)
                await MainActor.run { self.report = result; self.busy = false; self.message = "Analysis complete: \(result.classification.rawValue)."; self.refresh() }
            } catch { await MainActor.run { self.busy = false; self.message = error.localizedDescription } }
        }
    }
    func createPlan() {
        guard let report = report else { return }
        do { plan = try Rebuilder().plan(report, sourceRecipe: sourceRecipe); message = "Plan ready: \(plan!.strategy.rawValue)." }
        catch { message = error.localizedDescription }
    }
    func chooseSourceRecipe() {
        let filePanel = NSOpenPanel(); filePanel.canChooseFiles = true; filePanel.canChooseDirectories = false; filePanel.allowedContentTypes = [.json]; filePanel.prompt = "Choose Recipe"
        guard filePanel.runModal() == .OK, let recipeURL = filePanel.url else { return }
        let folderPanel = NSOpenPanel(); folderPanel.canChooseDirectories = true; folderPanel.canChooseFiles = false; folderPanel.prompt = "Choose Source Folder"
        guard folderPanel.runModal() == .OK, let folder = folderPanel.url else { return }
        do { sourceRecipe = try JSONFile.read(SourceRecipe.self, from: recipeURL); sourceDirectory = folder; plan = nil; message = "Source recipe selected. Create a plan to validate it." }
        catch { message = error.localizedDescription }
    }
    func rebuildApp() {
        guard let report = report, let plan = plan, !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Choose Destination"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true; cancellation = CancellationToken(); message = "Copying, rebuilding, and validating…"
        let token = cancellation
        let source = sourceDirectory
        let recipe = sourceRecipe
        Task.detached { [self] in
            do {
                let result = try Rebuilder().rebuild(report, plan: plan, destination: destination, sourceDirectory: source, recipe: recipe, cancelled: { token.isCancelled })
                let db = try CompatibilityDatabase(url: CompatibilityDatabase.defaultURL); try db.save(result, report: report)
                await MainActor.run { self.rebuild = result; self.busy = false; self.message = "Rebuilt copy saved. Runtime compatibility remains untested."; self.refresh() }
            } catch { await MainActor.run { self.busy = false; self.message = error.localizedDescription } }
        }
    }
    func testApp(launch: Bool) {
        guard let report = report, let rebuild = rebuild, !busy else { return }
        let seconds = observationSeconds
        busy = true; message = launch ? "Launching and observing…" : "Validating rebuilt bundle…"
        Task.detached { [self] in
            do {
                let result = try ApplicationTester().test(URL(fileURLWithPath: rebuild.outputPath), launch: launch, observationSeconds: seconds)
                let db = try CompatibilityDatabase(url: CompatibilityDatabase.defaultURL); try db.save(result, report: report)
                await MainActor.run { self.test = result; self.busy = false; self.message = result.diagnostic; self.refresh() }
            } catch { await MainActor.run { self.busy = false; self.message = error.localizedDescription } }
        }
    }
    func exportReport() {
        guard let report = report else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Seqoma-\(report.appName)-report.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try JSONFile.write(report, to: url); message = "Report exported." }
        catch { message = error.localizedDescription }
    }
    func markFunctionality(_ status: CompatibilityStatus) {
        guard let previous = test, previous.launched, let report = report else { return }
        let updated = TestResult(date: Date(), appPath: previous.appPath, bundleValid: previous.bundleValid, architectureValid: previous.architectureValid, signatureValid: previous.signatureValid, missingDependencies: previous.missingDependencies, launched: previous.launched, remainedRunning: previous.remainedRunning, exitCode: previous.exitCode, status: status, diagnostic: previous.diagnostic + "\nUser notes: " + functionalityNotes)
        do { try CompatibilityDatabase(url: CompatibilityDatabase.defaultURL).save(updated, report: report); test = updated; message = "Functionality result saved."; refresh() }
        catch { message = error.localizedDescription }
    }
    func refresh() {
        records = (try? CompatibilityDatabase(url: CompatibilityDatabase.defaultURL).list(limit: 100)) ?? []
    }
}

enum Section: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard", scanner = "Application Scanner", analyzer = "Compatibility Analyzer", manager = "Rebuild Manager", rebuilt = "Rebuilt Applications", diagnostics = "Testing & Diagnostics", settings = "Settings"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .dashboard: return "square.grid.2x2"
        case .scanner: return "doc.viewfinder"
        case .analyzer: return "waveform.path.ecg"
        case .manager: return "hammer"
        case .rebuilt: return "shippingbox"
        case .diagnostics: return "stethoscope"
        case .settings: return "gearshape"
        }
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
    @State private var section: Section? = .dashboard
    var body: some Scene {
        WindowGroup {
            NavigationSplitView {
                List(Section.allCases, selection: $section) { item in Label(item.rawValue, systemImage: item.icon).tag(item) }
                    .listStyle(.sidebar)
                    .navigationTitle("Seqoma")
            } detail: {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section?.rawValue ?? "Seqoma").font(.largeTitle.bold())
                            Text("macOS 15 → 14 · Intel").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Choose App", systemImage: "plus") { model.chooseApp() }.buttonStyle(.borderedProminent)
                    }
                    if model.busy { ProgressView(); Button("Cancel") { model.cancel() } }
                    Group { content }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    Text(model.message).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
                .padding(24)
                .frame(minWidth: 720, minHeight: 520)
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url = url { DispatchQueue.main.async { model.select(url) } } }
                    return true
                }
            }
            .onAppear {
                NSApplication.shared.applicationIconImage = SeqomaIcon.image
                model.refresh()
            }
        }
    }
    @ViewBuilder private var content: some View {
        switch section ?? .dashboard {
        case .dashboard:
            VStack(alignment: .leading, spacing: 16) {
                Text("Rebuild a copy for Sonoma").font(.title2.bold())
                Text("Seqoma inspects every Mach-O file and refuses unsupported binary targets. Successful rebuilding still needs a launch and functionality test.").foregroundStyle(.secondary)
                appSummary
                HStack { Button("Analyze") { model.analyze() }.disabled(model.selectedApp == nil || model.busy); Button("View Report") { section = .analyzer }.disabled(model.report == nil) }
                Spacer()
            }
        case .scanner:
            VStack(alignment: .leading, spacing: 12) { appSummary; Button("Scan Application") { model.analyze() }.disabled(model.selectedApp == nil || model.busy); if let r = model.report { Text("\(r.binaries.count) Mach-O files found"); Text("Main SHA-256: \(r.originalMainSHA256)").font(.caption.monospaced()).textSelection(.enabled) }; Spacer() }
        case .analyzer:
            ScrollView { VStack(alignment: .leading, spacing: 12) {
                if let r = model.report {
                    LabeledContent("Classification", value: r.classification.rawValue)
                    LabeledContent("Declared minimum", value: r.declaredMinimum)
                    LabeledContent("Bundle ID", value: r.bundleID)
                    LabeledContent("Version", value: r.version)
                    LabeledContent("Signature valid", value: r.originalSignatureValid ? "Yes" : "No")
                    LabeledContent("Hardened runtime", value: r.hardenedRuntime ? "Yes" : "No")
                    LabeledContent("Estimated confidence", value: "\(Int(r.confidence * 100))%")
                    Divider(); Text("Issues").font(.headline)
                    ForEach(r.issues.isEmpty ? ["No blocking issue found by static inspection."] : r.issues, id: \.self) { Text("• \($0)") }
                    Text("Limitations").font(.headline)
                    ForEach(r.limitations, id: \.self) { Text("• \($0)") }
                    Text("Binaries").font(.headline)
                    ForEach(r.binaries, id: \.path) { b in VStack(alignment: .leading) { Text(b.path).font(.system(.body, design: .monospaced)); Text("\(b.architectures.joined(separator: ", ")) · target \(b.deploymentTargets.joined(separator: ", ")) · \(b.dependencies.count) libraries · \(b.imports.count) imports").font(.caption).foregroundStyle(.secondary) }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) }
                    Button("Export JSON Report") { model.exportReport() }
                } else { Text("Analyze an app to see its report.").foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading) }
        case .manager:
            VStack(alignment: .leading, spacing: 14) {
                appSummary
                HStack { Button("Create Rebuild Plan") { model.createPlan() }.disabled(model.report == nil || model.busy); Button("Choose Source Recipe…") { model.chooseSourceRecipe() }.disabled(model.report == nil || model.busy) }
                if let p = model.plan { Text("Strategy: \(p.strategy.rawValue)").font(.headline); ForEach(p.modifications, id: \.self) { Text("• \($0)") }; ForEach(p.limitations, id: \.self) { Text("⚠︎ \($0)") }.foregroundStyle(.secondary); Button("Rebuild Copy…") { model.rebuildApp() }.buttonStyle(.borderedProminent).disabled(model.busy) }
                if let recipe = model.sourceRecipe { Text("Selected source recipe: \(recipe.id)").font(.footnote).foregroundStyle(.secondary) }
                Spacer()
            }
        case .rebuilt:
            VStack(alignment: .leading, spacing: 12) { if let r = model.rebuild { Text(r.outputPath).textSelection(.enabled); Text("Status: \(r.status.rawValue)"); Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.outputPath)]) } }; Divider(); Text("Recent records").font(.headline); List(model.records, id: \.self) { row in VStack(alignment: .leading) { Text("\(row["appName"] ?? "") · \(row["kind"] ?? "")"); Text("\(row["status"] ?? "") · \(row["date"] ?? "")").font(.caption).foregroundStyle(.secondary) } } }
        case .diagnostics:
            VStack(alignment: .leading, spacing: 14) { if let r = model.rebuild { Text(r.outputPath).textSelection(.enabled); HStack { Button("Validate Bundle") { model.testApp(launch: false) }; Button("Launch & Observe") { model.testApp(launch: true) }.buttonStyle(.borderedProminent) }.disabled(model.busy); if let t = model.test { Text("Status: \(t.status.rawValue)").font(.headline); Text(t.diagnostic); Text("Signature: \(t.signatureValid ? "valid" : "invalid")"); if t.launched { TextField("Functionality notes", text: $model.functionalityNotes); HStack { Button("Verified Basic Functionality") { model.markFunctionality(.basicFunctionalityVerified) }; Button("Partially Functional") { model.markFunctionality(.partiallyFunctional) } } } } } else { Text("Rebuild an app first.").foregroundStyle(.secondary) }; Spacer() }
        case .settings:
            Form { Text("Enabled profile: macOS 15 → 14, x86_64"); HStack { Text("Startup observation"); Slider(value: $model.observationSeconds, in: 1...30, step: 1); Text("\(Int(model.observationSeconds)) s") }; Text("Other compatibility profiles are disabled until implemented.").foregroundStyle(.secondary) }.frame(maxWidth: 480)
        }
    }
    private var appSummary: some View {
        HStack(spacing: 12) { Image(nsImage: SeqomaIcon.image).resizable().frame(width: 44, height: 44); VStack(alignment: .leading) { Text(model.selectedApp?.lastPathComponent ?? "No application selected").font(.headline); Text(model.selectedApp?.path ?? "Drop an .app here or choose one in Finder").font(.caption).foregroundStyle(.secondary).lineLimit(2) }; Spacer() }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}
