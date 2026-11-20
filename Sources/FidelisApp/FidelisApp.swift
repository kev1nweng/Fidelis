import SwiftUI
import CoreBluetooth
import FidelisCore

@main
struct FidelisApp: App {
    @StateObject private var engine: Engine
    private let bluetoothPermission = BluetoothPermission()

    init() {
        let engine = Engine(helperPath: FidelisApp.helperPath)
        _engine = StateObject(wrappedValue: engine)
        // Headless self-test: FIDELIS_SELFTEST=<seconds> streams to the selected headphones for
        // that long, then quits (used by scripts/selftest.sh).
        if let secs = ProcessInfo.processInfo.environment["FIDELIS_SELFTEST"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let e = engine
                if let addr = ProcessInfo.processInfo.environment["FIDELIS_DEVICE"] { e.selectedAddress = addr }
                if let src = ProcessInfo.processInfo.environment["FIDELIS_SOURCE"].flatMap(Engine.SourceChoice.init) { e.source = src }
                if let q = ProcessInfo.processInfo.environment["FIDELIS_QUALITY"].flatMap(Engine.QualityChoice.init) { e.quality = q }
                e.log.info("selftest: streaming for \(Int(secs)) s")
                e.start()
                Self.selftestWatch(e, until: Date().addingTimeInterval(secs + 90), streamFor: secs)
            }
        }
    }

    @MainActor
    private static func selftestWatch(_ e: Engine, until deadline: Date, streamFor secs: Double, since: Date? = nil) {
        var since = since
        if e.status == .streaming, since == nil { since = Date() }
        let finished = (since.map { Date().timeIntervalSince($0) >= secs } ?? false) || Date() > deadline
        if case .failed = e.status {
            e.log.error("selftest: FAILED")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(1) }
            return
        }
        if finished {
            e.log.info("selftest: done, stopping")
            e.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { exit(since == nil ? 1 : 0) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { selftestWatch(e, until: deadline, streamFor: secs, since: since) }
    }

    static var helperPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FidelisMediaHelper").path
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(engine)
        } label: {
            Image(nsImage: engine.status.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Creating a CBCentralManager is what asks the user for Bluetooth access on first launch.
final class BluetoothPermission: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager?
    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {}
}

extension Engine.Status {
    /// Outlined monogram when idle, dimmed while connecting, solid while streaming.
    var menuBarIcon: NSImage {
        switch self {
        case .idle: MenuBarIcon.image(.outline)
        case .connecting, .recovering, .stopping: MenuBarIcon.image(.outline, alpha: 0.5)
        case .streaming: MenuBarIcon.image(.solid)
        case .failed: MenuBarIcon.image(.outline, alpha: 0.35)
        }
    }
}
