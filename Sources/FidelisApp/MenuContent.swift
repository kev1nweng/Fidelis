import SwiftUI
import ServiceManagement
import FidelisCore

/// The whole UI: a native menu, in the style of the system's own menu bar extras.
struct MenuContent: View {
    @EnvironmentObject private var engine: Engine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text(verbatim: statusLine)

        Toggle("LDAC Output", isOn: Binding(get: { engine.status.isActive }, set: { _ in engine.toggle() }))
            .disabled(!engine.apiAvailable || engine.selectedAddress == nil || engine.status == .stopping)

        Divider()

        Menu("Headphones") {
            if engine.headphones.isEmpty {
                Text("No Paired Headphones")
            } else {
                Picker("Headphones", selection: Binding(get: { engine.selectedAddress ?? "" }, set: { engine.selectedAddress = $0 })) {
                    ForEach(engine.headphones) { h in Text(verbatim: h.name).tag(h.address) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Button("Refresh") { engine.refreshDevices() }
        }
        .disabled(engine.status.isActive)

        Menu("Bitrate") {
            Picker("Bitrate", selection: $engine.quality) {
                ForEach(Engine.QualityChoice.allCases) { q in
                    switch q {
                    case .auto: Text("Auto (Recommended)").tag(q)
                    case .autoAggressive: Text("Auto (Aggressive)").tag(q)
                    default: Text("\(q.title) kbps").tag(q)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Toggle("High Connection Priority (Experimental)", isOn: $engine.highConnectionPriority)
        }

        Menu("Source") {
            Picker("Source", selection: $engine.source) {
                Text("System Audio").tag(Engine.SourceChoice.system)
                Text("Test Chime").tag(Engine.SourceChoice.chime)
                Text("Silence").tag(Engine.SourceChoice.silence)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            if engine.driverBusy {
                Text(engine.driverInstalled ? "Removing Audio Driver…" : "Installing Audio Driver…")
            } else if engine.driverInstalled {
                Button("Remove Audio Driver…") { changeDriver(remove: true) }
            } else {
                Button("Install Audio Driver…") { changeDriver(remove: false) }
            }
        }
        .disabled(engine.status.isActive)

        // macOS's own Bluetooth audio is off while streaming (MacBluetoothAudio).
        Toggle("Exclusive Mode", isOn: Binding(get: { engine.pausesMacAudio }, set: { engine.setPausesMacAudio($0) }))
            .disabled(engine.macAudioBusy || engine.status.isActive)

        Divider()

        Toggle("Launch at Login", isOn: Binding(get: { launchAtLogin }, set: { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                engine.log.warn("launch at login: \(error.localizedDescription)")
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }))

        Button("Copy Diagnostic Log") {
            let text = engine.log.recent
                .map { "\($0.date.formatted(.iso8601)) [\($0.level.rawValue)] \($0.text)" }
                .joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        Divider()

        Button("Quit Fidelis") { quit() }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        guard engine.apiAvailable else { return String(localized: "This version of macOS isn't supported") }
        switch engine.status {
        case .idle where engine.source == .system && !engine.driverInstalled:
            return String(localized: "Install the audio driver from the Source menu")
        case .idle:
            if let name = engine.headphones.first(where: { $0.address == engine.selectedAddress })?.name {
                return String(localized: "Off · \(name)")
            }
            return String(localized: "Off")
        case .connecting(let step): return step
        case .streaming:
            let kbps = engine.stats?.quality.kbps ?? 0
            if let rate = engine.negotiated?.sampleRate {
                let khz = (Double(rate) / 1000).formatted(.number.precision(.fractionLength(0...1)))
                return String(localized: "LDAC · \(kbps) kbps · \(khz) kHz")
            }
            return String(localized: "LDAC · \(kbps) kbps")
        case .recovering(let why): return String(localized: "Recovering: \(why)")
        case .stopping: return String(localized: "Handing back to macOS…")
        case .failed(let why): return String(localized: "Error: \(why)")
        }
    }

    private func changeDriver(remove: Bool) {
        let res = Bundle.main.bundleURL.appendingPathComponent("Contents")
        engine.changeDriver(script: res.appendingPathComponent("Resources/install-driver.sh").path,
                            bundledDriver: res.appendingPathComponent("Library/Audio/Plug-Ins/HAL/Fidelis.driver").path,
                            remove: remove)
    }

    /// The app delegate hands the headphones back before the app exits.
    private func quit() { NSApp.terminate(nil) }
}
