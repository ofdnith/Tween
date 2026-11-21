import Metal
import MetalFX

/// Scales an RGB frame at source resolution up to the video area's size.
/// MetalFX spatial where supported, otherwise a separable Lanczos-3. Sized resources are reused
/// frame to frame, which is safe because the renderer keeps only one frame in flight.
final class Upscaler {
    enum Kind: String, CaseIterable, Identifiable {
        case metalFX, lanczos

        var id: String { rawValue }

        var label: String {
            switch self {
            case .metalFX: return "MetalFX"
            case .lanczos: return "Lanczos"
            }
        }
    }

    let supportsMetalFX: Bool

    private let device: MTLDevice
    private let lanczosHorizontal: MTLRenderPipelineState
    private let lanczosVertical: MTLRenderPipelineState

    private var input: MTLTexture?
    private var lanczosTemp: MTLTexture?
    private var lanczosOutput: MTLTexture?
    private var spatialScaler: MTLFXSpatialScaler?
    private var spatialOutput: MTLTexture?
    /// Sizes MetalFX refused, so we don't retry every frame.
    private var spatialFailedFor: (Int, Int, Int, Int)?

    init(device: MTLDevice, library: MTLLibrary) throws {
        func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        self.device = device
        supportsMetalFX = MTLFXSpatialScalerDescriptor.supportsDevice(device)
        lanczosHorizontal = try pipeline("lanczosHorizontal", .rgba16Float)
        lanczosVertical = try pipeline("lanczosVertical", .bgra8Unorm)
    }

    /// Render target for the YCbCr → RGB pass, at the (cropped) source size.
    func inputTexture(width: Int, height: Int) -> MTLTexture? {
        if let input, input.width == width, input.height == height { return input }
        input = makeTexture(width: width, height: height, format: .bgra8Unorm, usage: [.renderTarget, .shaderRead])
        return input
    }

    /// Encodes `source` → a texture of the output size. Returns it with the name of the scaler that ran.
    func encode(source: MTLTexture, outputWidth: Int, outputHeight: Int,
                kind: Kind, commandBuffer: MTLCommandBuffer) -> (MTLTexture, String)? {
        if kind == .metalFX, supportsMetalFX,
           let (scaler, output) = spatial(inWidth: source.width, inHeight: source.height,
                                          outWidth: outputWidth, outHeight: outputHeight) {
            scaler.colorTexture = source
            scaler.outputTexture = output
            scaler.inputContentWidth = source.width
            scaler.inputContentHeight = source.height
            scaler.encode(commandBuffer: commandBuffer)
            return (output, "MetalFX Spatial")
        }

        if lanczosTemp?.width != outputWidth || lanczosTemp?.height != source.height {
            lanczosTemp = makeTexture(width: outputWidth, height: source.height, format: .rgba16Float,
                                      usage: [.renderTarget, .shaderRead])
        }
        if lanczosOutput?.width != outputWidth || lanczosOutput?.height != outputHeight {
            lanczosOutput = makeTexture(width: outputWidth, height: outputHeight, format: .bgra8Unorm,
                                        usage: [.renderTarget, .shaderRead])
        }
        guard let temp = lanczosTemp, let output = lanczosOutput else { return nil }
        draw(source, into: temp, pipeline: lanczosHorizontal, commandBuffer: commandBuffer)
        draw(temp, into: output, pipeline: lanczosVertical, commandBuffer: commandBuffer)
        return (output, "Lanczos-3")
    }

    private func spatial(inWidth: Int, inHeight: Int, outWidth: Int, outHeight: Int) -> (MTLFXSpatialScaler, MTLTexture)? {
        if let scaler = spatialScaler, let output = spatialOutput,
           scaler.inputWidth == inWidth, scaler.inputHeight == inHeight,
           scaler.outputWidth == outWidth, scaler.outputHeight == outHeight {
            return (scaler, output)
        }
        if let failed = spatialFailedFor, failed == (inWidth, inHeight, outWidth, outHeight) { return nil }

        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = inWidth
        descriptor.inputHeight = inHeight
        descriptor.outputWidth = outWidth
        descriptor.outputHeight = outHeight
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual

        guard let scaler = descriptor.makeSpatialScaler(device: device),
              let output = makeTexture(width: outWidth, height: outHeight, format: .bgra8Unorm,
                                       usage: scaler.outputTextureUsage.union(.shaderRead)) else {
            spatialFailedFor = (inWidth, inHeight, outWidth, outHeight)
            spatialScaler = nil
            spatialOutput = nil
            return nil
        }
        spatialScaler = scaler
        spatialOutput = output
        return (scaler, output)
    }

    private func draw(_ texture: MTLTexture, into target: MTLTexture, pipeline: MTLRenderPipelineState,
                      commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func makeTexture(width: Int, height: Int, format: MTLPixelFormat, usage: MTLTextureUsage) -> MTLTexture? {
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }
}
