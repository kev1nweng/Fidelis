import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// The Fidelis output device that the driver (Driver/) adds, and the system's default output.
public enum FidelisAudioDevice {
    public static let uid = "dev.fidelis.device"
    /// Custom driver property 'fdau': the audio played to the device, from a sample time on.
    static let audioSelector: AudioObjectPropertySelector = 0x6664_6175
    /// Custom driver property 'fdlu': output presentation latency in µs.
    static let latencySelector: AudioObjectPropertySelector = 0x6664_6c75
    /// 'fdhw': 1 while the headphones' own volume follows the slider (the driver then leaves the
    /// samples unscaled).
    static let hardwareVolumeSelector: AudioObjectPropertySelector = 0x6664_6877
    public static let installedDriverPath = "/Library/Audio/Plug-Ins/HAL/Fidelis.driver"

    public static var isDriverInstalled: Bool { FileManager.default.fileExists(atPath: installedDriverPath) }

    /// The device's object ID, or nil when the driver isn't loaded.
    public static var id: AudioObjectID? { deviceID(uid: uid) }

    public static func deviceID(uid: String) -> AudioObjectID? {
        var address = globalAddress(kAudioHardwarePropertyTranslateUIDToDevice)
        var qualifier = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    public static func uid(of device: AudioObjectID) -> String? {
        var address = globalAddress(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    public static var defaultOutput: AudioObjectID? {
        get {
            var address = globalAddress(kAudioHardwarePropertyDefaultOutputDevice)
            var device = AudioObjectID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
            return status == noErr && device != kAudioObjectUnknown ? device : nil
        }
    }

    @discardableResult
    public static func setDefaultOutput(_ device: AudioObjectID) -> Bool {
        var ok = true
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var address = globalAddress(selector)
            var value = device
            ok = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                            UInt32(MemoryLayout<AudioObjectID>.size), &value) == noErr && ok
        }
        return ok
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        var address = globalAddress(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr ? rate : nil
    }

    static func setNominalSampleRate(_ device: AudioObjectID, _ rate: Double) -> OSStatus {
        var address = globalAddress(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &value)
    }

    /// Tells the driver how far behind real time the headphones play, so it reports it as the
    /// device's latency and video players keep lip sync.
    static func setPresentationLatency(_ device: AudioObjectID, microseconds: Int) -> OSStatus {
        var address = globalAddress(latencySelector)
        var value: CFPropertyList = NSNumber(value: Int32(clamping: microseconds))
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), $0)
        }
    }

    static func setHardwareVolume(_ device: AudioObjectID, _ on: Bool) -> OSStatus {
        var address = globalAddress(hardwareVolumeSelector)
        var value: CFPropertyList = NSNumber(value: Int32(on ? 1 : 0))
        return withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<CFPropertyList>.size), $0)
        }
    }

    /// The device's volume slider, 0…1, as macOS shows it.
    static let volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)

    static func volume(_ device: AudioObjectID) -> Float? {
        var address = volumeAddress
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &v) == noErr ? v : nil
    }

    @discardableResult
    static func setVolume(_ device: AudioObjectID, _ value: Float) -> Bool {
        var address = volumeAddress
        var v = Float32(min(max(value, 0), 1))
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    /// Whether any process is playing on the device.
    static func isRunning(_ device: AudioObjectID) -> Bool {
        var address = globalAddress(kAudioDevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    /// Whether something records from the headphones' microphone: a call or meeting. That
    /// holds them in the hands-free profile, and macOS then takes the link straight back from
    /// any takeover (measured 2026-11-20: an active SCO link, every attempt lost).
    /// `address` is the Bluetooth address as Fidelis lists it ("91-5E-99-C9-D5-AE").
    public static func microphoneInUse(address: String) -> Bool {
        let prefix = address.uppercased().replacingOccurrences(of: ":", with: "-") + ":"
        return allDevices().contains { id in
            guard let uid = uid(of: id), uid.uppercased().hasPrefix(prefix), hasStreams(id, kAudioObjectPropertyScopeInput) else { return false }
            return isRunning(id)
        }
    }

    static func allDevices() -> [AudioObjectID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func hasStreams(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}

public enum SystemAudioError: Error, CustomStringConvertible {
    case driverMissing
    case driverRefused
    case coreAudio(String, OSStatus)

    public var description: String {
        switch self {
        case .driverMissing: "The Fidelis audio driver isn't installed (or coreaudiod hasn't loaded it)"
        case .driverRefused: "The Fidelis audio driver refused this app (signature mismatch)"
        case .coreAudio(let what, let status): "\(what) failed (\(status))"
        }
    }
}

/// Single-producer single-consumer ring of interleaved stereo Float32 frames. The consumer runs
/// on the real-time media thread, so neither side ever locks or allocates.
final class FrameFIFO: @unchecked Sendable {
    let capacity: Int               // frames, a power of two
    private let buffer: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)  // frames ever written (producer-owned)
    private let read = Atomic<Int>(0)     // frames ever read (consumer-owned)

    init(capacityFrames: Int) {
        var c = 1
        while c < capacityFrames { c <<= 1 }
        capacity = c
        buffer = .allocate(capacity: c * 2)
        buffer.initialize(repeating: 0, count: c * 2)
    }

    deinit { buffer.deallocate() }

    var level: Int { written.load(ordering: .acquiring) - read.load(ordering: .relaxed) }

    /// Producer. Returns how many frames fit; the rest are dropped.
    @discardableResult
    func write(_ samples: UnsafeBufferPointer<Float>) -> Int {
        let w = written.load(ordering: .relaxed)
        let space = capacity - (w - read.load(ordering: .acquiring))
        let n = min(space, samples.count / 2)
        for i in 0..<n {
            let slot = (w + i) & (capacity - 1)
            buffer[2 * slot] = samples[2 * i]
            buffer[2 * slot + 1] = samples[2 * i + 1]
        }
        written.store(w + n, ordering: .releasing)
        return n
    }

    /// Consumer. Copies up to `frames` frames; returns how many.
    func read(into out: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        let r = read.load(ordering: .relaxed)
        let n = min(frames, written.load(ordering: .acquiring) - r)
        for i in 0..<n {
            let slot = (r + i) & (capacity - 1)
            out[2 * i] = buffer[2 * slot]
            out[2 * i + 1] = buffer[2 * slot + 1]
        }
        read.store(r + n, ordering: .releasing)
        return n
    }

    /// Consumer. Drops `frames` frames (at most what is there).
    func discard(_ frames: Int) {
        let r = read.load(ordering: .relaxed)
        let n = min(frames, written.load(ordering: .acquiring) - r)
        read.store(r + n, ordering: .releasing)
    }
}

/// Plays what macOS sends to the Fidelis output device.
///
/// The driver keeps the device's mixed output in a ring indexed by device sample time and hands
/// it to this app through the custom property 'fdau' (the approach of the Sendspin driver it is
/// adapted from). A silent IOProc keeps the device running so its timeline never stops; a
/// poller copies new frames into a FIFO; the media thread drains the FIFO at the LDAC rate.
///
/// The device runs on the host clock (libASPL's zero timestamps are host time at the nominal
/// rate), and so does MediaStreamer's pacing, so the FIFO level holds steady. It still guards
/// both ways: it refills after an underrun and drops back to its target after a backlog.
public final class SystemAudioSource: AudioSource, @unchecked Sendable {
    public let sampleRate: Int
    /// Frames the FIFO aims to hold: poll interval plus the HAL's IO cycle, with margin.
    public let targetFrames: Int
    private var highFrames: Int { targetFrames + sampleRate * 60 / 1000 }

    private let log: Log
    private let fifo: FrameFIFO
    private let queue = DispatchQueue(label: "fidelis.system-audio", qos: .userInteractive)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private var timer: DispatchSourceTimer?
    private var activity: NSObjectProtocol?

    // Poller state (on `queue`).
    private var cursor: Int64 = -1
    private var session: Int64 = -1
    private var failedReads = 0
    private var rateWarned = false
    private var lastReport = (underruns: 0, drops: 0)
    private var pollCount = 0

    // Media-thread state.
    private var priming = true

    // Counters, read for diagnostics.
    private let underruns = Atomic<Int>(0)
    private let drops = Atomic<Int>(0)

    public init(sampleRate: Int, targetMs: Int = 40, log: Log) {
        self.sampleRate = sampleRate
        self.log = log
        targetFrames = sampleRate * targetMs / 1000
        fifo = FrameFIFO(capacityFrames: sampleRate)   // one second
    }

    /// Delay from a sample reaching the device to it leaving us: the FIFO's target level.
    public var bufferedMicroseconds: Int { targetFrames * 1_000_000 / sampleRate }

    public func start() throws {
        guard let id = FidelisAudioDevice.id else { throw SystemAudioError.driverMissing }
        device = id
        var address = FidelisAudioDevice.globalAddress(FidelisAudioDevice.audioSelector)
        guard AudioObjectHasProperty(id, &address) else { throw SystemAudioError.driverMissing }

        if FidelisAudioDevice.nominalSampleRate(id) != Double(sampleRate) {
            let st = FidelisAudioDevice.setNominalSampleRate(id, Double(sampleRate))
            if st != noErr { log.warn("system audio: could not set the device to \(sampleRate) Hz (\(st))") }
        }
        // Fails here, not silently later, when the driver won't hand this process its audio.
        _ = try readDriver(from: -1)

        var proc: AudioDeviceIOProcID?
        var st = AudioDeviceCreateIOProcIDWithBlock(&proc, id, nil) { _, _, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        guard st == noErr, let proc else { throw SystemAudioError.coreAudio("AudioDeviceCreateIOProcID", st) }
        ioProc = proc
        st = AudioDeviceStart(id, proc)
        guard st == noErr else { stop(); throw SystemAudioError.coreAudio("AudioDeviceStart", st) }

        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Streaming system audio")
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
        log.info("system audio: reading the Fidelis device at \(sampleRate) Hz, \(targetFrames * 1000 / sampleRate) ms buffer")
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        queue.sync {}
        if let ioProc {
            AudioDeviceStop(device, ioProc)
            AudioDeviceDestroyIOProcID(device, ioProc)
            self.ioProc = nil
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        let u = underruns.load(ordering: .relaxed), d = drops.load(ordering: .relaxed)
        if u + d > 0 { log.info("system audio: \(u) underruns, \(d) backlog drops") }
    }

    // MARK: Media thread

    public func render(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        let level = fifo.level
        if priming {
            if level < targetFrames {
                out.update(repeating: 0, count: frames * 2)
                return
            }
            priming = false
        }
        if level > highFrames {
            fifo.discard(level - targetFrames)
            drops.add(1, ordering: .relaxed)
        }
        let n = fifo.read(into: out, frames: frames)
        if n < frames {
            (out + 2 * n).update(repeating: 0, count: (frames - n) * 2)
            underruns.add(1, ordering: .relaxed)
            priming = true
        }
        if fadedFrames < fadeFrames, n > 0 { fadeIn(out, frames: n) }
    }

    /// Two seconds from silence at the start of a stream: the level the headphones end up at is
    /// a guess until the listener hears it, so it arrives gently rather than at once.
    var fadeSeconds = 2.0 { didSet { fadeFrames = Int(Double(sampleRate) * fadeSeconds) } }
    private lazy var fadeFrames = Int(Double(sampleRate) * fadeSeconds)
    private var fadedFrames = 0

    private func fadeIn(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        for i in 0..<frames {
            let t = Float(min(fadedFrames + i, fadeFrames)) / Float(fadeFrames)
            let gain = t * t
            out[2 * i] *= gain
            out[2 * i + 1] *= gain
        }
        fadedFrames += frames
    }

    public func didSkip(frames: Int) { fifo.discard(frames) }

    var testFIFO: FrameFIFO { fifo }

    // MARK: Poller

    private func poll() {
        pollCount += 1
        if pollCount % 200 == 0 {   // every second: report new underruns/drops as they happen
            let u = underruns.load(ordering: .relaxed), d = drops.load(ordering: .relaxed)
            if u != lastReport.underruns || d != lastReport.drops {
                log.warn("system audio: +\(u - lastReport.underruns) underruns, +\(d - lastReport.drops) drops (FIFO \(fifo.level * 1000 / sampleRate) ms)")
                lastReport = (u, d)
            }
        }
        // A full reply means there is more; read until caught up.
        for _ in 0..<8 {
            let reply: Reply
            do {
                reply = try readDriver(from: cursor)
            } catch {
                failedReads += 1
                if failedReads == 1 || failedReads % 1000 == 0 { log.warn("system audio: read failed: \(error)") }
                return
            }
            failedReads = 0
            if reply.session != session {
                // New timeline (IO restarted, or the rate changed): its sample times are new.
                if session >= 0 { log.info("system audio: device timeline restarted") }
                session = reply.session
                cursor = reply.start + Int64(reply.frameCount)
            }
            if reply.rate != sampleRate {
                if !rateWarned {
                    log.warn("system audio: device runs at \(reply.rate) Hz, LDAC at \(sampleRate) Hz; setting it back")
                    rateWarned = true
                    _ = FidelisAudioDevice.setNominalSampleRate(device, Double(sampleRate))
                }
                cursor = reply.start + Int64(reply.frameCount)
                return
            }
            rateWarned = false
            if reply.start > cursor, cursor >= 0 {
                log.warn("system audio: fell \(reply.start - cursor) frames behind the driver")
            }
            if reply.frameCount > 0 {
                reply.samples.withUnsafeBufferPointer { _ = fifo.write($0) }
            }
            cursor = reply.start + Int64(reply.frameCount)
            if reply.frameCount < 1 << 15 { return }
        }
    }

    private struct Reply {
        var start: Int64
        var session: Int64
        var rate: Int
        var samples: [Float]
        var frameCount: Int { samples.count / 2 }
    }

    private func readDriver(from sampleTime: Int64) throws -> Reply {
        var address = FidelisAudioDevice.globalAddress(FidelisAudioDevice.audioSelector)
        var qualifier: CFPropertyList = NSNumber(value: sampleTime)
        var value: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<CFPropertyList>.size)
        let status = withUnsafePointer(to: &qualifier) {
            AudioObjectGetPropertyData(device, &address, UInt32(MemoryLayout<CFPropertyList>.size), $0, &size, &value)
        }
        if status == kAudioHardwareIllegalOperationError { throw SystemAudioError.driverRefused }
        guard status == noErr else { throw SystemAudioError.coreAudio("reading 'fdau'", status) }
        guard let reply = value?.takeRetainedValue() as? [String: Any],
              let start = (reply["start"] as? NSNumber)?.int64Value,
              let session = (reply["session"] as? NSNumber)?.int64Value,
              let rate = (reply["rate"] as? NSNumber)?.intValue,
              let frames = reply["frames"] as? Data
        else { throw SystemAudioError.coreAudio("decoding 'fdau'", -1) }
        let samples = frames.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return Reply(start: start, session: session, rate: rate, samples: samples)
    }
}
