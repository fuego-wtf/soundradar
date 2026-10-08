import CoreAudio
import Foundation

/// Pure, allocation-free math for the mixer. Everything here is safe to call on the
/// realtime audio thread and is unit tested without touching Core Audio.
enum MixerMath {
    static let silenceDB: Float = -120
    static let attackSeconds: Float = 0.015
    static let releaseSeconds: Float = 0.3
    static let maxGain: Float = 1.5
    /// Below this magnitude the limiter is the identity.
    static let limiterKnee: Float = 0.9
    /// Time a gain change takes to settle to within 5 % of its target.
    static let gainRampSeconds: Float = 0.02
    static let defaultSampleRate: Float = 48_000
    /// Per-sample one-pole coefficient for gain changes at the 48 kHz fallback rate.
    static let gainRampCoefficient: Float = gainRampCoefficient(sampleRate: defaultSampleRate)

    /// Per-sample one-pole coefficient so a step settles to within 5 % (e^-3) after `seconds`
    /// at `sampleRate`. Falls back to 48 kHz for an unusable rate.
    static func gainRampCoefficient(sampleRate: Float, seconds: Float = gainRampSeconds) -> Float {
        let rate = (sampleRate.isFinite && sampleRate >= 8_000 && sampleRate <= 768_000) ? sampleRate : defaultSampleRate
        return 1 - exp(-3 / (rate * seconds))
    }

    // MARK: Metering

    static func sumOfSquares(_ p: UnsafePointer<Float>, count: Int) -> Float {
        var s: Float = 0
        var i = 0
        while i < count { s += p[i] * p[i]; i += 1 }
        return s
    }

    /// dBFS of a root-mean-square built from a sum of squares over `count` samples.
    static func dBFS(sumSquares: Float, count: Int) -> Float {
        guard count > 0, sumSquares > 0, sumSquares.isFinite else { return silenceDB }
        let rms = (sumSquares / Float(count)).squareRoot()
        return max(silenceDB, 20 * log10(rms))
    }

    static func rmsDBFS(_ p: UnsafePointer<Float>, count: Int) -> Float {
        dBFS(sumSquares: sumOfSquares(p, count: count), count: count)
    }

    /// One smoothing step toward `target` (dBFS) over `dt` seconds: fast attack, slow release.
    static func smoothLevel(current: Float, target: Float, dt: Float) -> Float {
        guard dt > 0 else { return current }
        let tau = target > current ? attackSeconds : releaseSeconds
        let k = 1 - exp(-dt / tau)
        return max(silenceDB, current + (target - current) * k)
    }

    // MARK: Gain

    static func clampVolume(_ v: Float) -> Float {
        guard v.isFinite else { return 1 }
        return min(max(v, 0), maxGain)
    }

    static func targetGain(volume: Float, muted: Bool) -> Float {
        muted ? 0 : clampVolume(volume)
    }

    /// A channel must own the audio (muted tap) only when the sound differs from the original.
    static func needsProcessing(volume: Float, muted: Bool) -> Bool {
        muted || clampVolume(volume) != 1
    }

    /// Once a channel owns the audio (muted tap, re-rendered) it keeps doing so, even back at
    /// exactly 100 % and unmuted: leaving processing mode would rebuild the tap and click.
    static func keepsProcessing(wasProcessing: Bool, volume: Float, muted: Bool) -> Bool {
        wasProcessing || needsProcessing(volume: volume, muted: muted)
    }

    /// One per-sample step of the gain smoother; snaps to the target when very close.
    static func gainRamp(current: Float, target: Float, coefficient: Float = gainRampCoefficient) -> Float {
        let next = current + (target - current) * coefficient
        return abs(target - next) < 1e-4 ? target : next
    }

    /// Identity up to the knee, then a tanh curve that approaches (never exceeds) 1.0.
    static func softLimit(_ x: Float) -> Float {
        let a = abs(x)
        guard a > limiterKnee else { return x }
        let headroom = 1 - limiterKnee
        let limited = min(1, limiterKnee + headroom * tanh((a - limiterKnee) / headroom))
        return x < 0 ? -limited : limited
    }

    // MARK: Render

    /// Copies interleaved `input` to `output` through the smoothed gain and the limiter.
    /// Output channel c reads input channel c + `inOffset` (used to de-interleave one stereo
    /// input into separate mono output buffers). Output channels beyond the input's are silent. Returns the sum of squares of the
    /// input (pre-gain) for metering. `gain` is advanced in place.
    static func render(input: UnsafePointer<Float>, inChannels: Int,
                       output: UnsafeMutablePointer<Float>, outChannels: Int,
                       frames: Int, gain: inout Float, target: Float,
                       coefficient: Float = gainRampCoefficient, inOffset: Int = 0) -> Float {
        var sumSq: Float = 0
        var g = gain
        var f = 0
        while f < frames {
            g = gainRamp(current: g, target: target, coefficient: coefficient)
            var c = 0
            while c < outChannels {
                if c + inOffset < inChannels {
                    let s = input[f * inChannels + c + inOffset]
                    sumSq += s * s
                    output[f * outChannels + c] = softLimit(s * g)
                } else {
                    output[f * outChannels + c] = 0
                }
                c += 1
            }
            f += 1
        }
        gain = g
        return sumSq
    }

    // MARK: Channel diff

    struct ChannelPlan: Equatable {
        var create: Set<pid_t> = []
        var rebuild: Set<pid_t> = []
        var teardown: Set<pid_t> = []
    }

    /// Decides what to do with per-app channels.
    /// - `current`: process objects each live channel was built from.
    /// - `sources`: process objects each app has now.
    /// - `lastActive`: last time (seconds) an app was seen sounding.
    /// A channel whose app stopped is kept until it has been silent for `grace` seconds.
    /// `keepAlive` are processing channels whose process is still alive: never torn down.
    static func planChannels(current: [pid_t: Set<AudioObjectID>],
                             sources: [pid_t: Set<AudioObjectID>],
                             lastActive: [pid_t: TimeInterval],
                             now: TimeInterval, grace: TimeInterval,
                             keepAlive: Set<pid_t> = []) -> ChannelPlan {
        var plan = ChannelPlan()
        for (pid, objects) in sources where !objects.isEmpty {
            if let existing = current[pid] {
                if existing != objects { plan.rebuild.insert(pid) }
            } else {
                plan.create.insert(pid)
            }
        }
        for pid in current.keys {
            if let objects = sources[pid], !objects.isEmpty { continue }
            // A processing (muted or turned-down) channel owns its app's sound: while the
            // process lives, dropping the tap would leak the app's next blip at full volume.
            if keepAlive.contains(pid) { continue }
            let last = lastActive[pid] ?? -.infinity
            if now - last >= grace { plan.teardown.insert(pid) }
        }
        return plan
    }

    // MARK: Stall watchdog

    struct StallProgress: Equatable {
        var count: Int
        var at: TimeInterval
    }

    /// Tracks the IOProc callback counter of a running channel. `progress` is the last count seen
    /// and when it last changed (start it at `(0, startedAt)`). A processing channel whose count
    /// has not advanced for more than `threshold` seconds is stalled: its muted tap would keep the
    /// app silent, so the caller must destroy it. Meter-only channels never stall the sound.
    static func stallStep(processing: Bool, count: Int, progress: StallProgress,
                          now: TimeInterval, threshold: TimeInterval) -> (progress: StallProgress, stalled: Bool) {
        var p = progress
        if count != p.count { p = StallProgress(count: count, at: now) }
        return (p, processing && now - p.at > threshold)
    }
}
