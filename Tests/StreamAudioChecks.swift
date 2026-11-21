import AVFoundation
import CoreMedia
import Foundation

private let rate = 48_000.0

private func constant(_ value: Float, seconds: Double) -> [Float] {
    [Float](repeating: value, count: Int(seconds * rate) * 2)
}

private func flat(_ blocks: [(samples: [Float], hostTime: Double)]) -> [Float] {
    blocks.flatMap { $0.samples }
}

private func int16MonoBuffer(frames: Int, sampleRate: Double) -> CMSampleBuffer? {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
        mBitsPerChannel: 16, mReserved: 0)
    var format: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                         magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
          let format else { return nil }
    let pcm: [Int16] = (0..<frames).map { Int16(10_000 * sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
    let bytes = pcm.count * 2
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                             customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                             blockBufferOut: &block) == noErr, let block else { return nil }
    guard pcm.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                                              dataLength: bytes) }) == noErr else { return nil }
    var sample: CMSampleBuffer?
    guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
        presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sample) == noErr else { return nil }
    return sample
}

/// Small deterministic generator so jitter runs repeat.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

func streamAudioChecks() {
    let start = 1000.0

    check("mixer with no pushes emits contiguous silence from the start") {
        var mixer = StreamMixer(startHostTime: start)
        let blocks = mixer.pull(now: start + 1)
        try expect(blocks.count > 30, "blocks \(blocks.count)")
        try expect(abs(blocks[0].hostTime - start) < 1e-9, "first at \(blocks[0].hostTime)")
        for (n, block) in blocks.enumerated() {
            try expect(block.samples.count == 2048, "size")
            try expect(abs(block.hostTime - (start + Double(n) * 1024 / rate)) < 1e-9, "time of block \(n)")
        }
        try expect(flat(blocks).allSatisfy { $0 == 0 }, "not silent")
    }

    check("mixer applies volume and mute") {
        var mixer = StreamMixer(startHostTime: start)
        mixer.volume[.mic] = 0.5
        mixer.push(.game, samples: constant(0.25, seconds: 1), hostTime: start)
        mixer.push(.mic, samples: constant(0.5, seconds: 1), hostTime: start)
        let mixed = flat(mixer.pull(now: start + 0.6))
        try expect(mixed.count > 20_000 && mixed.allSatisfy { abs($0 - 0.5) < 1e-6 }, "volume mix")

        var muted = StreamMixer(startHostTime: start)
        muted.micMuted = true
        muted.push(.game, samples: constant(0.25, seconds: 1), hostTime: start)
        muted.push(.mic, samples: constant(0.5, seconds: 1), hostTime: start)
        let quiet = flat(muted.pull(now: start + 0.6))
        try expect(quiet.allSatisfy { abs($0 - 0.25) < 1e-6 }, "muted mix")
    }

    check("mixer clamps the sum") {
        var mixer = StreamMixer(startHostTime: start)
        mixer.push(.game, samples: constant(0.8, seconds: 1), hostTime: start)
        mixer.push(.mic, samples: constant(0.8, seconds: 1), hostTime: start)
        let mixed = flat(mixer.pull(now: start + 0.6))
        try expect(!mixed.isEmpty && mixed.allSatisfy { $0 == 1 }, "not clamped")
    }

    check("a late push leaves silence then the sound") {
        var mixer = StreamMixer(startHostTime: start)
        mixer.push(.game, samples: constant(0.5, seconds: 0.1), hostTime: start)
        // Timeline ends at 0.1 s; the next push starts at 0.3 s.
        mixer.push(.game, samples: constant(0.5, seconds: 0.1), hostTime: start + 0.3)
        let mixed = flat(mixer.pull(now: start + 0.5))
        func frame(_ t: Double) -> Float { mixed[Int(t * rate) * 2] }
        try expect(frame(0.05) == 0.5, "first part")
        try expect(frame(0.12) == 0 && frame(0.28) == 0, "gap not silent")
        try expect(frame(0.35) == 0.5, "second part")
    }

    check("jittered timestamps stay contiguous") {
        var mixer = StreamMixer(startHostTime: start)
        var rng = SystemRandomNumberGenerator()
        let chunk = 0.02
        var blocks: [(samples: [Float], hostTime: Double)] = []
        for i in 0..<100 {
            let jitter = Double.random(in: -0.01...0.01, using: &rng)
            let t = start + 0.1 + Double(i) * chunk
            mixer.push(.game, samples: constant(0.5, seconds: chunk), hostTime: t + jitter)
            blocks += mixer.pull(now: t + chunk + 0.02)
        }
        let mixed = flat(blocks)
        let from = Int(0.15 * rate) * 2, to = Int(1.95 * rate) * 2
        try expect(mixed[from..<to].allSatisfy { $0 != 0 }, "zeros inside at \(mixed[from..<to].firstIndex { $0 == 0 }.map { Double($0 / 2) / rate } ?? -1) of \(mixed.count)")
    }

    check("a fast source stays within 100 ms of the host clock and does not drift away") {
        var mixer = StreamMixer(startHostTime: start)
        let chunk = 0.02
        let samples = constant(0.3, seconds: chunk)
        var worst = 0.0, early = 0.0, late = 0.0
        var zeros = 0
        var t = 0.0 // the source's own clock, running 0.1% fast against the host
        while t < 60 {
            let host = start + 0.05 + t / 1.001
            let now = host + chunk
            mixer.push(.game, samples: samples, hostTime: host)
            for block in mixer.pull(now: now) where t > 1 && block.samples.contains(0) { zeros += 1 }
            let lead = abs(mixer.timelineEnd(.game)! - now)
            worst = max(worst, lead)
            if t < 5 { early = max(early, lead) }
            if t > 55 { late = max(late, lead) }
            t += chunk
        }
        try expect(worst <= 0.1, "timeline off the host clock by \(worst) s")
        try expect(late <= early + 0.005, "grew from \(early) to \(late)")
        try expect(zeros <= 2, "\(zeros) blocks with gaps")
    }

    /// Runs a 100 Hz sine through the mixer and counts places where it is not smooth (a held or skipped frame).
    func discontinuities(chunk: Double, jitter: Double, rateRatio: Double, seconds: Double, seed: UInt64 = 1) -> (breaks: Int, worstLead: Double) {
        var mixer = StreamMixer(startHostTime: start)
        var rng = SplitMix64(state: seed)
        let frames = Int(chunk * rate)
        // One period of the 100 Hz sine (480 frames) is all the signal there is.
        let period: [Float] = (0..<480).map { Float(0.5 * sin(2 * Double.pi * Double($0) / 480)) }
        var t = 0.0
        var out: [Float] = []
        out.reserveCapacity(Int(seconds * rate) * 2 + 4096)
        var worst = 0.0
        // Buffers are whole periods, so every one holds the same samples and keeps the sine continuous.
        precondition(frames % 480 == 0)
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            samples[i * 2] = period[i % 480]
            samples[i * 2 + 1] = period[i % 480]
        }
        while t < seconds {
            let host = start + 0.1 + t / rateRatio
            let j = jitter > 0 ? Double.random(in: -jitter...jitter, using: &rng) : 0
            mixer.push(.game, samples: samples, hostTime: host + j)
            for block in mixer.pull(now: host + chunk) { out.append(contentsOf: block.samples) }
            if t > 5 { worst = max(worst, abs(mixer.timelineEnd(.game)! - (host + chunk))) }
            t += chunk
        }
        var breaks = 0
        let from = Int(0.5 * rate)
        out.withUnsafeBufferPointer { o in
            for i in max(from, 2)..<(o.count / 2) {
                let d2 = o[i * 2] - 2 * o[(i - 1) * 2] + o[(i - 2) * 2]
                if abs(d2) > 3e-4 { breaks += 1 }
            }
        }
        return (breaks, worst)
    }

    for (chunk, jitter) in [(0.01, 0.002), (0.02, 0.005), (0.02, 0.008)] {
        check("an in-sync source with \(Int(jitter * 1000)) ms jitter in \(Int(chunk * 1000)) ms buffers is untouched, 20 seeds") {
            for seed in 1...20 {
                let r = discontinuities(chunk: chunk, jitter: jitter, rateRatio: 1, seconds: 10, seed: UInt64(seed))
                try expect(r.breaks == 0, "seed \(seed): \(r.breaks) held or skipped frames")
            }
        }
    }

    for ratio in [1.001, 0.999] {
        check("a source \(ratio > 1 ? "fast" : "slow") by 0.1% with 5 ms jitter converges gently") {
            let r = discontinuities(chunk: 0.02, jitter: 0.005, rateRatio: ratio, seconds: 60, seed: 7)
            // The host clock against the timeline end: 20 ms is half the resync distance.
            try expect(r.worstLead <= 0.02, "lead \(r.worstLead) s after 5 s")
            // 0.1% of 57 s is about 2700 frames to remove, each showing as two or so; chasing jitter would be far more.
            try expect(r.breaks > 1500 && r.breaks < 6500, "\(r.breaks) breaks")
        }
    }

    check("non-finite times are ignored") {
        var mixer = StreamMixer(startHostTime: start)
        mixer.push(.game, samples: constant(0.5, seconds: 0.1), hostTime: .nan)
        mixer.push(.game, samples: constant(0.5, seconds: 0.1), hostTime: .infinity)
        mixer.push(.game, samples: constant(0.5, seconds: 0.1), hostTime: 1e300)
        try expect(mixer.timelineEnd(.game) == nil, "track created")
        try expect(mixer.pull(now: .nan).isEmpty, "blocks for NaN")
        try expect(mixer.pull(now: .infinity).isEmpty, "blocks for infinity")
    }

    check("a slow source never starves into repeated gaps") {
        var mixer = StreamMixer(startHostTime: start)
        let chunk = 0.02
        let samples = constant(0.3, seconds: chunk)
        var zeros = 0, t = 0.0
        while t < 60 {
            let host = start + 0.05 + t / 0.999
            mixer.push(.game, samples: samples, hostTime: host)
            for block in mixer.pull(now: host + chunk + 0.04) where t > 1 && block.samples.contains(0) { zeros += 1 }
            t += chunk
        }
        try expect(zeros <= 2, "\(zeros) blocks with gaps")
    }

    check("nothing newer than now minus the delay is returned") {
        var mixer = StreamMixer(startHostTime: start)
        let now = start + 2.345
        let blocks = mixer.pull(now: now)
        let last = blocks.last!
        try expect(last.hostTime + 1024 / rate <= now - StreamMixer.delay + 1e-9, "block too new")
        try expect(mixer.pull(now: now).isEmpty, "emitted twice")
    }

    check("a removed source goes silent and holds nothing back") {
        var mixer = StreamMixer(startHostTime: start)
        mixer.push(.game, samples: constant(0.5, seconds: 1), hostTime: start)
        mixer.remove(.game)
        try expect(mixer.queuedSeconds(.game) == 0, "queue kept")
        try expect(flat(mixer.pull(now: start + 0.6)).allSatisfy { $0 == 0 }, "not silent")
    }

    check("sound from before the emitted position is dropped, the rest plays") {
        var mixer = StreamMixer(startHostTime: start)
        let first = mixer.pull(now: start + 1.1)
        let emittedEnd = first.last!.hostTime + 1024 / rate - start
        mixer.push(.game, samples: constant(0.5, seconds: 1), hostTime: start + 0.5) // 0.5 s to 1.5 s
        let blocks = mixer.pull(now: start + 2)
        let mixed = flat(blocks)
        let base = blocks[0].hostTime - start
        func at(_ t: Double) -> Float { mixed[Int((t - base) * rate) * 2] }
        try expect(at(emittedEnd + 0.01) == 0.5 && at(1.4) == 0.5, "on-time part not audible")
        try expect(at(1.6) == 0, "sound after its end")
        let firstAudible = Double(mixed.firstIndex { $0 != 0 }! / 2) / rate + base
        try expect(firstAudible >= emittedEnd - 1e-9, "late part mixed in at \(firstAudible)")
    }

    check("normalizer turns 44.1 kHz mono Int16 into 48 kHz stereo") {
        guard let buffer = int16MonoBuffer(frames: 4410, sampleRate: 44_100) else { throw CheckFailure(description: "no buffer") }
        let out = PCMNormalizer().samples(from: buffer)
        try expect(out != nil, "nil")
        try expect(abs(out!.count - 9600) <= 64, "count \(out!.count)")
        var same = true
        for i in 0..<(out!.count / 2) where out![i * 2] != out![i * 2 + 1] { same = false }
        try expect(same, "left != right")
        try expect(out!.contains { abs($0) > 0.1 }, "silent")
    }

    check("normalizer keeps the first two of many channels, non-interleaved Float") {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 6)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for ch in 0..<6 { for i in 0..<480 { buffer.floatChannelData![ch][i] = Float(ch + 1) / 10 } }
        let out = PCMNormalizer().samples(from: buffer)
        try expect(out != nil && abs(out!.count - 960) <= 64, "count \(out?.count ?? -1)")
        let mid = out!.count / 2
        try expect(abs(out![mid] - 0.1) < 0.01 && abs(out![mid + 1] - 0.2) < 0.01, "channels \(out![mid]) \(out![mid + 1])")
    }

    check("normalizer keeps the first two channels of interleaved Int16") {
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 3)!
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, interleaved: true, channelLayout: layout)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        let p = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Int16.self)
        for i in 0..<480 { p[i * 3] = 3277; p[i * 3 + 1] = -3277; p[i * 3 + 2] = 9999 }
        let out = PCMNormalizer().samples(from: buffer)
        try expect(out != nil && abs(out!.count - 960) <= 64, "count \(out?.count ?? -1)")
        let mid = out!.count / 2
        try expect(abs(out![mid] - 0.1) < 0.01 && abs(out![mid + 1] + 0.1) < 0.01, "channels \(out![mid]) \(out![mid + 1])")
    }

    check("encoder makes AAC frames from a tone") {
        guard let encoder = StreamAudioEncoder() else { throw CheckFailure(description: "no encoder") }
        try expect(encoder.encode([Float](repeating: 0, count: 100)) == nil, "wrong size accepted")
        var frames = 0
        for n in 0..<100 {
            var block = [Float](repeating: 0, count: 2048)
            for i in 0..<1024 {
                let v = Float(0.3 * sin(2 * Double.pi * 440 * Double(n * 1024 + i) / rate))
                block[i * 2] = v
                block[i * 2 + 1] = v
            }
            if let data = encoder.encode(block), !data.isEmpty { frames += 1 }
        }
        try expect(frames >= 98, "frames \(frames)")
    }

    check("AAC frames decode with the 11 90 config back to the tone") {
        guard let encoder = StreamAudioEncoder(),
              let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                 AVNumberOfChannelsKey: 2]),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false),
              let decoder = AVAudioConverter(from: aac, to: pcm) else { throw CheckFailure(description: "no codec") }
        // What the sites get in the AAC sequence header, after its two FLV bytes.
        decoder.magicCookie = FLV.aacSequenceHeader().dropFirst(2)
        var left: [Float] = []
        for n in 0..<60 {
            var block = [Float](repeating: 0, count: 2048)
            for i in 0..<1024 {
                let v = Float(0.3 * sin(2 * Double.pi * 440 * Double(n * 1024 + i) / rate))
                block[i * 2] = v
                block[i * 2 + 1] = v
            }
            guard let packet = encoder.encode(block), !packet.isEmpty else { continue }
            let input = AVAudioCompressedBuffer(format: aac, packetCapacity: 1, maximumPacketSize: packet.count)
            packet.copyBytes(to: input.data.assumingMemoryBound(to: UInt8.self), count: packet.count)
            input.byteLength = UInt32(packet.count)
            input.packetCount = 1
            input.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                        mDataByteSize: UInt32(packet.count))
            guard let output = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 1024) else { continue }
            var given = false
            var error: NSError?
            let status = decoder.convert(to: output, error: &error) { _, inputStatus in
                if given { inputStatus.pointee = .noDataNow; return nil }
                given = true
                inputStatus.pointee = .haveData
                return input
            }
            try expect(status != .error && error == nil, "decode failed: \(String(describing: error))")
            left += UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))
        }
        try expect(left.count >= 50 * 1024, "only \(left.count) frames decoded")
        // Past the codec's priming: the tone's strength at 440 Hz, as an amplitude.
        let tail = left.suffix(30 * 1024)
        var real = 0.0, imaginary = 0.0
        for (i, value) in tail.enumerated() {
            real += Double(value) * cos(2 * Double.pi * 440 * Double(i) / rate)
            imaginary += Double(value) * sin(2 * Double.pi * 440 * Double(i) / rate)
        }
        let level = 2 * (real * real + imaginary * imaginary).squareRoot() / Double(tail.count)
        try expect(level > 0.2, "tone level \(level)")
    }
}
