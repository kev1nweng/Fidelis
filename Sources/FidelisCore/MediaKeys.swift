import Foundation

/// Passes the headphones' transport buttons on to whatever is playing. While Fidelis holds their
/// AVRCP channel the buttons reach us instead of macOS, so without this they would do nothing.
///
/// MediaRemote is private; it is looked up at run time, and its absence only costs the buttons.
enum MediaKeys {
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let send: SendCommand? = {
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let sym = dlsym(lib, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: SendCommand.self)
    }()

    /// Returns false when the command could not be sent.
    @discardableResult
    static func press(_ key: AVRCP.Key) -> Bool {
        // Headphones that do not track the player's state send PLAY for both directions, so
        // play and pause both toggle.
        let command: UInt32 = switch key {
        case .play, .pause: 2      // kMRTogglePlayPause
        case .stop: 3
        case .next: 4
        case .previous: 5
        }
        return send?(command, nil) ?? false
    }

    /// Pauses whatever is playing (never starts it, unlike the toggle).
    @discardableResult
    static func pause() -> Bool { send?(1, nil) ?? false }   // kMRPause
}
