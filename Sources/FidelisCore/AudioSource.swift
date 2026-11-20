import Foundation

/// Supplies interleaved S16 stereo PCM to the media thread. `render` is called on a real-time
/// thread: no locks, no allocation, no Objective-C messaging.
public protocol AudioSource: AnyObject {
    var sampleRate: Int { get }
    func render(_ buffer: UnsafeMutablePointer<Int16>, frames: Int)
    /// Called when the stream had to skip ahead (for example after congestion).
    func didSkip(frames: Int)
}

public extension AudioSource {
    func didSkip(frames: Int) {}
}

public final class SilenceSource: AudioSource {
    public let sampleRate: Int
    public init(sampleRate: Int) { self.sampleRate = sampleRate }
    public func render(_ buffer: UnsafeMutablePointer<Int16>, frames: Int) {
        buffer.update(repeating: 0, count: frames * 2)
    }
}

/// A soft two-note chime (A4 then E5) every two seconds at −24 dBFS: enough to hear dropouts,
/// gentle enough to leave running.
public final class ChimeSource: AudioSource {
    public let sampleRate: Int
    private var t: Int = 0
    private let period: Int
    private let amplitude = 0.063   // −24 dBFS

    public init(sampleRate: Int) {
        self.sampleRate = sampleRate
        period = sampleRate * 2
    }

    public func render(_ buffer: UnsafeMutablePointer<Int16>, frames: Int) {
        let sr = Double(sampleRate)
        for i in 0..<frames {
            let pos = (t + i) % period
            let s = Double(pos) / sr
            var v = 0.0
            if s < 0.6 { v += sin(2 * .pi * 440 * s) * envelope(s, length: 0.6) }
            if s >= 0.3 && s < 0.9 { v += sin(2 * .pi * 659.26 * s) * envelope(s - 0.3, length: 0.6) }
            let sample = Int16(max(-1, min(1, v * amplitude)) * 32767)
            buffer[2 * i] = sample
            buffer[2 * i + 1] = sample
        }
        t = (t + frames) % period
    }

    public func didSkip(frames: Int) { t = (t + frames) % period }

    private func envelope(_ s: Double, length: Double) -> Double {
        let attack = 0.01
        if s < attack { return s / attack }
        return max(0, 1 - (s - attack) / (length - attack))
    }
}
