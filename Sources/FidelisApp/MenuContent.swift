import SwiftUI
import ServiceManagement
import FidelisCore

/// The whole UI: a native menu, in the style of the system's own menu bar extras.
struct MenuContent: View {
    @EnvironmentObject private var engine: Engine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text(statusLine)

        Toggle("LDAC 输出", isOn: Binding(get: { engine.status.isActive }, set: { _ in engine.toggle() }))
            .disabled(!engine.apiAvailable || engine.selectedAddress == nil || engine.status == .stopping)

        Divider()

        Menu("耳机") {
            if engine.headphones.isEmpty {
                Text("没有已配对的耳机")
            } else {
                Picker("耳机", selection: Binding(get: { engine.selectedAddress ?? "" }, set: { engine.selectedAddress = $0 })) {
                    ForEach(engine.headphones) { h in Text(h.name).tag(h.address) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Button("刷新") { engine.refreshDevices() }
        }
        .disabled(engine.status.isActive)

        Menu("码率") {
            Picker("码率", selection: $engine.quality) {
                ForEach(Engine.QualityChoice.allCases) { q in
                    Text(q == .auto ? "自动" : "\(q.title) kbps").tag(q)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }

        Menu("音源") {
            Picker("音源", selection: $engine.source) {
                Text("测试提示音").tag(Engine.SourceChoice.chime)
                Text("静音").tag(Engine.SourceChoice.silence)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Text("系统音频将在下一阶段加入")
        }
        .disabled(engine.status.isActive)

        Divider()

        Toggle("登录时启动", isOn: Binding(get: { launchAtLogin }, set: { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                engine.log.warn("launch at login: \(error.localizedDescription)")
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }))

        Button("拷贝诊断日志") {
            let text = engine.log.recent
                .map { "\($0.date.formatted(.iso8601)) [\($0.level.rawValue)] \($0.text)" }
                .joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        Divider()

        Button("退出 Fidelis") { quit() }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        guard engine.apiAvailable else { return "此 macOS 版本不受支持" }
        switch engine.status {
        case .idle:
            return engine.headphones.first(where: { $0.address == engine.selectedAddress }).map { "未启用 · \($0.name)" } ?? "未启用"
        case .connecting(let step): return step
        case .streaming:
            let kbps = engine.stats?.quality.kbps ?? 0
            let rate = engine.negotiated.map { String(format: " · %g kHz", Double($0.sampleRate) / 1000) } ?? ""
            return "LDAC · \(kbps) kbps\(rate)"
        case .recovering(let why): return "正在恢复：\(why)"
        case .stopping: return "正在交还给 macOS…"
        case .failed(let why): return "出错：\(why)"
        }
    }

    private func quit() {
        guard engine.status.isActive else { NSApp.terminate(nil); return }
        engine.stop()
        // Give the hand-back a moment so the headphones return to macOS.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
    }
}
