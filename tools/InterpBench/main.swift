// InterpBench: mede quanto este Mac leva para gerar um quadro intermediário com o interpolador
// de baixa latência da Apple (VideoToolbox, macOS 26+), o mesmo que o Tween usa.
//
// Não precisa de placa de captura nem de vídeo: usa quadros sintéticos com movimento.
// Roda no ritmo real de uso (30 pares por segundo) para que o aquecimento seja representativo.
//
// Compilar e rodar:  zsh scripts/bench.sh            (720p e 1080p, 60 s cada)
// Teste térmico:     zsh scripts/bench.sh --seconds 1800 --size 1280x720
// Opções: --seconds N   duração por tamanho (padrão 60)
//         --size WxH    tamanho a testar; pode repetir (padrão 1280x720 e 1920x1080)
//         --unpaced     sem pausa entre pares (carga máxima, não representa o uso real)
//         --csv ARQ     grava uma linha por janela de 10 s
//
// As chamadas de VideoToolbox seguem Tween/FrameInterpolator.swift.

import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Metal
import VideoToolbox

// MARK: - Opções

var seconds = 60.0
var sizes: [(width: Int, height: Int)] = []
var paced = true
var csvPath: String?

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--seconds":
        guard let value = arguments.first.flatMap({ Double($0) }), value > 0 else { fatalError("--seconds precisa de um número") }
        seconds = value
        arguments.removeFirst()
    case "--size":
        let parts = (arguments.first ?? "").lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { fatalError("--size precisa de LARGURAxALTURA, por exemplo 1280x720") }
        sizes.append((parts[0], parts[1]))
        arguments.removeFirst()
    case "--unpaced":
        paced = false
    case "--csv":
        guard let value = arguments.first else { fatalError("--csv precisa de um caminho") }
        csvPath = value
        arguments.removeFirst()
    default:
        fatalError("opção desconhecida: \(argument)")
    }
}
if sizes.isEmpty { sizes = [(1280, 720), (1920, 1080)] }

// MARK: - Utilidades

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
    return String(cString: buffer)
}

func thermalName(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "?"
    }
}

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
    return sorted[index]
}

func format(_ value: Double) -> String { String(format: "%5.1f", value) }

/// Um quadro 420v com fundo em gradiente que desliza e três blocos em velocidades diferentes.
func fill(_ buffer: CVPixelBuffer, step: Int) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
    if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let luma = base.assumingMemoryBound(to: UInt8.self)
        let boxes: [(x: Int, y: Int, size: Int)] = [
            ((step * 24) % width, height / 5, height / 6),
            ((width - (step * 40) % width) % width, height / 2, height / 8),
            ((step * 9) % width, (height * 3) / 4, height / 10),
        ]
        for y in 0..<height {
            let row = luma + y * bytesPerRow
            let vertical = (y % 64) / 4
            for x in 0..<width {
                row[x] = UInt8(40 + ((x + 12 * step) % 256) / 2 + vertical)
            }
            for box in boxes where y >= box.y && y < box.y + box.size {
                let end = min(width, box.x + box.size)
                if box.x < end { for x in box.x..<end { row[x] = 220 } }
            }
        }
    }
    if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
    }
}

func zeroLuma(_ buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
        memset(base, 0, CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
    }
}

func centerLuma(_ buffer: CVPixelBuffer) -> UInt8 {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
    let offset = (CVPixelBufferGetHeightOfPlane(buffer, 0) / 2) * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        + CVPixelBufferGetWidthOfPlane(buffer, 0) / 2
    return base.assumingMemoryBound(to: UInt8.self)[offset]
}

// MARK: - Medição

struct Result {
    let width: Int
    let height: Int
    let wallP50: Double
    let wallP95: Double
    let wallMax: Double
    let gpuP50: Double
    let worstWindowP95: Double
    let finalThermal: ProcessInfo.ThermalState
}

func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000) }

func run(width: Int, height: Int, device: MTLDevice, queue: MTLCommandQueue, csv: FileHandle?) -> Result? {
    print("\n== \(width)×\(height) ==")
    guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
        frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1) else {
        print("  tamanho não aceito pelo interpolador")
        return nil
    }
    let processor = VTFrameProcessor()
    do {
        try processor.startSession(configuration: configuration)
    } catch {
        print("  não foi possível iniciar a sessão: \(error.localizedDescription)")
        return nil
    }
    defer { processor.endSession() }

    var attributes = configuration.destinationPixelBufferAttributes
    attributes[kCVPixelBufferMetalCompatibilityKey as String] = true
    var createdPool: CVPixelBufferPool?
    CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                            attributes as CFDictionary, &createdPool)
    guard let pool = createdPool else {
        print("  não foi possível criar os buffers")
        return nil
    }
    func makeBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    // Quadros de entrada prontos de antemão, para a CPU não aquecer o Mac durante a medição.
    let frameCount = 12
    var frames: [CVPixelBuffer] = []
    for step in 0..<frameCount {
        guard let buffer = makeBuffer() else { print("  faltou buffer"); return nil }
        fill(buffer, step: step)
        frames.append(buffer)
    }
    guard let output = makeBuffer() else { print("  faltou buffer"); return nil }
    zeroLuma(output)

    /// Gera o quadro entre `previous` e `current`. Devolve (tempo total, tempo de GPU) em ms.
    func interpolate(_ previous: CVPixelBuffer, _ current: CVPixelBuffer) -> (wall: Double, gpu: Double)? {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let source = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: time(1.0 / 30)),
              let prior = VTFrameProcessorFrame(buffer: previous, presentationTimeStamp: time(0)),
              let destination = VTFrameProcessorFrame(buffer: output, presentationTimeStamp: time(1.0 / 60)),
              let parameters = VTLowLatencyFrameInterpolationParameters(
                sourceFrame: source, previousFrame: prior, interpolationPhase: [0.5], destinationFrames: [destination])
        else { return nil }
        let start = now()
        processor.process(with: commandBuffer, parameters: parameters)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let end = now()
        return ((end - start) * 1000, (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000)
    }

    // Aquecimento, e conferência de que o interpolador escreve mesmo neste tamanho.
    for index in 0..<10 {
        guard interpolate(frames[index % frameCount], frames[(index + 1) % frameCount]) != nil else {
            print("  o interpolador recusou os quadros")
            return nil
        }
    }
    guard centerLuma(output) != 0 else {
        print("  o interpolador não produz saída neste tamanho")
        return nil
    }

    let period = 1.0 / 30
    let begin = now()
    var deadline = begin
    var index = 0
    var allWall: [Double] = [], allGPU: [Double] = []
    var windowWall: [Double] = [], windowGPU: [Double] = []
    var windowStart = begin
    var worstWindowP95 = 0.0
    print("  tempo    p50    p95    máx   GPU p50   térmico")

    func closeWindow(at moment: Double) {
        guard !windowWall.isEmpty else { return }
        let wall = windowWall.sorted(), gpu = windowGPU.sorted()
        let p95 = percentile(wall, 0.95)
        worstWindowP95 = max(worstWindowP95, p95)
        let thermal = thermalName(ProcessInfo.processInfo.thermalState)
        let elapsed = Int((moment - begin).rounded())
        print("  \(String(format: "%4d", elapsed)) s  \(format(percentile(wall, 0.5)))  \(format(p95))  \(format(wall.last ?? 0))    \(format(percentile(gpu, 0.5)))   \(thermal)")
        if let csv {
            let line = "\(width)x\(height),\(elapsed),\(percentile(wall, 0.5)),\(p95),\(wall.last ?? 0),\(percentile(gpu, 0.5)),\(thermal)\n"
            csv.write(line.data(using: .utf8)!)
        }
        windowWall.removeAll(keepingCapacity: true)
        windowGPU.removeAll(keepingCapacity: true)
        windowStart = moment
    }

    while now() - begin < seconds {
        guard let sample = interpolate(frames[index % frameCount], frames[(index + 1) % frameCount]) else {
            print("  o interpolador falhou durante a medição")
            return nil
        }
        index += 1
        allWall.append(sample.wall)
        allGPU.append(sample.gpu)
        windowWall.append(sample.wall)
        windowGPU.append(sample.gpu)
        let moment = now()
        if moment - windowStart >= 10 { closeWindow(at: moment) }
        if paced {
            deadline += period
            let wait = deadline - now()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) } else { deadline = now() }
        }
    }
    closeWindow(at: now())

    let wall = allWall.sorted(), gpu = allGPU.sorted()
    return Result(width: width, height: height, wallP50: percentile(wall, 0.5), wallP95: percentile(wall, 0.95),
                  wallMax: wall.last ?? 0, gpuP50: percentile(gpu, 0.5), worstWindowP95: worstWindowP95,
                  finalThermal: ProcessInfo.processInfo.thermalState)
}

// MARK: - Principal

setvbuf(stdout, nil, _IOLBF, 0)
print("Tween InterpBench")
print("Mac: \(sysctlString("hw.model")) · \(sysctlString("machdep.cpu.brand_string")) · \(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) GB")
print("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("Modo Pouca Energia: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "LIGADO (desligue para medir)" : "desligado")")
print("Estado térmico inicial: \(thermalName(ProcessInfo.processInfo.thermalState))")
print("Ritmo: \(paced ? "30 pares por segundo (uso real)" : "sem pausa (carga máxima)") · \(Int(seconds)) s por tamanho")

guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
    print("\nEste Mac ou este macOS não oferece o interpolador de baixa latência.")
    exit(2)
}
guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    print("\nSem GPU compatível com Metal.")
    exit(2)
}
print("GPU: \(device.name)")

var csv: FileHandle?
if let csvPath {
    if !FileManager.default.fileExists(atPath: csvPath) {
        FileManager.default.createFile(atPath: csvPath,
                                       contents: "tamanho,segundo,p50_ms,p95_ms,max_ms,gpu_p50_ms,termico\n".data(using: .utf8))
    }
    csv = FileHandle(forWritingAtPath: csvPath)
    csv?.seekToEndOfFile()
}

var results: [Result] = []
for size in sizes {
    if let result = run(width: size.width, height: size.height, device: device, queue: queue, csv: csv) {
        results.append(result)
    }
}
csv?.closeFile()

// Critério da etapa 1 (docs/PLANO.md): p95 até 20 ms no total e nenhuma janela de 10 s acima de 25 ms.
print("\n== Resumo ==")
print("  tamanho       p50    p95    máx   GPU p50   pior janela (p95)   térmico final   veredito")
var passed = false
for result in results {
    let ok = result.wallP95 <= 20 && result.worstWindowP95 <= 25
    if ok { passed = true }
    let size = "\(result.width)×\(result.height)".padding(toLength: 10, withPad: " ", startingAt: 0)
    let thermal = thermalName(result.finalThermal).padding(toLength: 13, withPad: " ", startingAt: 0)
    print("  \(size)  \(format(result.wallP50))  \(format(result.wallP95))  \(format(result.wallMax))    \(format(result.gpuP50))        \(format(result.worstWindowP95))           \(thermal)   \(ok ? "CABE" : "NÃO CABE")")
}
print("\nTempos em ms por quadro gerado. O orçamento é 33,3 ms por par de quadros reais, e o app ainda")
print("gasta alguns ms com conversão de cor, upscaling e nitidez; por isso o limite aqui é 20 ms.")
exit(passed ? 0 : 1)
