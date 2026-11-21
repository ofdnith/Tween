# Arquitetura

Tudo roda na GPU com frameworks da Apple (AVFoundation, Metal, MetalFX, VideoToolbox,
ScreenCaptureKit). Não há dependências de terceiros nem drivers, e o app é sandboxed.

## Caminho do quadro

```
placa de captura ─▶ AVCaptureVideoDataOutput (YUY2 / UYVY / 420v; quadros atrasados são descartados)
        ─▶ CVMetalTextureCache (sem cópia, sobre IOSurface)
        ─▶ [geração: cópia em 420v → VTFrameProcessor → trava de pixels parados]
        ─▶ YCbCr → RGB ─▶ [upscaling MetalFX ou Lanczos] ─▶ [nitidez CAS]
        ─▶ CAMetalLayer ─▶ tela
```

### Sem geração de quadros

A thread de captura entrega cada quadro a uma fila de apresentação e retorna. A fila espera a tela
poder receber um quadro e só então desenha o mais novo; um quadro mais antigo que ainda estava
esperando é substituído, não enfileirado. São dois drawables e no máximo um quadro em andamento.

### Com geração de quadros

1. **Descarte de repetidos.** Um jogo a 30 fps em sinal de 60 Hz manda cada quadro duas vezes. O
   `RepeatDetector` aprende o ritmo real/repetido e descarta os repetidos.
2. **Quadro intermediário.** O par de quadros reais é convertido para 420v no tamanho de
   interpolação (720p no modo Fast, 1080p no Full) e o `FrameInterpolator` pede ao VideoToolbox o
   quadro do meio, dentro do mesmo command buffer do Metal.
3. **Trava de pixels parados.** Pixels que não mudam há cinco quadros reais (HUD, texto) são
   copiados do quadro real para o gerado, no tamanho original.
4. **Apresentação.** Uma fila separada apresenta o quadro gerado e, um refresh depois, o real. São
   três drawables nesse modo.
5. **Governador de latência.** Como a saída é produzida no mesmo ritmo em que a tela consome, um
   quadro que entra na fila nunca sai sozinho. O `LatencyGovernor` percebe e pula um quadro gerado
   para esvaziar a fila.

Quando não dá para interpolar (fonte já a 60 fps, tamanho não suportado), o quadro segue pelo
caminho direto.

## De onde vem o atraso

| Parcela | Valor de referência (Clarion, M3, MS2130) |
|---|---|
| Placa e macOS entregando o quadro | 20 a 25 ms |
| Caminho direto até a tela, V-Sync ligado | 43 a 66 ms no total |
| Com geração de quadros, modo Fast | piso de cerca de 80 ms no total |

O atraso mínimo da geração é inevitável: o quadro real só pode aparecer depois do quadro
intermediário que vem antes dele.

## Mapa dos arquivos

| Arquivo | Papel |
|---|---|
| `Tween/TweenApp.swift` | Entrada do app, ligação entre as partes, teclas |
| `Tween/CaptureManager.swift` | Sessão de captura da placa, escolha de formato |
| `Tween/Renderer.swift` | Todo o caminho de desenho, geração e apresentação |
| `Tween/FrameInterpolator.swift` | `FrameProbe`, `RepeatDetector` e o interpolador do VideoToolbox |
| `Tween/Upscaler.swift` | MetalFX espacial e Lanczos |
| `Tween/Shaders.metal`, `Tween/Sharpen.metal` | Conversão de cor, Lanczos, nitidez |
| `Tween/DisplayManager.swift` | Telas, janela sem bordas, camada Metal |
| `Tween/AudioPassthrough.swift` | Som da placa para a saída do Mac |
| `Tween/Settings.swift`, `Tween/SettingsView.swift` | Preferências e tela de ajustes |
| `Tween/Overlay.swift` | Estatísticas e avisos sobre o vídeo |
| `Tween/Recorder.swift` | Capturas de tela e gravação |
| `Tween/WindowCapture.swift` | Captura da janela de outro app (útil para testar sem placa) |
| Demais arquivos em `Tween/` | Transmissão ao vivo, a remover na etapa 4 |
| `Config/` | `Info.plist` e permissões |
| `tools/InterpBench.swift` | Medição do interpolador, independente do app |

## Regras que não podem regredir

As regras de latência e os becos sem saída já medidos estão em `docs/upstream/CLARION-NOTES.md`. Leia
antes de mudar `Renderer.swift`. As principais:

- Captura sem compressão; MJPEG só se o usuário escolher.
- Nenhuma cópia na CPU: CVPixelBuffer → CVMetalTextureCache → MTLTexture.
- Dois drawables no caminho direto, três só enquanto gera quadros.
- A thread de captura nunca desenha.
- Não usar `CAMetalDisplayLink`: ele escolhe quadros três refreshes à frente.
- Um `VTFrameProcessor` novo por sessão; reiniciar um já encerrado derruba o app.
