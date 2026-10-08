import CoreAudio
import XCTest
@testable import SoundRadar

final class MixerMathTests: XCTestCase {
    // MARK: rms

    func testRMSOfConstantHalfIsMinusSixDB() {
        let buf = [Float](repeating: 0.5, count: 512)
        let db = buf.withUnsafeBufferPointer { MixerMath.rmsDBFS($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(db, -6.0206, accuracy: 0.01)
    }

    func testRMSOfFullScaleSineIsMinusThreeDB() {
        let buf = (0..<4800).map { sinf(2 * .pi * Float($0) / 48) }
        let db = buf.withUnsafeBufferPointer { MixerMath.rmsDBFS($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(db, -3.01, accuracy: 0.05)
    }

    func testRMSOfSilenceIsFloor() {
        let buf = [Float](repeating: 0, count: 256)
        let db = buf.withUnsafeBufferPointer { MixerMath.rmsDBFS($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(db, MixerMath.silenceDB)
        XCTAssertEqual(MixerMath.dBFS(sumSquares: 1, count: 0), MixerMath.silenceDB)
    }

    // MARK: smoothing

    func testSmoothingAttackIsFasterThanRelease() {
        let up = MixerMath.smoothLevel(current: -60, target: -20, dt: 0.03) - (-60)
        let down = (-20) - MixerMath.smoothLevel(current: -20, target: -60, dt: 0.03)
        XCTAssertGreaterThan(up, 3 * down)
        XCTAssertGreaterThan(up, 25) // nearly there within 30 ms
    }

    func testSmoothingReleaseTakesAboutThreeHundredMilliseconds() {
        var v: Float = -20
        for _ in 0..<30 { v = MixerMath.smoothLevel(current: v, target: -120, dt: 0.01) }
        // after 300 ms (one time constant) ~63% of the 100 dB drop
        XCTAssertEqual(-20 - v, 63.2, accuracy: 2)
    }

    func testSmoothingNeverOvershootsAndZeroDtHolds() {
        XCTAssertEqual(MixerMath.smoothLevel(current: -30, target: -10, dt: 0), -30)
        XCTAssertLessThanOrEqual(MixerMath.smoothLevel(current: -30, target: -10, dt: 5), -10)
    }

    // MARK: gain ramp

    func testGainRampConvergesMonotonicallyWithoutOvershoot() {
        var g: Float = 1
        var last = g
        for _ in 0..<5000 {
            g = MixerMath.gainRamp(current: g, target: 0.25)
            XCTAssertLessThanOrEqual(g, last)
            XCTAssertGreaterThanOrEqual(g, 0.25)
            last = g
        }
        XCTAssertEqual(g, 0.25)
    }

    func testGainRampStepIsSmall() {
        let next = MixerMath.gainRamp(current: 0, target: 1)
        XCTAssertLessThan(next, 0.01) // no zipper jump
        XCTAssertGreaterThan(next, 0)
    }

    func testVolumeClampAndMute() {
        XCTAssertEqual(MixerMath.clampVolume(9), 1.5)
        XCTAssertEqual(MixerMath.clampVolume(-1), 0)
        XCTAssertEqual(MixerMath.targetGain(volume: 1.2, muted: true), 0)
        XCTAssertFalse(MixerMath.needsProcessing(volume: 1, muted: false))
        XCTAssertTrue(MixerMath.needsProcessing(volume: 0.99, muted: false))
        XCTAssertTrue(MixerMath.needsProcessing(volume: 1, muted: true))
    }

    func testStaysInProcessingModeOnceEntered() {
        // untouched channel stays a passive tap at exactly 100 %
        XCTAssertFalse(MixerMath.keepsProcessing(wasProcessing: false, volume: 1, muted: false))
        // leaving 100 % enters processing mode
        XCTAssertTrue(MixerMath.keepsProcessing(wasProcessing: false, volume: 0.5, muted: false))
        XCTAssertTrue(MixerMath.keepsProcessing(wasProcessing: false, volume: 1, muted: true))
        // back at exactly 100 % and unmuted: still processing (no tap rebuild, no click)
        XCTAssertTrue(MixerMath.keepsProcessing(wasProcessing: true, volume: 1, muted: false))
    }

    func testGrantedPermissionStartsEveryChannelInProcessing() {
        XCTAssertTrue(MixerMath.keepsProcessing(wasProcessing: false, volume: 1, muted: false, permissionGranted: true))
        XCTAssertFalse(MixerMath.keepsProcessing(wasProcessing: false, volume: 1, muted: false, permissionGranted: false))
    }

    func testSliderTaper() {
        XCTAssertEqual(MixerMath.sliderToGain(0), 0)
        XCTAssertEqual(MixerMath.sliderToGain(1), 1)
        XCTAssertEqual(MixerMath.sliderToGain(0.5), 0.25, accuracy: 1e-6)
        XCTAssertEqual(MixerMath.sliderToGain(1.5), 1.5, accuracy: 1e-6)
        XCTAssertEqual(MixerMath.sliderToGain(9), 1.5, accuracy: 1e-6)
        XCTAssertEqual(MixerMath.sliderToGain(-1), 0)
        var prev: Float = -1
        for i in 0...150 {
            let g = MixerMath.sliderToGain(Float(i) / 100)
            XCTAssertGreaterThan(g, prev, "strictly increasing at \(i)")
            prev = g
        }
        for i in 0...150 {
            let p = Float(i) / 100
            XCTAssertEqual(MixerMath.gainToSlider(MixerMath.sliderToGain(p)), p, accuracy: 1e-4)
        }
    }

    func testGainRampCoefficientSettlesIn20msAtEveryRate() {
        for rate: Float in [44_100, 48_000, 96_000] {
            let k = MixerMath.gainRampCoefficient(sampleRate: rate)
            var g: Float = 0
            let n = Int((rate * 0.02).rounded())
            for _ in 0..<n { g = MixerMath.gainRamp(current: g, target: 1, coefficient: k) }
            XCTAssertEqual(g, 1, accuracy: 0.05, "rate \(rate)")
            XCTAssertLessThan(g, 0.99, "rate \(rate): ramp must not be instant")
        }
    }

    func testGainRampCoefficientFallsBackForBadRate() {
        let fallback = MixerMath.gainRampCoefficient(sampleRate: 48_000)
        XCTAssertEqual(MixerMath.gainRampCoefficient(sampleRate: 0), fallback)
        XCTAssertEqual(MixerMath.gainRampCoefficient(sampleRate: .nan), fallback)
    }

    // MARK: limiter

    func testLimiterNeverExceedsOne() {
        for x in stride(from: Float(-20), through: 20, by: 0.01) {
            XCTAssertLessThanOrEqual(abs(MixerMath.softLimit(x)), 1.0, "x=\(x)")
        }
        XCTAssertLessThanOrEqual(MixerMath.softLimit(.greatestFiniteMagnitude), 1.0)
    }

    func testLimiterIsIdentityBelowKnee() {
        for x in stride(from: Float(-0.9), through: 0.9, by: 0.01) {
            XCTAssertEqual(MixerMath.softLimit(x), x)
        }
    }

    func testLimiterIsMonotonicAndOddSymmetric() {
        var last: Float = -1
        for x in stride(from: Float(-3), through: 3, by: 0.01) {
            let y = MixerMath.softLimit(x)
            XCTAssertGreaterThanOrEqual(y, last)
            last = y
            XCTAssertEqual(MixerMath.softLimit(-x), -y, accuracy: 1e-6)
        }
    }

    func testRenderAppliesGainMuteAndLimiter() {
        let input = [Float](repeating: 0.8, count: 2 * 4000) // stereo
        var out = [Float](repeating: 9, count: 2 * 4000 + 4000) // output has 3 channels
        // converge gain at 1.5: 0.8 * 1.5 = 1.2 must be limited to <= 1
        var gain: Float = 1.5
        var sumSq: Float = 0
        input.withUnsafeBufferPointer { i in out.withUnsafeMutableBufferPointer { o in
            sumSq = MixerMath.render(input: i.baseAddress!, inChannels: 2, output: o.baseAddress!, outChannels: 3,
                                     frames: 4000, gain: &gain, target: 1.5)
        } }
        XCTAssertEqual(sumSq, 0.64 * 8000, accuracy: 1)
        for f in 0..<4000 {
            XCTAssertLessThanOrEqual(abs(out[f * 3]), 1.0)
            XCTAssertGreaterThan(out[f * 3], 0.9)
            XCTAssertEqual(out[f * 3 + 2], 0) // channel with no input stays silent
        }
        // muting ramps to exact zero (needs ~8000 samples to decay below the snap threshold)
        let longIn = [Float](repeating: 0.8, count: 2 * 12000)
        var longOut = [Float](repeating: 9, count: 2 * 12000)
        longIn.withUnsafeBufferPointer { i in longOut.withUnsafeMutableBufferPointer { o in
            _ = MixerMath.render(input: i.baseAddress!, inChannels: 2, output: o.baseAddress!, outChannels: 2,
                                 frames: 12000, gain: &gain, target: 0)
        } }
        XCTAssertEqual(gain, 0)
        XCTAssertEqual(longOut[2 * 11999], 0)
        XCTAssertGreaterThan(longOut[2], 0) // ramp, not a click to zero
    }

    // MARK: channel diff

    private typealias Plan = MixerMath.ChannelPlan

    func testPlanCreatesNewAppsAndRebuildsChangedObjectSets() {
        let plan = MixerMath.planChannels(
            current: [1: [10], 2: [20]],
            sources: [1: [10], 2: [20, 21], 3: [30]],
            lastActive: [1: 100, 2: 100, 3: 100], now: 100, grace: 5)
        XCTAssertEqual(plan, Plan(create: [3], rebuild: [2], teardown: []))
    }

    func testPlanKeepsChannelDuringGraceThenTearsDown() {
        let current: [pid_t: Set<AudioObjectID>] = [1: [10]]
        let within = MixerMath.planChannels(current: current, sources: [:], lastActive: [1: 100], now: 104.9, grace: 5)
        XCTAssertEqual(within, Plan())
        let after = MixerMath.planChannels(current: current, sources: [:], lastActive: [1: 100], now: 105, grace: 5)
        XCTAssertEqual(after.teardown, [1])
    }

    func testPlanReturnedAppCancelsTeardown() {
        let plan = MixerMath.planChannels(current: [1: [10]], sources: [1: [10]], lastActive: [1: 0], now: 500, grace: 5)
        XCTAssertEqual(plan, Plan())
    }

    func testPlanIgnoresSourceWithNoObjects() {
        let plan = MixerMath.planChannels(current: [:], sources: [1: []], lastActive: [:], now: 0, grace: 5)
        XCTAssertEqual(plan, Plan())
    }

    func testPlanKeepsProcessingChannelOfLiveProcessPastGrace() {
        let current: [pid_t: Set<AudioObjectID>] = [1: [10], 2: [20]]
        let plan = MixerMath.planChannels(current: current, sources: [:], lastActive: [1: 0, 2: 0],
                                          now: 500, grace: 5, keepAlive: [1])
        XCTAssertEqual(plan.teardown, [2])
    }

    func testPlanStillRebuildsKeptChannelWhenObjectsChange() {
        let plan = MixerMath.planChannels(current: [1: [10]], sources: [1: [11]], lastActive: [1: 0],
                                          now: 500, grace: 5, keepAlive: [1])
        XCTAssertEqual(plan.rebuild, [1])
        XCTAssertTrue(plan.teardown.isEmpty)
    }

    func testStallDetectedOnlyForProcessingChannelWithFrozenCount() {
        var p = MixerMath.StallProgress(count: 0, at: 100)
        var r = MixerMath.stallStep(processing: true, count: 0, progress: p, now: 100.9, threshold: 1)
        XCTAssertFalse(r.stalled)
        r = MixerMath.stallStep(processing: true, count: 0, progress: p, now: 101.1, threshold: 1)
        XCTAssertTrue(r.stalled)
        XCTAssertFalse(MixerMath.stallStep(processing: false, count: 0, progress: p, now: 200, threshold: 1).stalled)
        // running for a while, then freezing at count 50
        r = MixerMath.stallStep(processing: true, count: 50, progress: p, now: 150, threshold: 1)
        XCTAssertFalse(r.stalled)
        p = r.progress
        XCTAssertEqual(p, MixerMath.StallProgress(count: 50, at: 150))
        XCTAssertFalse(MixerMath.stallStep(processing: true, count: 50, progress: p, now: 150.9, threshold: 1).stalled)
        XCTAssertTrue(MixerMath.stallStep(processing: true, count: 50, progress: p, now: 151.5, threshold: 1).stalled)
        XCTAssertFalse(MixerMath.stallStep(processing: true, count: 51, progress: p, now: 151.5, threshold: 1).stalled)
    }
}

