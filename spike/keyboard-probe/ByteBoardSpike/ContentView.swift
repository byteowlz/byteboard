import SwiftUI

struct ContentView: View {
    @State private var report: ProbeReport?
    @State private var localCapture: String?

    var body: some View {
        NavigationStack {
            List {
                Section("Setup") {
                    Text("Settings, General, Keyboard, Keyboards, Add New Keyboard, byteboard, then enable Allow Full Access.")
                        .font(.footnote)
                    Text("Open the keyboard once, press the probe buttons, then pull refresh here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Last probe") {
                    if let report {
                        row("Writer", report.writer)
                        row("Mic status", report.micStatus)
                        row("Mic request", report.micRequestResult ?? "not attempted")
                        row("Capture test", report.captureResult ?? "not attempted")
                        row("Just-bash", report.justBashResult ?? "not attempted")
                        row("Agent model", report.agentModelResult ?? "not attempted")
                        row("Touch latency", report.touchLatency ?? "type, then open tools")
                        if let mb = report.justBashFootprintMB { row("Footprint after just-bash", String(format: "%.1f MB", mb)) }
                        row("Footprint at load", mb(report.footprintAtLoadMB))
                        row("Footprint with model", mb(report.footprintAfterModelMB))
                        row("App group", report.appGroupReachable ? "reachable" : "unreachable")
                        row("Updated", report.updatedAt.formatted(date: .omitted, time: .standard))
                    } else {
                        Text("No report yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let notes = report?.notes, !notes.isEmpty {
                    Section("Trace") {
                        ForEach(notes, id: \.self) { note in
                            Text(note).font(.caption.monospaced())
                        }
                    }
                }
                // Control: identical capture code, but running in the app rather
                // than the extension. Separates "extension cannot record" from
                // "this code cannot record".
                Section("Control: capture in the app") {
                    Button("Run capture here") {
                        Task { @MainActor in
                            localCapture = "running…"
                            localCapture = await CaptureProbe.capture()
                        }
                    }
                    if let localCapture {
                        Text(localCapture).font(.caption.monospaced())
                    }
                }
            }
            .navigationTitle("byteboard probe")
            .toolbar {
                Button("Refresh") { report = ProbeStore.read() }
            }
            .onAppear { report = ProbeStore.read() }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) { Text(value) }
    }

    private func mb(_ value: Double?) -> String {
        guard let value else { return "not measured" }
        return String(format: "%.1f MB", value)
    }
}
