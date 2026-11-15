import SwiftUI
import AppKit

enum SonomaFallback {
    static func copyNote(_ note: String, pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(note, forType: .string)
    }
}

@main struct ControlledApp: App {
    @State private var note = "Seqoma controlled test"
    @State private var status = "Ready"
    init() {
        #if SEQOMA_SONOMA
        if CommandLine.arguments.contains("--seqoma-self-test") {
            let value = "Seqoma fallback verified"
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.seqoma.controlled.selftest"))
            let success = SonomaFallback.copyNote(value, pasteboard: pasteboard) && pasteboard.string(forType: .string) == value
            fputs(success ? "Sonoma fallback passed\n" : "Sonoma fallback failed\n", stdout)
            exit(success ? 0 : 1)
        }
        #endif
    }
    var body: some Scene {
        WindowGroup("Seqoma Controlled Test") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Controlled Compatibility Test").font(.title.bold())
                TextEditor(text: $note).frame(height: 120).border(.gray.opacity(0.4))
                Text("Text editing uses a macOS 14 API.").foregroundStyle(.secondary)
                Button("Use optional window feature") { optionalFeature() }
                Text(status).accessibilityIdentifier("featureStatus")
            }
            .padding(24).frame(width: 480, height: 300)
        }
    }
    private func optionalFeature() {
        #if SEQOMA_SONOMA
        status = SonomaFallback.copyNote(note) ? "Sonoma fallback: note copied to clipboard" : "Clipboard write failed"
        #elseif SEQOMA_STUB
        status = "Sequoia window sharing needs the macOS 15 SDK"
        #else
        Task {
            guard let window = NSApp.keyWindow else { status = "No window available"; return }
            do {
                try await window.requestSharingOfWindow(window)
                status = "Window sharing requested"
            } catch { status = "Window sharing failed: \(error.localizedDescription)" }
        }
        #endif
    }
}
