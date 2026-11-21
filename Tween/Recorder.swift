import AppKit
import AVFoundation
import Combine
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Saves what Tween shows: screenshots (PNG in Pictures/Tween) and recordings (.mp4 with the
/// game's sound in Movies/Tween). The renderer hands over finished, already-enhanced frames only
/// while one of the two is wanted, so normal play pays nothing for this.
/// Control methods run on the main thread; frames and sound arrive on other threads.
final class Recorder: ObservableObject {
    @Published private(set) var startedAt: Date?
    /// A short-lived note for the overlay ("Screenshot saved", an error…).
    @Published private(set) var notice: String?

    var isRecording: Bool { startedAt != nil }

    /// Main thread: turn the renderer's frame hand-over on or off.
    var onWantsFrames: ((Bool) -> Void)?
    /// Main thread: ask the source for its sound while recording.
    var onWantsAudio: ((Bool) -> Void)?
    /// Main thread. While true the frames also go to the stream, so the stats are drawn on a copy.
    var sharesFrames = false {
        didSet {
            let shared = sharesFrames
            queue.async { self.sharing = shared }
        }
    }

    private let queue = DispatchQueue(label: "tween.recorder", qos: .userInitiated)
    private var noticeTimer: Timer?

    /// One row of the stats panel, as drawn into a recording.
    struct StatLine: Equatable {
        let label: String
        let value: String
    }

    // queue only
    private var statLines: [StatLine]?
    private var statsImage: (lines: [StatLine], scale: CGFloat, image: CGImage)?
    private var wantsScreenshot = false
    private var sharing = false
    private var copyPool: CVPixelBufferPool?
    private var recording = false
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var frameSize = (width: 0, height: 0)
    private var sessionStart = CMTime.invalid
    private var lastVideoTime = CMTime.invalid

    static func folder(_ directory: FileManager.SearchPathDirectory) -> URL? {
        guard let base = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent("Tween", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            return nil
        }
    }

    // MARK: - Main thread

    func takeScreenshot() {
        queue.async {
            self.wantsScreenshot = true
            self.updateWants()
        }
    }

    /// The stats to draw into screenshots and recordings, or nil to leave them out. The on-screen
    /// overlay is drawn by the window system over the video, so it is never part of the picture itself.
    func setStats(_ lines: [StatLine]?) {
        queue.async { self.statLines = lines }
    }

    func toggleRecording() {
        if isRecording {
            stop()
        } else {
            startedAt = Date()
            onWantsAudio?(true)
            queue.async {
                self.recording = true
                self.updateWants()
            }
        }
    }

    /// Finishes the file. `completion` runs on the main thread once it is safe to quit.
    func stop(completion: (() -> Void)? = nil) {
        startedAt = nil
        onWantsAudio?(false)
        queue.async {
            self.recording = false
            self.updateWants()
            self.finish(completion: completion)
        }
    }

    // MARK: - Any thread

    /// A finished picture and the host time it reached the screen.
    func handle(frame: CVPixelBuffer, at hostTime: CFTimeInterval) {
        queue.async { self.process(frame, at: CMTime(seconds: hostTime, preferredTimescale: 1_000_000_000)) }
    }

    /// Game sound. `hostTime` is given when the buffer's own timestamp is on another clock.
    func handle(audio sampleBuffer: CMSampleBuffer, at hostTime: CMTime? = nil) {
        queue.async {
            guard self.recording, let writer = self.writer, writer.status == .writing,
                  let input = self.audioInput, input.isReadyForMoreMediaData else { return }
            var sample = sampleBuffer
            if let hostTime {
                var timing = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr else { return }
                timing.presentationTimeStamp = hostTime
                var retimed: CMSampleBuffer?
                CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                                                      sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                                      sampleBufferOut: &retimed)
                guard let retimed else { return }
                sample = retimed
            }
            // Sound from before the first picture has nothing to go with.
            guard CMSampleBufferGetPresentationTimeStamp(sample) >= self.sessionStart else { return }
            input.append(sample)
        }
    }

    // MARK: - queue

    private func updateWants() {
        let wants = recording || wantsScreenshot
        DispatchQueue.main.async { self.onWantsFrames?(wants) }
    }

    /// The buffer to draw the stats on: the frame itself, or a copy of it when someone else uses
    /// the frame too. Nil when the copy can't be made.
    static func drawingTarget(for frame: CVPixelBuffer, shared: Bool, pool: inout CVPixelBufferPool?) -> CVPixelBuffer? {
        guard shared else { return frame }
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        let format = CVPixelBufferGetPixelFormatType(frame)
        if let existing = pool,
           let attributes = CVPixelBufferPoolGetPixelBufferAttributes(existing) as? [CFString: Any],
           attributes[kCVPixelBufferWidthKey] as? Int != width || attributes[kCVPixelBufferHeightKey] as? Int != height
            || attributes[kCVPixelBufferPixelFormatTypeKey] as? OSType != format {
            pool = nil
        }
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        }
        guard let pool, !CVPixelBufferIsPlanar(frame) else { return nil }
        var copy: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &copy)
        guard let copy, CVPixelBufferLockBaseAddress(frame, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard CVPixelBufferLockBaseAddress(copy, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(copy, []) }
        guard let source = CVPixelBufferGetBaseAddress(frame), let target = CVPixelBufferGetBaseAddress(copy) else { return nil }
        let sourceStride = CVPixelBufferGetBytesPerRow(frame), targetStride = CVPixelBufferGetBytesPerRow(copy)
        let rowBytes = min(sourceStride, targetStride)
        for y in 0..<height {
            memcpy(target + y * targetStride, source + y * sourceStride, rowBytes)
        }
        return copy
    }

    private func process(_ frame: CVPixelBuffer, at time: CMTime) {
        var frame = frame
        if let statLines, wantsScreenshot || recording,
           let target = Self.drawingTarget(for: frame, shared: sharing, pool: &copyPool) {
            // The stream must never show the stats: without a copy they are left out.
            drawStats(statLines, on: target)
            frame = target
        }
        if wantsScreenshot {
            wantsScreenshot = false
            updateWants()
            saveScreenshot(frame)
        }
        guard recording else { return }

        let size = (width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
        if writer == nil {
            guard startWriter(size: size, at: time) else {
                abort("Couldn't start recording")
                return
            }
        } else if size != frameSize {
            // A video file has one picture size; a new display or scaling mode needs a new file.
            abort("Recording stopped: the picture size changed")
            return
        }
        guard let writer, writer.status == .writing else {
            abort("Recording failed: \(self.writer?.error?.localizedDescription ?? "unknown error")")
            return
        }
        guard let videoInput, let adaptor, videoInput.isReadyForMoreMediaData,
              !lastVideoTime.isValid || time > lastVideoTime else { return }
        if adaptor.append(frame, withPresentationTime: time) { lastVideoTime = time }
    }

    private func startWriter(size: (width: Int, height: Int), at time: CMTime) -> Bool {
        guard let folder = Self.folder(.moviesDirectory) else { return false }
        let url = folder.appendingPathComponent("Tween \(Self.timestamp()).mp4")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }

        // About 30 Mbit/s at 4K-ish sizes, 12 at 1080p: clean for fast game footage.
        let bitrate = max(8_000_000, size.width * size.height * 6)
        func settings(_ codec: AVVideoCodecType) -> [String: Any] {
            [AVVideoCodecKey: codec, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
             AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: 60,
                                               AVVideoAllowFrameReorderingKey: false]]
        }
        // HEVC where the Mac can encode it, else H.264.
        let videoSettings = writer.canApply(outputSettings: settings(.hevc), forMediaType: .video) ? settings(.hevc) : settings(.h264)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000])
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { return false }
        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: time)

        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.audioInput = audioInput
        frameSize = size
        sessionStart = time
        lastVideoTime = .invalid
        return true
    }

    private func abort(_ reason: String) {
        recording = false
        updateWants()
        finish(failure: reason, completion: nil)
        DispatchQueue.main.async {
            self.startedAt = nil
            self.onWantsAudio?(false)
        }
    }

    private func finish(failure: String? = nil, completion: (() -> Void)?) {
        guard let writer else {
            if let failure { show(failure) }
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        self.writer = nil
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        videoInput = nil
        adaptor = nil
        audioInput = nil
        sessionStart = .invalid
        guard writer.status == .writing, lastVideoTime.isValid else {
            // Nothing usable was written: don't leave an empty file behind.
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: writer.outputURL)
            show(failure ?? "Recording was empty")
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        writer.finishWriting {
            self.show(failure ?? (writer.status == .completed
                                  ? "Recording saved in Movies → Tween"
                                  : "Recording failed: \(writer.error?.localizedDescription ?? "unknown error")"))
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    private func saveScreenshot(_ frame: CVPixelBuffer) {
        guard let folder = Self.folder(.picturesDirectory), let image = Self.image(from: frame) else {
            show("Couldn't save the screenshot")
            return
        }
        let url = folder.appendingPathComponent("Tween \(Self.timestamp()).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            show("Couldn't save the screenshot")
            return
        }
        CGImageDestinationAddImage(destination, image, nil)
        show(CGImageDestinationFinalize(destination) ? "Screenshot saved in Pictures → Tween" : "Couldn't save the screenshot")
    }

    /// Draws the stats panel into the frame's top-left corner, like the on-screen overlay. The panel
    /// is rendered once per change of text (twice a second); each frame only gets it blended in.
    private func drawStats(_ lines: [StatLine], on frame: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        // Sized like the overlay on a Retina screen, smaller on smaller pictures.
        let scale = min(3, max(1, CGFloat(width) / 1470))
        if statsImage?.lines != lines || statsImage?.scale != scale {
            statsImage = Self.renderStats(lines, scale: scale).map { (lines, scale, $0) }
        }
        guard let image = statsImage?.image,
              CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(frame, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(frame, []) }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: CVPixelBufferGetBaseAddress(frame), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(frame),
                                      space: space, bitmapInfo: info) else { return }
        let inset = 24 * scale
        context.draw(image, in: CGRect(x: inset, y: CGFloat(height) - inset - CGFloat(image.height),
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
    }

    /// The stats panel as an image with a transparent background: same font, colours and spacing as `StatsOverlay`.
    private static func renderStats(_ lines: [StatLine], scale: CGFloat) -> CGImage? {
        guard !lines.isEmpty else { return nil }
        let font = NSFont.monospacedSystemFont(ofSize: 13 * scale, weight: .medium)
        func line(_ text: String, alpha: CGFloat) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: NSColor(white: 1, alpha: alpha)]))
        }
        let rows = lines.map { (label: line($0.label, alpha: 0.55), value: line($0.value, alpha: 1)) }
        func width(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }
        let labelWidth = rows.map { width($0.label) }.max() ?? 0
        let valueWidth = rows.map { width($0.value) }.max() ?? 0
        let ascent = CTFontGetAscent(font), rowHeight = (ascent + CTFontGetDescent(font) + CTFontGetLeading(font)).rounded(.up)
        let padX = 14 * scale, padY = 10 * scale, gap = 12 * scale, rowGap = 3 * scale
        let size = CGSize(width: (padX * 2 + labelWidth + gap + valueWidth).rounded(.up),
                          height: (padY * 2 + rowHeight * CGFloat(rows.count) + rowGap * CGFloat(rows.count - 1)).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.addPath(CGPath(roundedRect: CGRect(origin: .zero, size: size), cornerWidth: 10 * scale,
                               cornerHeight: 10 * scale, transform: nil))
        context.setFillColor(CGColor(gray: 0, alpha: 0.62))
        context.fillPath()
        for (index, row) in rows.enumerated() {
            let baseline = size.height - padY - ascent - CGFloat(index) * (rowHeight + rowGap)
            context.textPosition = CGPoint(x: padX, y: baseline)
            CTLineDraw(row.label, context)
            context.textPosition = CGPoint(x: padX + labelWidth + gap, y: baseline)
            CTLineDraw(row.value, context)
        }
        return context.makeImage()
    }

    /// Copies a BGRA frame into a CGImage.
    private static func image(from frame: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(frame, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: CVPixelBufferGetBaseAddress(frame), width: CVPixelBufferGetWidth(frame),
                                      height: CVPixelBufferGetHeight(frame), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(frame), space: space, bitmapInfo: info) else { return nil }
        return context.makeImage()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return formatter.string(from: Date())
    }

    private func show(_ text: String) {
        DispatchQueue.main.async {
            self.notice = text
            self.noticeTimer?.invalidate()
            self.noticeTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
                self.notice = nil
            }
        }
    }
}
