import Foundation
import CoreMedia
import CoreVideo

/// Thread-safe collector for encoder output.
private final class FrameLog {
    private let lock = NSLock()
    private var items: [StreamVideoEncoder.Frame] = []
    func add(_ frame: StreamVideoEncoder.Frame) { lock.lock(); items.append(frame); lock.unlock() }
    var frames: [StreamVideoEncoder.Frame] { lock.lock(); defer { lock.unlock() }; return items }
}

private let width = 1920
private let height = 1080

/// A row of BGRA pixels, much wider than the picture: a ramp plus noise. Rows are copied out of
/// it at an offset that moves every frame, so the picture moves and no two frames repeat.
/// `noiseShift` sets how busy it is: 31 is nearly flat, 24 is close to white noise. `other`
/// gives an unrelated picture: another seed and a steeper ramp running the other way per channel.
private func noiseRow(noiseShift: UInt32, other: Bool = false) -> [UInt8] {
    var seed: UInt32 = other ? 999 : 12345
    var row = [UInt8](repeating: 255, count: (width + 4096) * 4)
    for x in 0..<(width + 4096) {
        for channel in 0..<3 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let ramp = other ? 765 - x / 3 + channel * 85 : x / 8
            row[x * 4 + channel] = UInt8(truncatingIfNeeded: ramp + Int(seed >> noiseShift))
        }
    }
    return row
}

/// A new BGRA IOSurface-backed buffer for frame `index`.
private func movingBuffer(from row: [UInt8], index: Int) -> CVPixelBuffer? {
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
    var buffer: CVPixelBuffer?
    guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
          let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    row.withUnsafeBytes { source in
        for y in 0..<height {
            let offset = ((y * 13 + index * 37) % 4000) * 4
            memcpy(base + y * stride, source.baseAddress! + offset, width * 4)
        }
    }
    return buffer
}

private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { Thread.sleep(forTimeInterval: 0.002) }
}

private struct Run {
    let frames: [StreamVideoEncoder.Frame]
    let dropped: Int
    /// What `encode` returned for each input frame.
    let accepted: [Bool]
    var totalBytes: Int { frames.reduce(0) { $0 + $1.avcc.count } }
    /// Most bytes in any one second of presentation time.
    var worstSecond: Int {
        var worst = 0
        var start = 0
        var sum = 0
        for frame in frames {
            sum += frame.avcc.count
            while frame.time.seconds - frames[start].time.seconds >= 1 {
                sum -= frames[start].avcc.count
                start += 1
            }
            worst = max(worst, sum)
        }
        return worst
    }
    /// Fewest frames output in any of the whole seconds [k, k + 1) of the input.
    func fewestFramesPerSecond(seconds: Int) -> Int {
        (0..<seconds).map { k in frames.filter { Int($0.time.seconds) == k }.count }.min() ?? 0
    }
    /// Longest stretch in seconds without a keyframe: between keyframes, and from the last one to
    /// the last input frame at `end`.
    func longestKeyframeGap(end: Double) -> Double {
        let times = frames.filter(\.keyframe).map(\.time.seconds)
        guard let last = times.last else { return .infinity }
        return zip(times, times.dropFirst()).map { $1 - $0 }.reduce(end - last, max)
    }
    /// Bytes of frames with presentation time under 1 s.
    var firstSecond: Int { frames.filter { $0.time.seconds < 1 }.reduce(0) { $0 + $1.avcc.count } }
    /// Longest runs of consecutive dropped input frames: before an admitted keyframe (where the
    /// guard waits for room for one), and elsewhere.
    var longestDropRuns: (keyframe: Int, other: Int) {
        let keyframes = Set(frames.filter(\.keyframe).map { Int($0.time.value) })
        var longest = (keyframe: 0, other: 0)
        var run = 0
        for (i, ok) in accepted.enumerated() {
            if !ok { run += 1; continue }
            if keyframes.contains(i) { longest.keyframe = max(longest.keyframe, run) } else { longest.other = max(longest.other, run) }
            run = 0
        }
        longest.other = max(longest.other, run)
        return longest
    }
}

/// Encodes `count` frames at 60 fps and returns what came out once the encoder has finished.
/// `forceKeyframe` picks the frames sent with a keyframe request; `sceneEvery` switches to an
/// unrelated picture and back every that many frames; `warmUp` waits for the first output;
/// `time` gives frame `i` its presentation time.
private func encodeRun(count: Int, bitrate: Int = 6_000_000, noiseShift: UInt32, forceKeyframe: (Int) -> Bool = { _ in false },
                       sceneEvery: Int? = nil, warmUp: Bool = true,
                       time: (Int) -> CMTime = { CMTime(value: CMTimeValue($0), timescale: 60) }) -> Run? {
    let log = FrameLog()
    guard let encoder = StreamVideoEncoder(width: width, height: height, bitrate: bitrate, frameRate: 60, onFrame: { log.add($0) }) else { return nil }
    let rows = [noiseRow(noiseShift: noiseShift), noiseRow(noiseShift: noiseShift, other: true)]
    var accepted: [Bool] = []
    for i in 0..<count {
        let row = rows[sceneEvery.map { (i / $0) % 2 } ?? 0]
        guard let buffer = movingBuffer(from: row, index: i) else { return nil }
        // Capture arrives every 16 ms; a little pacing keeps the checks short but not a flood.
        Thread.sleep(forTimeInterval: 0.004)
        accepted.append(encoder.encode(buffer, at: time(i), forceKeyframe: forceKeyframe(i)))
        // The first frame's latency is the encoder's warm-up, not steady state: wait it out.
        if i == 0 && warmUp { waitUntil(timeout: 3) { !log.frames.isEmpty } }
    }
    encoder.invalidate()
    return Run(frames: log.frames, dropped: encoder.droppedFrames, accepted: accepted)
}

func videoEncoderChecks() {
    guard StreamVideoEncoder.hardwareAvailable(width: 1920, height: 1080) else {
        print("video encoder checks skipped: no hardware H.264 encoder for 1920x1080")
        return
    }

    check("encoder outputs 300 frames in input order with keyframes and parameter sets") {
        let run = try encodeRun(count: 300, noiseShift: 31).unwrapped("encoder not created")
        let frames = run.frames
        try expect(frames.count == 300, "got \(frames.count) frames")
        try expect(run.dropped == 0, "dropped \(run.dropped) frames")
        try expect(frames[0].keyframe, "first frame is not a keyframe")
        try expect(frames[0].sps?.isEmpty == false && frames[0].pps?.isEmpty == false, "first keyframe lacks SPS/PPS")
        var last = -1
        var lastKey = 0
        for (i, frame) in frames.enumerated() {
            let t = Int(frame.time.value)
            try expect(t > last, "time \(t) after \(last) at \(i)")
            last = t
            try expect(frame.avcc.count > 4, "empty frame \(i)")
            let length = frame.avcc.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            try expect(length > 0 && length <= frame.avcc.count - 4, "bad length prefix at \(i)")
            if frame.keyframe {
                try expect(i - lastKey <= 120, "keyframes \(i - lastKey) frames apart")
                lastKey = i
            }
        }
        try expect(299 - lastKey <= 120, "no keyframe in the last stretch")
    }

    check("forceKeyframe makes that frame a keyframe") {
        let run = try encodeRun(count: 100, noiseShift: 31, forceKeyframe: { $0 == 50 }).unwrapped("encoder not created")
        try expect(run.frames.count == 100, "got \(run.frames.count) frames")
        try expect(run.frames[50].keyframe, "frame 50 is not a keyframe")
    }

    // The hardware encoder overshoots its data rate on busy pictures, so these hold the guard to it.
    // Not covered: near-white noise (shift 24), where one key frame alone is ~900 KB and no
    // frame dropping can keep a second under the limit.
    let report = ProcessInfo.processInfo.environment["ENCODER_REPORT"] != nil
    check("encoder holds 6 Mbps on busy input, shedding evenly") {
        let run = try encodeRun(count: 300, noiseShift: 28).unwrapped("encoder not created")
        let runs = run.longestDropRuns
        let gap = run.longestKeyframeGap(end: 299.0 / 60)
        if report { print("shift 28: worst \(run.worstSecond) total \(run.totalBytes) out \(run.frames.count) drop runs \(runs) keyframe gap \(gap)") }
        try expect(run.totalBytes >= 1_500_000 && run.totalBytes <= 5_000_000, "total \(run.totalBytes) bytes")
        try expect(run.frames.count > 5, "only \(run.frames.count) frames")
        try expect(Double(run.worstSecond) <= 1.3 * 750_000, "worst second \(run.worstSecond) bytes")
        try expect(run.frames.count + run.dropped == 300, "frames \(run.frames.count) + dropped \(run.dropped)")
        try expect(runs.other <= 4, "\(runs.other) frames dropped in a row")
        try expect(runs.keyframe <= 4, "\(runs.keyframe) frames dropped in a row before a keyframe")
        try expect(gap <= 2.2, "\(gap) s without a keyframe")
    }

    // Even shedding is not asserted here: fed at 15 fps (every 4th frame) with no guard, this
    // encoder already goes over the target, since it re-spends the budget dropped frames leave.
    // Holding the rate comes first; the stream must only keep moving.
    check("encoder holds 6 Mbps on very busy input without stalling") {
        let run = try encodeRun(count: 300, noiseShift: 26).unwrapped("encoder not created")
        let fewest = run.fewestFramesPerSecond(seconds: 5)
        let gap = run.longestKeyframeGap(end: 299.0 / 60)
        if report { print("shift 26: worst \(run.worstSecond) total \(run.totalBytes) out \(run.frames.count) fewest a second \(fewest) drop runs \(run.longestDropRuns) keyframe gap \(gap)") }
        try expect(run.frames.count > 5, "only \(run.frames.count) frames")
        try expect(Double(run.worstSecond) <= 1.3 * 750_000, "worst second \(run.worstSecond) bytes")
        try expect(run.frames.count + run.dropped == 300, "frames \(run.frames.count) + dropped \(run.dropped)")
        try expect(fewest >= 1, "a second with only \(fewest) frames")
        // A keyframe here needs most of a second's budget, so it waits for room: measured 2.52 s.
        try expect(gap <= 2.6, "\(gap) s without a keyframe")
    }

    // Input close to the target must not be thinned by the guard's pacing. At shift 30 the
    // encoder stays under the target throughout. At shift 29 it settles at about 720-735 KB a
    // second, but its first second runs over while it settles, so the guard drops a few frames there.
    for (shift, fewest) in [(UInt32(30), 300), (UInt32(29), 290)] {
        check("encoder keeps nearly every frame of mid-busy input (shift \(shift))") {
            let run = try encodeRun(count: 300, noiseShift: shift).unwrapped("encoder not created")
            if report { print("shift \(shift): worst \(run.worstSecond) out \(run.frames.count)") }
            try expect(run.frames.count >= fewest, "\(run.frames.count) of 300 frames out")
            try expect(Double(run.worstSecond) <= 1.3 * 750_000, "worst second \(run.worstSecond) bytes")
        }
    }

    check("encoder recovers when input time restarts") {
        // 120 frames from t = 100 s, then 120 from t = 0, frames of the first stretch in flight.
        let run = try encodeRun(count: 240, noiseShift: 29, time: {
            CMTime(value: CMTimeValue($0 < 120 ? 6000 + $0 : $0 - 120), timescale: 60)
        }).unwrapped("encoder not created")
        let restarted = run.frames.filter { $0.time.seconds < 100 }
        let keyframes = restarted.filter(\.keyframe).map(\.time.seconds)
        if report { print("time restart: \(restarted.count) of 120 out, keyframes at \(keyframes)") }
        try expect(restarted.count >= 115, "only \(restarted.count) of 120 frames after the restart")
        try expect(keyframes.first.map { $0 <= 0.2 } == true, "no keyframe where time restarted")
        try expect(zip(keyframes, keyframes.dropFirst()).allSatisfy { $1 - $0 <= 2.2 }
                   && 119.0 / 60 - (keyframes.last ?? 0) <= 2.2, "keyframes \(keyframes)")
    }

    check("encoder holds 6 Mbps with keyframes forced on busy input") {
        let run = try encodeRun(count: 300, noiseShift: 28, forceKeyframe: { $0 % 30 == 0 }).unwrapped("encoder not created")
        if report { print("forced keyframes: worst \(run.worstSecond) out \(run.frames.count)") }
        try expect(Double(run.worstSecond) <= 1.3 * 750_000, "worst second \(run.worstSecond) bytes")
        try expect(run.frames.filter(\.keyframe).count >= 5, "keyframes not delivered")
    }

    check("encoder holds 6 Mbps through scene changes") {
        let run = try encodeRun(count: 300, noiseShift: 28, sceneEvery: 20).unwrapped("encoder not created")
        if report { print("scene changes: worst \(run.worstSecond) out \(run.frames.count)") }
        try expect(Double(run.worstSecond) <= 1.3 * 750_000, "worst second \(run.worstSecond) bytes")
        try expect(run.frames.count > 30, "only \(run.frames.count) frames")
    }

    check("encoder holds 6 Mbps from a cold start") {
        let run = try encodeRun(count: 90, noiseShift: 26, warmUp: false).unwrapped("encoder not created")
        if report { print("start-up: first second \(run.firstSecond) out \(run.frames.count)") }
        try expect(Double(run.firstSecond) <= 1.3 * 750_000, "first second \(run.firstSecond) bytes")
        try expect(run.frames.first?.keyframe == true, "first frame is not a keyframe")
    }

    check("a session lost underneath is rebuilt, and frames come out again starting with a keyframe") {
        let log = FrameLog()
        let encoder = try StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60,
                                             onFrame: { log.add($0) }).unwrapped("encoder not created")
        let row = noiseRow(noiseShift: 31)
        for i in 0..<120 {
            let buffer = try movingBuffer(from: row, index: i).unwrapped("no buffer")
            if i == 60 {
                waitUntil(timeout: 3) { log.frames.count >= 55 }
                // As after sleep and wake, or when VideoToolbox's encoder service crashes.
                encoder.breakSessionForChecks()
            }
            Thread.sleep(forTimeInterval: 0.004)
            encoder.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60))
            if i == 0 { waitUntil(timeout: 3) { !log.frames.isEmpty } }
        }
        waitUntil(timeout: 3) { log.frames.last.map { $0.time.value >= 119 } ?? false }
        encoder.invalidate()
        let after = log.frames.filter { $0.time.value >= 60 }
        try expect(after.count >= 55, "only \(after.count) of 60 frames after the session was lost")
        try expect(after.first?.keyframe == true && after.first?.sps != nil, "the first frame after the rebuild is not a keyframe")
        try expect(!encoder.hasFailed, "gave up")
    }

    check("an encoder whose rebuilds keep failing gives up after the recovery limit") {
        let log = FrameLog()
        let encoder = try StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60,
                                             onFrame: { log.add($0) }).unwrapped("encoder not created")
        // Limit 0.5 s, a rebuild at most every 0.1 s.
        encoder.recoveryTimeScale = 0.05
        encoder.refusesRebuildForChecks = true
        let row = noiseRow(noiseShift: 31)
        let buffer = try movingBuffer(from: row, index: 0).unwrapped("no buffer")
        try expect(encoder.encode(buffer, at: .zero), "first frame refused")
        waitUntil(timeout: 3) { !log.frames.isEmpty }
        encoder.breakSessionForChecks()
        let start = Date()
        var i = 1
        while !encoder.hasFailed && Date().timeIntervalSince(start) < 3 {
            encoder.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60))
            i += 1
            Thread.sleep(forTimeInterval: 0.016)
        }
        let took = Date().timeIntervalSince(start)
        try expect(encoder.hasFailed, "never gave up")
        try expect(took >= 0.45 && took < 1.5, "gave up after \(took) s")
        try expect(!encoder.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60)), "took a frame after giving up")
        encoder.invalidate()
    }

    check("a stalled session whose rebuild is refused still gives up after the recovery limit") {
        let log = FrameLog()
        let encoder = try StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60,
                                             onFrame: { log.add($0) }).unwrapped("encoder not created")
        // Limit 0.5 s, a rebuild at most every 0.1 s.
        encoder.recoveryTimeScale = 0.05
        encoder.refusesRebuildForChecks = true
        let buffer = try movingBuffer(from: noiseRow(noiseShift: 31), index: 0).unwrapped("no buffer")
        try expect(encoder.encode(buffer, at: .zero), "first frame refused")
        waitUntil(timeout: 3) { !log.frames.isEmpty }
        // As a hung encoder service: no output, no error.
        encoder.stallForChecks()
        let start = Date()
        var i = 1
        while !encoder.hasFailed && Date().timeIntervalSince(start) < 3 {
            encoder.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60))
            i += 1
            Thread.sleep(forTimeInterval: 0.016)
        }
        let took = Date().timeIntervalSince(start)
        try expect(encoder.hasFailed, "never gave up")
        try expect(took >= 0.45 && took < 1.5, "gave up after \(took) s")
        encoder.invalidate()
    }

    check("the SPS from the FLV AVC record describes a 1920x1080 BT.709 stream") {
        let run = try encodeRun(count: 10, noiseShift: 31).unwrapped("encoder not created")
        guard let first = run.frames.first, let sps = first.sps, let pps = first.pps else {
            throw CheckFailure(description: "no parameter sets")
        }
        // Read back out of the record the sites get, as their ingest does.
        let record = [UInt8](FLV.avcSequenceHeader(sps: sps, pps: pps))
        try expect(record.count > 16 && record[10] == 0xE1, "record \(record.prefix(16))")
        let spsLength = Int(record[11]) << 8 | Int(record[12])
        let ppsStart = 13 + spsLength + 3
        try expect(record.count >= ppsStart && record[13 + spsLength] == 1, "one PPS expected")
        let ppsLength = Int(record[ppsStart - 2]) << 8 | Int(record[ppsStart - 1])
        let sets = [Array(record[13..<13 + spsLength]), Array(record[ppsStart..<ppsStart + ppsLength])]
        var format: CMFormatDescription?
        let status = sets[0].withUnsafeBufferPointer { a in
            sets[1].withUnsafeBufferPointer { b in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: [a.baseAddress!, b.baseAddress!],
                    parameterSetSizes: [a.count, b.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else { throw CheckFailure(description: "no format description: \(status)") }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        try expect(size.width == 1920 && size.height == 1080, "\(size.width)x\(size.height)")
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        for key in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
                    kCMFormatDescriptionExtension_YCbCrMatrix] {
            try expect(extensions[key as String] as? String == "ITU_R_709_2", "\(key): \(extensions[key as String] ?? "none")")
        }
    }

    check("encode after invalidate does nothing") {
        let log = FrameLog()
        let encoder = try StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { log.add($0) }).unwrapped("encoder not created")
        let row = noiseRow(noiseShift: 31)
        let buffer = try movingBuffer(from: row, index: 0).unwrapped("no buffer")
        encoder.encode(buffer, at: .zero)
        encoder.invalidate()
        let count = log.frames.count
        try expect(!encoder.encode(buffer, at: CMTime(value: 1, timescale: 60)), "encode accepted a frame after invalidate")
        Thread.sleep(forTimeInterval: 0.2)
        try expect(log.frames.count == count, "frames arrived after invalidate")
    }

    check("releasing encoders with frames in flight does not deadlock") {
        let done = DispatchSemaphore(value: 0)
        let row = noiseRow(noiseShift: 28)
        DispatchQueue.global().async {
            for _ in 0..<50 {
                var encoder: StreamVideoEncoder? = StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { _ in })
                for i in 0..<4 {
                    if let buffer = movingBuffer(from: row, index: i) {
                        encoder?.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60))
                    }
                }
                encoder = nil
            }
            done.signal()
        }
        try expect(done.wait(timeout: .now() + 20) == .success, "timed out")
    }

    check("onFrame invalidating while another thread encodes does not deadlock") {
        let done = DispatchSemaphore(value: 0)
        let row = noiseRow(noiseShift: 31)
        DispatchQueue.global().async {
            for _ in 0..<10 {
                var encoder: StreamVideoEncoder?
                encoder = StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { _ in
                    encoder?.invalidate()
                })
                // Keep encoding while the first output invalidates the encoder.
                for i in 0..<30 {
                    if let buffer = movingBuffer(from: row, index: i) {
                        encoder?.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60))
                    }
                }
                encoder?.invalidate()
                encoder = nil
            }
            done.signal()
        }
        try expect(done.wait(timeout: .now() + 20) == .success, "timed out")
    }

    check("a keyframe the guard dropped is delivered on the next frame") {
        // Busy input so the guard is dropping; ask for a keyframe on every dropped-prone frame.
        let log = FrameLog()
        guard let encoder = StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { log.add($0) }) else { throw CheckFailure(description: "encoder not created") }
        let row = noiseRow(noiseShift: 26)
        var refused = -1
        for i in 0..<240 {
            let buffer = try movingBuffer(from: row, index: i).unwrapped("no buffer")
            if i == 0 { encoder.encode(buffer, at: .zero); waitUntil(timeout: 3) { !log.frames.isEmpty }; continue }
            let accepted = encoder.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60), forceKeyframe: refused < 0)
            if !accepted && refused < 0 { refused = i }
            if accepted && refused >= 0 {
                encoder.invalidate()
                let frame = log.frames.last
                try expect(frame?.time == CMTime(value: CMTimeValue(i), timescale: 60) && frame?.keyframe == true, "kept request not applied")
                return
            }
        }
        try expect(refused >= 0, "guard never dropped a frame")
        throw CheckFailure(description: "no frame admitted after the dropped keyframe request")
    }

    check("onFrame of one encoder may invalidate another that is encoding") {
        let done = DispatchSemaphore(value: 0)
        let row = noiseRow(noiseShift: 31)
        let late = FrameLog()
        DispatchQueue.global().async {
            for _ in 0..<10 {
                let closed = NSLock()
                var bClosed = false
                var b: StreamVideoEncoder?
                b = StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { frame in
                    // Busy for a while, then see whether B's invalidate has returned meanwhile.
                    Thread.sleep(forTimeInterval: 0.005)
                    closed.lock(); let after = bClosed; closed.unlock()
                    if after { late.add(frame) }
                })
                var invalidated = false
                let a = StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { _ in
                    guard !invalidated else { return }
                    invalidated = true
                    b?.invalidate()
                    closed.lock(); bClosed = true; closed.unlock()
                })
                let encodingB = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    for i in 0..<60 {
                        if let buffer = movingBuffer(from: row, index: i) { b?.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60)) }
                    }
                    encodingB.signal()
                }
                Thread.sleep(forTimeInterval: 0.05)
                if let buffer = movingBuffer(from: row, index: 0) { a?.encode(buffer, at: .zero) }
                encodingB.wait()
                a?.invalidate()
                b?.invalidate()
            }
            done.signal()
        }
        try expect(done.wait(timeout: .now() + 30) == .success, "timed out")
        try expect(late.frames.isEmpty, "\(late.frames.count) frames from B after its invalidate returned")
    }

    check("two encoders invalidating each other from onFrame do not deadlock") {
        let done = DispatchSemaphore(value: 0)
        let row = noiseRow(noiseShift: 31)
        DispatchQueue.global().async {
            for _ in 0..<10 {
                var a: StreamVideoEncoder?
                var b: StreamVideoEncoder?
                let start = DispatchSemaphore(value: 0)
                // Each holds its delivery open a moment so the two invalidations overlap.
                a = StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { _ in
                    _ = start.wait(timeout: .now() + 0.05); Thread.sleep(forTimeInterval: 0.002); b?.invalidate()
                })
                b = StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { _ in
                    start.signal(); Thread.sleep(forTimeInterval: 0.002); a?.invalidate()
                })
                let group = DispatchGroup()
                for encoder in [a, b] {
                    DispatchQueue.global().async(group: group) {
                        for i in 0..<20 {
                            if let buffer = movingBuffer(from: row, index: i) { encoder?.encode(buffer, at: CMTime(value: CMTimeValue(i), timescale: 60)) }
                        }
                    }
                }
                group.wait()
                start.signal()
                a?.invalidate()
                b?.invalidate()
            }
            done.signal()
        }
        try expect(done.wait(timeout: .now() + 30) == .success, "timed out")
    }

    check("onFrame may invalidate its own encoder") {
        let done = DispatchSemaphore(value: 0)
        var encoder: StreamVideoEncoder?
        let row = noiseRow(noiseShift: 31)
        encoder = StreamVideoEncoder(width: width, height: height, bitrate: 6_000_000, frameRate: 60, onFrame: { _ in
            encoder?.invalidate()
            done.signal()
        })
        let buffer = try movingBuffer(from: row, index: 0).unwrapped("no buffer")
        try expect(encoder?.encode(buffer, at: .zero) == true, "encode refused")
        try expect(done.wait(timeout: .now() + 10) == .success, "timed out")
        encoder = nil
    }
}

private extension Optional {
    func unwrapped(_ message: String) throws -> Wrapped {
        guard let self else { throw CheckFailure(description: message) }
        return self
    }
}
