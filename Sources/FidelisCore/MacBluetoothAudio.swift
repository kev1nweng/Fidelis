import Foundation

/// macOS's own Bluetooth audio (A2DP), which Fidelis turns off while it streams.
///
/// bluetoothd checks each profile against the `com.apple.MobileBluetooth.debug` preferences
/// before it connects it ("Using override value 0 for service a2dp" in its log). With A2DP off,
/// it connects the headphones for calls only and never opens AVDTP signaling, so Fidelis opens
/// it on the link as it is, with no race to win. It applies to every device, so macOS plays to
/// no Bluetooth headphones until it is back on.
///
/// Changing it takes root and a bluetoothd restart (every Bluetooth connection drops for a few
/// seconds). scripts/bt-audio-helper.sh does both; scripts/install-bt-helper.sh installs it once,
/// root-owned, with a sudoers rule that lets this user run exactly its `off` and `on`.
public enum MacBluetoothAudio {
    static let domainPath = "/Library/Preferences/com.apple.MobileBluetooth.debug"
    public static let helperPath = "/Library/PrivilegedHelperTools/fidelis-bt-audio"

    /// True when macOS's own A2DP is off (by Fidelis or by hand).
    public static var isOff: Bool { isOff(in: currentSettings()) }
    /// True when macOS's AVRCP is off too, so Fidelis can hold it (the helper turns both off).
    public static var remoteControlIsOff: Bool { isOff(in: currentSettings(), service: "avrcp") }

    static func currentSettings() -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: domainPath + ".plist"),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return dict
    }

    /// bluetoothd reads a string ("FALSE"); a boolean is ignored.
    static func isOff(in prefs: [String: Any], service: String = "a2dp") -> Bool {
        let values = [(prefs[service] as? [String: Any])?["ServiceSettings"],
                      (prefs["ServiceSettings"] as? [String: Any])?[service]]
        return values.contains { ($0 as? String).map { ["FALSE", "NO", "0"].contains($0.uppercased()) } ?? false }
    }

    /// The helper is installed, is this version's (`source`), and sudo lets this user run it
    /// without a password.
    public static func helperReady(source: String? = nil) async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: helperPath) else { return false }
        if let source, !FileManager.default.contentsEqual(atPath: helperPath, andPath: source) { return false }
        return (try? await run("/usr/bin/sudo", ["-n", "-l", helperPath, "off"])) != nil
    }

    /// Turns it off or back on through the helper; true when it changed (bluetoothd restarted).
    @discardableResult
    public static func set(off: Bool) async throws -> Bool {
        try await run("/usr/bin/sudo", ["-n", helperPath, off ? "off" : "on"]).contains("changed")
    }

    /// Installs the helper for this user (asks for an administrator password), or removes it,
    /// which turns macOS's Bluetooth audio back on first.
    public static func changeHelper(installer: String, helperSource: String, remove: Bool) async throws -> String {
        try await run("/bin/bash", remove ? [installer, "-u"] : [installer, helperSource, NSUserName()])
    }

    /// Runs a tool and returns its output; throws with that output when it fails.
    private static func run(_ tool: String, _ args: [String]) async throws -> String {
        try await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw NSError(domain: "Fidelis", code: Int(p.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: out.isEmpty ? "exit \(p.terminationStatus)" : out])
            }
            return out
        }.value
    }
}
