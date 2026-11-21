import XCTest
@testable import FidelisCore

final class FrameFIFOTests: XCTestCase {
    private func frames(_ range: Range<Int>) -> [Float] { range.flatMap { [Float($0), -Float($0)] } }

    func testReadsBackInOrderAcrossTheWrap() {
        let fifo = FrameFIFO(capacityFrames: 100)
        XCTAssertEqual(fifo.capacity, 128)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer { out.deallocate() }
        var next = 0, expect = 0
        for _ in 0..<20 {
            next += frames(next..<(next + 50)).withUnsafeBufferPointer { fifo.write($0) }
            let n = fifo.read(into: out, frames: 40)
            for i in 0..<n {
                XCTAssertEqual(out[2 * i], Float(expect)); XCTAssertEqual(out[2 * i + 1], -Float(expect))
                expect += 1
            }
        }
        XCTAssertEqual(fifo.level, next - expect)
    }

    func testDropsWhatDoesNotFit() {
        let fifo = FrameFIFO(capacityFrames: 64)
        let wrote = frames(0..<100).withUnsafeBufferPointer { fifo.write($0) }
        XCTAssertEqual(wrote, 64)
        XCTAssertEqual(fifo.level, 64)
        fifo.discard(1000)
        XCTAssertEqual(fifo.level, 0)
    }
}

final class SystemAudioSourceTests: XCTestCase {
    func testFadesInFromSilence() {
        let src = SystemAudioSource(sampleRate: 48000, targetMs: 10, log: Log())
        src.fadeSeconds = 0.01   // 480 frames
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer { out.deallocate() }
        let ones = [Float](repeating: 1, count: 2 * 2000)
        ones.withUnsafeBufferPointer { _ = src.testFIFO.write($0) }
        src.render(out, frames: 128)
        XCTAssertEqual(out[0], 0)
        XCTAssertLessThan(out[2 * 127], 0.1)
        XCTAssertGreaterThan(out[2 * 127], out[2 * 64])
        for _ in 0..<3 { src.render(out, frames: 128) }   // past 480 frames
        XCTAssertEqual(out[2 * 127], 1)
        XCTAssertEqual(out[2 * 127 + 1], 1)
    }

    /// The slider's gain never starts from full scale and reaches a new value within a buffer.
    func testAppliesTheSliderGain() {
        let src = SystemAudioSource(sampleRate: 48000, targetMs: 10, log: Log())
        src.fadeSeconds = 0
        src.setVolumeGain(0.01)
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer { out.deallocate() }
        let ones = [Float](repeating: 1, count: 2 * 2000)
        ones.withUnsafeBufferPointer { _ = src.testFIFO.write($0) }
        src.render(out, frames: 128)
        XCTAssertEqual(out[0], 0.01, accuracy: 1e-6)
        XCTAssertEqual(out[2 * 127 + 1], 0.01, accuracy: 1e-6)
        src.setVolumeGain(0.5)
        src.render(out, frames: 128)
        XCTAssertGreaterThan(out[0], 0.01)
        XCTAssertLessThan(out[0], 0.5)
        XCTAssertEqual(out[2 * 127], 0.5, accuracy: 1e-6)
    }

    /// The cushion is waited for once; after an underrun only the base buffer refills, or the
    /// cushion would be added to the delay for good.
    func testRefillAfterUnderrunWaitsForTheBaseOnly() {
        let src = SystemAudioSource(sampleRate: 48000, targetMs: 10, cushionMs: 20, log: Log())   // 480 + 960
        src.fadeSeconds = 0
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        defer { out.deallocate() }
        let ones = [Float](repeating: 1, count: 2 * 1000)
        ones.withUnsafeBufferPointer { _ = src.testFIFO.write($0) }      // 1000 < 1440: still priming
        src.render(out, frames: 128)
        XCTAssertEqual(out[0], 0)
        ones.withUnsafeBufferPointer { _ = src.testFIFO.write(UnsafeBufferPointer(rebasing: $0[0..<1000])) }   // 1500
        src.render(out, frames: 128)
        XCTAssertEqual(out[0], 1)
        src.render(out, frames: 2000)                                    // drains it: underrun
        let some = [Float](repeating: 1, count: 2 * 500)
        some.withUnsafeBufferPointer { _ = src.testFIFO.write($0) }      // 500 ≥ 480: plays again
        src.render(out, frames: 128)
        XCTAssertEqual(out[0], 1)
    }

    func testSliderCurveIsLinearInDecibels() {
        XCTAssertEqual(FidelisAudioDevice.gain(forSlider: 0), 0)
        XCTAssertEqual(FidelisAudioDevice.gain(forSlider: 1), 1)
        XCTAssertEqual(20 * log10(FidelisAudioDevice.gain(forSlider: 0.5)), -20, accuracy: 0.01)
        XCTAssertEqual(20 * log10(FidelisAudioDevice.gain(forSlider: 0.0625)), -37.5, accuracy: 0.01)
        XCTAssertEqual(FidelisAudioDevice.slider(forDecibels: -30), 0.25, accuracy: 1e-6)
        XCTAssertEqual(FidelisAudioDevice.slider(forDecibels: -200), 0)
        // The driver scales by the slider value: the same loudness is at the gain.
        XCTAssertEqual(FidelisAudioDevice.driverSlider(matching: 0.5), 0.1, accuracy: 1e-4)
    }

    func testPrimesThenPlaysThenRefillsAfterUnderrun() {
        let src = SystemAudioSource(sampleRate: 48000, targetMs: 10, log: Log())   // 480 frames
        src.fadeSeconds = 0
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer { out.deallocate() }
        let ones = [Float](repeating: 1, count: 2 * 400)

        ones.withUnsafeBufferPointer { _ = src.testFIFO.write($0) }
        src.render(out, frames: 128)
        XCTAssertEqual(out[0], 0, "below the target: still priming, silence")

        ones.withUnsafeBufferPointer { _ = src.testFIFO.write($0) }   // 800 ≥ 480
        src.render(out, frames: 128)
        XCTAssertEqual(out[0], 1, "target reached: plays")
        XCTAssertEqual(src.testFIFO.level, 800 - 128)

        for _ in 0..<5 { src.render(out, frames: 128) }   // drains 640 of the 672 left
        src.render(out, frames: 128)
        XCTAssertEqual(out[2 * 31], 1); XCTAssertEqual(out[2 * 32], 0, "underrun: the rest is silence")
        ones.withUnsafeBufferPointer { _ = src.testFIFO.write($0) }
        src.render(out, frames: 128)
        XCTAssertEqual(out[0], 0, "after an underrun it primes again")
    }

    func testBacklogDropsBackToTarget() {
        let src = SystemAudioSource(sampleRate: 48000, targetMs: 10, log: Log())   // high = 480 + 2880
        src.fadeSeconds = 0
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer { out.deallocate() }
        let lots = [Float](repeating: 1, count: 2 * 6000)
        lots.withUnsafeBufferPointer { _ = src.testFIFO.write($0) }
        src.render(out, frames: 128)
        XCTAssertEqual(src.testFIFO.level, 480 - 128)
    }
}
