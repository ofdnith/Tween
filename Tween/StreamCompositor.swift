import Metal
import CoreVideo
import CoreGraphics

enum StreamQuality: Int, CaseIterable {
    case p1080 = 1080, p1440 = 1440, p2160 = 2160

    var size: (width: Int, height: Int) {
        switch self {
        case .p1080: return (1920, 1080)
        case .p1440: return (2560, 1440)
        case .p2160: return (3840, 2160)
        }
    }

    /// The largest canvas ≤ wanted whose height ≤ frameHeight and that `hardware` accepts. 1080p is
    /// kept even for a smaller frame; nil only when the hardware refuses everything.
    static func choose(wanted: StreamQuality, frameHeight: Int, hardware: (Int, Int) -> Bool) -> StreamQuality? {
        for quality in allCases.reversed() where quality.rawValue <= wanted.rawValue {
            if quality != .p1080 && quality.size.height > frameHeight { continue }
            if hardware(quality.size.width, quality.size.height) { return quality }
        }
        return nil
    }
}

enum StreamCorner: String, CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

enum StreamCameraSize: String, CaseIterable {
    case small, medium, large

    /// Share of the canvas width.
    var fraction: CGFloat {
        switch self {
        case .small: return 0.15
        case .medium: return 0.20
        case .large: return 0.28
        }
    }
}

struct CameraLayout: Equatable {
    var corner: StreamCorner
    var size: StreamCameraSize
}

/// Mirrors `StreamQuadParams` in Stream.metal.
private struct StreamQuadParams {
    var rect: SIMD4<Float>
    var uvRect: SIMD4<Float>
    var canvas: SIMD4<Float>
    var source: SIMD4<Float>
}

/// Scales the finished game picture into a fixed 16:9 canvas and draws the webcam in a corner. Has its
/// own queue, texture cache and pools, so it never touches the renderer.
final class StreamCompositor {
    enum CompositorError: Error { case setupFailed(String) }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let lock = NSLock()
    private var pools: [Int: CVPixelBufferPool] = [:]

    static func gameRect(source: CGSize, canvas: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0 else { return .zero }
        let scale = min(canvas.width / source.width, canvas.height / source.height)
        let width = source.width * scale, height = source.height * scale
        return CGRect(x: (canvas.width - width) / 2, y: (canvas.height - height) / 2, width: width, height: height)
    }

    static func cameraRect(canvas: CGSize, aspect: CGFloat, layout: CameraLayout) -> CGRect {
        let width = canvas.width * layout.size.fraction
        let height = width / aspect
        let margin = canvas.width * 0.02
        let left = layout.corner == .topLeft || layout.corner == .bottomLeft
        let top = layout.corner == .topLeft || layout.corner == .topRight
        return CGRect(x: left ? margin : canvas.width - margin - width,
                      y: top ? margin : canvas.height - margin - height,
                      width: width, height: height)
    }

    init(device: MTLDevice, library: MTLLibrary) throws {
        guard let queue = device.makeCommandQueue() else { throw CompositorError.setupFailed("command queue") }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "streamQuadVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "streamScaleFragment")
        guard descriptor.vertexFunction != nil, descriptor.fragmentFunction != nil else {
            throw CompositorError.setupFailed("shader functions")
        }
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        // The canvas stays opaque: the camera's antialiased edge must not leave it translucent.
        attachment.sourceAlphaBlendFactor = .zero
        attachment.destinationAlphaBlendFactor = .one
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw CompositorError.setupFailed("texture cache") }
        self.device = device
        self.queue = queue
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        textureCache = cache
    }

    /// Draws on its own command queue; `completion` runs on a Metal thread, or on a global queue when
    /// it fails before any GPU work, so never before this returns. Black canvas when `game` is nil.
    func compose(game: CVPixelBuffer?, camera: CVPixelBuffer?, layout: CameraLayout?,
                 canvas: (width: Int, height: Int), completion: @escaping (CVPixelBuffer?) -> Void) {
        func fail() { DispatchQueue.global().async { completion(nil) } }
        guard canvas.width > 0, canvas.height > 0,
              let output = outputBuffer(width: canvas.width, height: canvas.height),
              let (outputTexture, outputRef) = texture(output),
              let commands = queue.makeCommandBuffer() else { return fail() }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = outputTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return fail() }
        encoder.setRenderPipelineState(pipeline)

        let canvasSize = CGSize(width: canvas.width, height: canvas.height)
        var held: [Any] = [outputRef]
        var failed = false

        func draw(_ buffer: CVPixelBuffer, rect: CGRect, crop: SIMD4<Float>, radius: Float) {
            guard let (source, ref) = texture(buffer) else { failed = true; return }
            held.append(ref)
            var params = StreamQuadParams(
                rect: SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height)),
                uvRect: crop,
                canvas: SIMD4(Float(canvas.width), Float(canvas.height), radius, 0),
                source: SIMD4(Float(source.width), Float(source.height), 0, 0))
            encoder.setVertexBytes(&params, length: MemoryLayout<StreamQuadParams>.stride, index: 0)
            encoder.setFragmentBytes(&params, length: MemoryLayout<StreamQuadParams>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        if let game {
            let size = CGSize(width: CVPixelBufferGetWidth(game), height: CVPixelBufferGetHeight(game))
            draw(game, rect: Self.gameRect(source: size, canvas: canvasSize), crop: SIMD4(0, 0, 1, 1), radius: 0)
        }
        if let camera, let layout {
            let width = CGFloat(CVPixelBufferGetWidth(camera)), height = CGFloat(CVPixelBufferGetHeight(camera))
            let wide: CGFloat = 16.0 / 9.0
            // Centre-crop to 16:9, never stretch.
            var crop = SIMD4<Float>(0, 0, 1, 1)
            if width / height > wide {
                let kept = Float(wide * height / width)
                crop = SIMD4((1 - kept) / 2, 0, kept, 1)
            } else {
                let kept = Float(width / wide / height)
                crop = SIMD4(0, (1 - kept) / 2, 1, kept)
            }
            let rect = Self.cameraRect(canvas: canvasSize, aspect: wide, layout: layout)
            draw(camera, rect: rect, crop: crop, radius: Float(rect.width * 0.04))
        }
        encoder.endEncoding()
        // Textures still in use are retained by `held`; this only drops unused cache entries.
        CVMetalTextureCacheFlush(textureCache, 0)
        if failed { return fail() }

        commands.addCompletedHandler { buffer in
            withExtendedLifetime(held) {}
            completion(buffer.status == .completed ? output : nil)
        }
        commands.commit()
    }

    private func texture(_ buffer: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        var ref: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm,
                CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &ref) == kCVReturnSuccess,
              let ref, let texture = CVMetalTextureGetTexture(ref) else { return nil }
        return (texture, ref)
    }

    private func outputBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let pool: CVPixelBufferPool? = {
            lock.lock()
            defer { lock.unlock() }
            let key = width << 20 | height
            if let existing = pools[key] { return existing }
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
                kCVPixelBufferMetalCompatibilityKey: true]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pools[key] = created
            return created
        }()
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        // The same BT.709 tags as the encoder session, so the RGB to YUV conversion matches the SPS.
        if let buffer {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        return buffer
    }
}
