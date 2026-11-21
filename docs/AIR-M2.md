# Perfil do MacBook Air M2

O que muda no projeto por causa da máquina alvo, e por quê. Os números marcados como "Clarion" foram
medidos pelo autor original em um MacBook com M3. Os do Air M2 foram medidos na etapa 1, em 2026-11-21 (`docs/MEDICAO.md`).

## A máquina

| Característica | Valor | Consequência |
|---|---|---|
| GPU | M2, 8 ou 10 núcleos | Mais lenta que a do M3 usado nas medições do Clarion |
| Refrigeração | sem ventoinha | O desempenho cai em sessões longas, quando o chassi satura |
| Tela | 2560×1664 a 60 Hz | A área 16:9 útil é 2560×1440; não há 120 Hz |
| Portas | duas USB-C (Thunderbolt) | A placa ocupa uma; a energia vai pelo MagSafe |

## Orçamento de tempo

Com jogo a 30 fps, chega um quadro real a cada 33,3 ms. Nesse intervalo o app precisa gerar um
quadro intermediário e desenhar dois quadros (o gerado e o real).

| Trabalho por par de quadros | Clarion, M3 | Air M2 |
|---|---|---|
| Quadro intermediário em 720p (Fast) | cerca de 10 ms | 6,8 ms (p50), 13,2 ms (p95) |
| Quadro intermediário em 1080p (Full) | cerca de 21 ms | o interpolador não gera saída |
| GPU total por quadro, Fast | cerca de 12 ms | a medir |
| GPU total por quadro, Full com MetalFX | cerca de 23 ms | a medir |

Se o M2 for de 20% a 40% mais lento que o M3 (estimativa, não medição), o modo Fast fica entre 12 e
17 ms e cabe com folga, e o modo Full fica entre 25 e 32 ms, no limite dos 33,3 ms e sem margem para
aquecimento. Por isso o perfil do Air é o modo Fast.

Medido em 2026-11-21: o modo Fast ficou abaixo da estimativa (p95 de 13,2 ms em 60 s e pior janela
de 15,3 ms em 30 minutos), e o modo Full não existe neste Mac, porque o interpolador não escreve
saída em 1920×1080. A etapa 5 deve esconder ou desabilitar a opção Full quando o tamanho não tiver
suporte, em vez de deixar a geração parar em silêncio.

Usar 720p para o quadro intermediário custa pouco na imagem por dois motivos: o Series S renderiza o
jogo em 720p por dentro, e o Tween mantém da imagem real os pixels que não se movem (HUD, texto,
minimapa), de modo que eles continuam nítidos nos quadros gerados.

## Perfil aplicado

| Ajuste | Valor | Onde está |
|---|---|---|
| Geração de quadros | ligada por padrão | `Tween/Settings.swift`, `frameGenerationEnabled` |
| Quadros intermediários | Fast (720p) por padrão | `Tween/Settings.swift`, `frameGenerationFast` |
| Formato de captura | 1080p YUY2 preferido | `Tween/CaptureManager.swift`, `defaultFormat` |
| Upscaling | MetalFX espacial, 1080p → 1440p | `Tween/Upscaler.swift` |
| V-Sync | ligado | `Tween/Settings.swift`, `displaySyncEnabled` |

Os três últimos já eram o padrão do Clarion. A única mudança de código feita até aqui foi ligar a
geração de quadros por padrão.

## Uso recomendado

- Mac na tomada e Modo Pouca Energia desligado. O Modo Pouca Energia limita a GPU.
- Mac sobre superfície dura, com a tampa aberta. Sobre tecido ou no colo o chassi satura mais cedo.
- Brilho da tela abaixo do máximo em sessões longas: a tela também aquece o chassi.
- Outros apps pesados fechados, em especial navegadores com vídeo.
- Placa ligada direto na porta USB-C.

## A fazer na etapa 5

### Governador térmico

Hoje o app não reage ao aquecimento. Proposta:

1. Ler `ProcessInfo.processInfo.thermalState` e observar `ProcessInfo.thermalStateDidChangeNotification`.
2. Mostrar o estado na linha de estatísticas, para que a queda de qualidade tenha explicação visível.
3. Em `serious`: forçar o modo Fast, mesmo que o usuário tenha escolhido Full.
4. Em `critical`: desligar o upscaling e, se ainda assim a saída cair de 60 fps, suspender a geração.
5. Voltar ao ajuste do usuário só depois de um tempo em `nominal` ou `fair`, para não ficar alternando.

O ponto natural para isso é `AppSettings.renderConfig` em `Tween/Settings.swift`, que já monta a
configuração enviada ao renderizador. Trocar entre Fast e Full reinicia a sessão do interpolador;
conferir a nota sobre `VTFrameProcessor` em `docs/upstream/CLARION-NOTES.md` antes de mexer.

### Modo Jogo do macOS

O Modo Jogo dá prioridade de CPU e GPU ao app em tela cheia. A verificar: se ele ativa com a janela
sem bordas do Tween e se exige `LSApplicationCategoryType` de jogo em `Config/Info.plist` (hoje é
`public.app-category.video`). Só adotar se os números de `docs/MEDICAO.md` melhorarem.

### Quedas do Series S

O Series S cai para vinte e poucos fps em cenas pesadas. Medir o comportamento atual nesses trechos
(fps de saída e artefatos) antes de decidir entre manter a geração ou suspendê-la enquanto a queda
durar.

### Custo do upscaling na tela do Air

O salto de 1080p para 1440p é pequeno. Medir os ms de GPU com upscaling ligado e desligado; se a
diferença na imagem não compensar o tempo, o padrão do Air passa a ser Lanczos ou desligado.
