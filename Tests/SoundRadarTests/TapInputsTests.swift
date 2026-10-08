import CoreAudio
import Darwin
import XCTest
@testable import SoundRadar

/// Drives the realtime `process` with synthetic AudioBufferLists (no Core Audio device involved).
final class TapInputsTests: XCTestCase {
    private let frames = 256

    private func makeList(_ values: [Float], channels: Int = 2) -> (UnsafeMutableAudioBufferListPointer, [UnsafeMutablePointer<Float>]) {
        let list = AudioBufferList.allocate(maximumBuffers: values.count)
        var ptrs: [UnsafeMutablePointer<Float>] = []
        for (i, v) in values.enumerated() {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames * channels)
            p.initialize(repeating: v, count: frames * channels)
            list[i] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4), mData: p)
            ptrs.append(p)
        }
        return (list, ptrs)
    }

    private func release(_ list: UnsafeMutableAudioBufferListPointer, _ ptrs: [UnsafeMutablePointer<Float>]) {
        ptrs.forEach { $0.deallocate() }
        Darwin.free(list.unsafeMutablePointer)
    }

    private func run(inputs: [Float], skip: Int) -> [Float] {
        let (ins, inPtrs) = makeList(inputs)
        let (outs, outPtrs) = makeList([7]) // sentinel proves the callback wrote the output
        defer { release(ins, inPtrs); release(outs, outPtrs) }
        let rt = RTState(processing: true, target: 1)
        rt.inputSkip = skip
        rt.process(UnsafePointer(ins.unsafePointer), outs.unsafeMutablePointer)
        return Array(UnsafeBufferPointer(start: outPtrs[0], count: frames * 2))
    }

    func testMicBufferIsNeverPlayedBack() {
        // buffer 0 is the output device's own mic (0.9), buffer 1 is the tap (0.1)
        let out = run(inputs: [0.9, 0.1], skip: 1)
        for s in out { XCTAssertEqual(s, 0.1, accuracy: 1e-6) }
    }

    func testSkipBeyondBufferCountIsSilentAndSafe() {
        for skip in [2, 3, 50] {
            let out = run(inputs: [0.9, 0.1], skip: skip)
            XCTAssertTrue(out.allSatisfy { $0 == 0 }, "skip \(skip)")
        }
    }

    func testGainAppliesToTapSignalOnly() {
        let (ins, inPtrs) = makeList([0.9, 0.4])
        let (outs, outPtrs) = makeList([7])
        defer { release(ins, inPtrs); release(outs, outPtrs) }
        let rt = RTState(processing: true, target: 0.5)
        rt.inputSkip = 1
        rt.process(UnsafePointer(ins.unsafePointer), outs.unsafeMutablePointer)
        XCTAssertEqual(outPtrs[0][10], 0.2, accuracy: 1e-6)
    }

    func testTapInputsSkipsLeadingBuffers() {
        let (list, ptrs) = makeList([0.9, 0.1, 0.2])
        defer { release(list, ptrs) }
        let t = TapInputs(list: list, skip: 1)
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(Array(t).count, 2)
        XCTAssertEqual(t[0].mData?.assumingMemoryBound(to: Float.self).pointee, 0.1)
    }
}
