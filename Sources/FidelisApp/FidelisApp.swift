import SwiftUI
import CoreBluetooth
import FidelisCore

@main
struct FidelisApp: App {
    @StateObject private var engine: Engine
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    private let bluetoothPermission = BluetoothPermission()

    init() {
        let engine = Engine(helperPath: FidelisApp.helperPath)
        _engine = StateObject(wrappedValue: engine)
        AppDelegate.engine = engine
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

/// Quitting (menu, ⌘Q, AppleScript, logout) first hands the headphones back and puts the
/// output back; otherwise they stay held by a helper and the output stays on Fidelis.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var engine: Engine?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine = Self.engine else { return .terminateNow }
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await engine.stopAndWait()
            reply()
        }
        // A hand-back that hangs must not keep the app from quitting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { reply() }
        return .terminateLater
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
        case .idle: Self.idleIcon
        case .connecting, .recovering, .stopping: Self.busyIcon
        case .streaming: Self.streamingIcon
        case .failed: Self.failedIcon
        }
    }

    // Made once: a new image on every render makes the status item redraw.
    private static let idleIcon = MenuBarIcon.image(.outline)
    private static let busyIcon = MenuBarIcon.image(.outline, alpha: 0.5)
    private static let streamingIcon = MenuBarIcon.image(.solid)
    private static let failedIcon = MenuBarIcon.image(.outline, alpha: 0.35)
}
