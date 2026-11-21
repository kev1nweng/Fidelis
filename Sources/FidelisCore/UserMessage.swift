import Foundation

/// An error that can explain itself to the user. `description` stays English for the log;
/// `userMessage` is localized for the menu.
public protocol UserFacingError: Error {
    var userMessage: String { get }
}

/// What the menu shows for an error.
public func userMessage(for error: Error) -> String {
    (error as? UserFacingError)?.userMessage ?? String(localized: "Something went wrong")
}

extension SessionError: UserFacingError {
    public var userMessage: String {
        switch self {
        case .privateAPIUnavailable: String(localized: "This version of macOS lacks the Bluetooth interfaces Fidelis needs")
        case .deviceNotFound: String(localized: "Headphones not found")
        case .takeoverFailed: String(localized: "Couldn't take the headphones over from macOS")
        case .noLDAC: String(localized: "These headphones don't support LDAC")
        case .unsupportedFormat: String(localized: "No LDAC format in common with these headphones")
        case .mediaChannel: String(localized: "Couldn't open the audio channel")
        case .signaling: String(localized: "The headphones stopped responding")
        case .headphonesInCall: String(localized: "The headphones' microphone is in use by a call; end the call or pick another microphone")
        case .cancelled: String(localized: "Stopped")
        }
    }
}

extension SystemAudioError: UserFacingError {
    public var userMessage: String {
        switch self {
        case .driverMissing: String(localized: "The audio driver isn't installed")
        case .driverRefused: String(localized: "The audio driver refused Fidelis; reinstall the driver")
        case .coreAudio(_, let status): String(localized: "Core Audio error (\(Int(status)))")
        }
    }
}
