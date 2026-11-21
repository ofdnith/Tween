# Preparação e uso

Passo a passo para compilar o Tween no MacBook Air M2 e ligar o Xbox Series S.

## 1. Instalar as ferramentas

1. Instale o **Xcode 26 ou mais novo** pela App Store. O interpolador só existe no SDK do macOS 26,
   então versões anteriores do Xcode não compilam o projeto.
2. Abra o Xcode uma vez e aceite a instalação dos componentes.
3. No Terminal, aponte as ferramentas de linha de comando para o Xcode e instale o Metal Toolchain:

   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   xcodebuild -downloadComponent MetalToolchain
   ```

4. Confira:

   ```sh
   xcodebuild -version      # Xcode 26 ou mais novo
   xcrun --show-sdk-version # 26 ou mais novo
   ```

## 2. Publicar a base no GitHub

A pasta ainda não é um repositório git. No Terminal:

```sh
cd ~/Documents/Tween
git init -b main
git add .
git commit -m "Base inicial: fork do Clarion 0.2.0 renomeado para Tween"
git remote add origin https://github.com/ofdnith/Tween.git
git push -u origin main
```

Se o repositório no GitHub já tiver algum commit (um README criado pelo site, por exemplo), rode
`git pull origin main --allow-unrelated-histories` antes do `git push`.

## 3. Compilar

```sh
cd ~/Documents/Tween
xcodebuild -project Tween.xcodeproj -scheme Tween -derivedDataPath build build
open build/Build/Products/Release/Tween.app
```

Ou abra `Tween.xcodeproj` no Xcode e pressione ⌘R. O projeto usa pastas sincronizadas: qualquer
arquivo colocado em `Tween/` entra no app sem precisar ser adicionado ao projeto.

Se a compilação falhar, o erro mais provável é algum nome que a renomeação Clarion → Tween deixou
inconsistente. Anote o erro e corrija antes de seguir; não mexa em mais nada nesse commit.

### Assinatura e permissões

O app é assinado de forma ad hoc. O macOS liga as permissões de Câmera e Gravação de Tela à
assinatura, então ele pede as permissões de novo a cada recompilação. Para evitar isso, abra o
projeto no Xcode, vá em Signing & Capabilities e escolha o seu time pessoal (basta um Apple ID
gratuito).

## 4. Medir sem a placa (etapa 1)

```sh
zsh scripts/bench.sh
```

Leva cerca de dois minutos. Antes de rodar: Mac na tomada, Modo Pouca Energia desligado, outros apps
pesados fechados, Tween fechado. O que fazer com o resultado está em `docs/MEDICAO.md`.

## 5. Ajustar o Xbox Series S

Em Configurações → Geral → Opções de TV e exibição (os nomes podem variar com a versão do sistema):

| Ajuste | Valor | Motivo |
|---|---|---|
| Resolução | 1080p | É o máximo da placa sem compressão e do interpolador |
| Taxa de atualização | 60 Hz | A placa captura a 60 Hz; o jogo repete cada quadro |
| Permitir 4K | desligado | Evita que o console tente negociar 4K com a placa |
| Permitir HDR10, Auto HDR, Dolby Vision | desligados | A placa captura em SDR; com HDR a imagem fica lavada |
| Permitir taxa de atualização variável | desligado | A placa não suporta VRR |
| Profundidade de cor | 8 bits | É o que a placa entrega |

## 6. Ligar a placa de captura

1. Xbox → cabo HDMI → entrada HDMI da placa.
2. Placa → porta USB-C do Mac, direto, sem hub. Com hub ou cabo USB 2.0 a placa pode cair para vídeo
   comprimido (MJPEG), que tem mais atraso.
3. Mac na tomada.
4. Abra o Tween. Permita **Câmera** (é o vídeo da placa) e **Microfone** (é o som do jogo).
5. Feche qualquer outro app que use a placa (OBS, QuickTime, Photo Booth). Só um app por vez
   consegue abri-la.

## 7. Conferir os ajustes do Tween

Pressione Tab para abrir os Ajustes e O para ver as estatísticas.

| Ajuste | Valor para o Air M2 |
|---|---|
| Source | Capture card |
| Formato | 1920×1080 · YUY2 · 60 fps |
| Frame generation | ligado |
| In-between frames | Fast (720p) |
| Upscaling | MetalFX |
| Sharpening | ligado, 0,5 para começar |
| V-Sync | ligado (a geração de quadros depende dele para o ritmo) |

Nas estatísticas, o esperado com um jogo a 30 fps é: entrada perto de 30 fps depois de descartar os
repetidos, saída a 60 fps e LAT estável.

## 8. Som

O som do jogo chega pela placa e o Tween o reproduz (tecla A liga e desliga). Use fones com fio ou
os alto-falantes do Mac; fones Bluetooth somam atraso de áudio perceptível.

## Verificar mudanças sem o Xcode aberto

```sh
swiftc -typecheck -parse-as-library -swift-version 5 -sdk "$(xcrun --show-sdk-path)" \
  -target arm64-apple-macos14.0 Tween/*.swift
```
