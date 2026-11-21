# Tween

App nativo de macOS que mostra um console em tela cheia no Mac e gera um quadro intermediário entre
cada par de quadros reais, transformando 30 fps em 60 fps. O alvo é um Xbox Series S ligado por placa
de captura HDMI a um MacBook Air M2.

O Tween é um fork do [Clarion](https://github.com/ashenknight-afk/Clarion) (MIT), versão 0.2.0.
Veja [Créditos](#créditos).

## Estado

**Etapa 0 concluída: base importada, ainda não compilada.** O código foi copiado do Clarion e
renomeado de forma mecânica em uma máquina sem Xcode. O primeiro passo é compilar no Mac
(`docs/SETUP.md`) e rodar a medição da etapa 1 (`docs/MEDICAO.md`). O roteiro completo está em
`docs/PLANO.md`.

## O que esperar

- **Imagem:** movimento mais fluido (60 quadros por segundo na tela). Os quadros gerados podem ter
  artefatos em movimentos rápidos e em elementos de HUD.
- **Resposta do controle:** fica mais lenta, não mais rápida. Cada quadro real precisa esperar o
  quadro intermediário ser exibido antes dele.
- **Números de referência (Clarion, M3, placa MS2130, 1080p60):** cerca de 43 a 66 ms da captura até
  a tela sem geração de quadros, e piso de cerca de 80 ms com geração no modo Fast. No Air M2 esses
  números ainda precisam ser medidos.
- **HDR:** não há. A captura é tratada como SDR de 8 bits.

## Requisitos

| Item | Requisito |
|---|---|
| Mac | Apple Silicon; alvo de otimização: MacBook Air M2 |
| macOS | 26 ou mais novo (o interpolador da Apple não existe antes disso) |
| Xcode | 26 ou mais novo, com o Metal Toolchain instalado |
| Placa de captura | UVC (aparece como câmera no macOS), 1080p60 sem compressão; referência: chip MS2130 em modo YUY2 |
| Console | Qualquer um com saída HDMI a 1080p60; alvo: Xbox Series S |

## Começar

1. Siga `docs/SETUP.md` para instalar o Xcode, compilar e abrir o app.
2. Rode `zsh scripts/bench.sh` e anote o resultado em `docs/MEDICAO.md`. Não precisa da placa.
3. Só compre a placa se a etapa 1 passar (critério em `docs/PLANO.md`).

## Teclas

| Tecla | Função |
|---|---|
| Tab ou ⌘, | Ajustes |
| O | Estatísticas: desligadas, compactas, completas |
| F | Geração de quadros |
| U | Upscaling |
| S | Nitidez |
| V | V-Sync (desligado é mais rápido e pode rasgar a imagem) |
| M | Ajustar / Preencher / Esticar |
| A | Som da placa de captura |
| L | Teste de latência |
| P | Captura de tela (Imagens → Tween) |
| R | Iniciar / parar gravação (Filmes → Tween) |

A interface ainda está em inglês, herdada do Clarion.

## Documentação

| Arquivo | Conteúdo |
|---|---|
| `docs/PLANO.md` | Etapas, critérios para seguir ou parar, o que fica de fora |
| `docs/SETUP.md` | Instalação, compilação, permissões, ajustes do Xbox e da placa |
| `docs/AIR-M2.md` | Orçamento de tempo por quadro e perfil de ajustes para o MacBook Air M2 |
| `docs/ARQUITETURA.md` | Caminho do quadro, da placa até a tela, e mapa dos arquivos |
| `docs/MEDICAO.md` | Como medir e onde registrar os resultados |
| `CLAUDE.md` | Regras do projeto para quem (pessoa ou agente) for mexer no código |
| `docs/upstream/` | Documentos originais do Clarion, intactos, com as medições e os becos sem saída |

## Créditos

O código de captura, renderização, interpolação, upscaling, gravação e transmissão vem do
[Clarion](https://github.com/ashenknight-afk/Clarion), de ashenknight-afk, sob licença MIT, a partir
do commit `fa00201` (versão 0.2.0). O ícone também é o do Clarion e deve ser trocado.

## Licença

MIT. Veja `LICENSE`.

O Tween não tem vínculo com Microsoft, Sony, Rockstar Games ou Apple. Os nomes de produtos pertencem
aos respectivos donos.
