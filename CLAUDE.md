# Tween

App nativo de macOS (Swift 5, SwiftUI, AVFoundation, Metal/MetalFX, VideoToolbox) que exibe um
console capturado por placa HDMI USB com o menor atraso possível e gera quadros intermediários
(30 → 60 fps). Fork do Clarion 0.2.0 (MIT). Sem dependências de terceiros, sem drivers, sandboxed.

- Máquina alvo: MacBook Air M2 (sem ventoinha, tela de 60 Hz), macOS 26. Fonte alvo: Xbox Series S
  a 1080p60 por placa MS2130.
- Roteiro e critérios de cada etapa: `docs/PLANO.md`. Sempre confira em que etapa o projeto está
  antes de propor trabalho.
- Caminho do quadro e mapa de arquivos: `docs/ARQUITETURA.md`.
- Perfil e pendências do Air M2: `docs/AIR-M2.md`.

## Comandos

- Compilar: `xcodebuild -project Tween.xcodeproj -scheme Tween -derivedDataPath build build`
- Abrir: `open build/Build/Products/Release/Tween.app`
- Verificar tipos sem o Xcode:
  `swiftc -typecheck -parse-as-library -swift-version 5 -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos14.0 Tween/*.swift`
- Medir o interpolador: `zsh scripts/bench.sh` (feche o Tween antes)
- O projeto usa pastas sincronizadas: todo arquivo em `Tween/` entra no alvo automaticamente.
  `Config/` só é referenciado pelas configurações de build.

## Regras de trabalho

1. **Conservador.** Só interpolação com o interpolador da Apple. Nada de extrapolação, RIFE ou
   modelos próprios (lista completa em "Fora do escopo" no plano).
2. **Medir antes e depois.** Mudança no renderizador, na captura ou na apresentação só entra com os
   números de `docs/MEDICAO.md` antes e depois, medidos no Air M2. Registre os resultados no arquivo.
3. **Uma mudança por commit**, compilando a cada passo. A base foi renomeada sem compilar: se algo
   não compila, corrija isso primeiro e em um commit separado.
4. **Não reinventar o que já foi medido.** Antes de mexer em `Tween/Renderer.swift`, leia
   `docs/upstream/CLARION-NOTES.md`. Ele lista o que foi tentado e abandonado, com números. Os nomes
   de tipos e funções lá continuam valendo; só "Clarion" virou "Tween".
5. **Otimizar para o Air M2.** Modo Fast (720p) é o padrão. Qualquer recurso novo precisa caber no
   orçamento de 33,3 ms por par de quadros com folga para aquecimento.
6. **APIs do macOS 26 atrás de `#available`**, como o código já faz, e alternância escondida quando
   não houver suporte.

## Regras de latência (não regredir)

- Captura sem compressão (YUY2 ou UYVY, depois 420v). MJPEG só por escolha do usuário.
- `alwaysDiscardsLateVideoFrames = true`; quadros tratados em fila serial `.userInteractive`.
- Sem cópias na CPU: CVPixelBuffer → CVMetalTextureCache → MTLTexture.
- No máximo um quadro em andamento; `maximumDrawableCount = 2` e `framebufferOnly = true` no caminho
  direto. Três drawables só enquanto a geração de quadros está ativa.
- A thread de captura nunca desenha; quem apresenta é a `presentQueue`.
- Não usar `CAMetalDisplayLink`.
- Não remover o `LatencyGovernor` nem "consertar" o quadro pulado de vez em quando: é ele que mantém
  a fila da tela vazia.
- Um `VTFrameProcessor` novo por sessão.
- Quando nada exigir, manter o caminho de passe único (conversão direto no drawable).

## Convenções

- Documentação em português do Brasil. Comentários de código e nomes em inglês, como na base.
- `docs/upstream/` é referência e não se edita.
- Não versionar `build/`, `export/` nem arquivos de usuário do Xcode (`.gitignore` já cobre).
- Ao terminar uma etapa do plano, atualize o estado em `README.md` e em `docs/PLANO.md`.
