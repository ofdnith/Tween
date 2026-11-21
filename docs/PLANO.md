# Plano do Tween

Abordagem conservadora: interpolação 30→60 com o interpolador de baixa latência da Apple, sobre o
código do Clarion. Sem extrapolação, sem modelos de IA próprios. Cada etapa tem um critério para
seguir ou parar; nenhuma etapa começa antes de a anterior passar.

## Metas

| Meta | Valor | Origem |
|---|---|---|
| Saída na tela | 60 quadros por segundo estáveis com jogo a 30 fps | objetivo do projeto |
| Tempo por quadro gerado no Air M2 | p95 até 20 ms | orçamento de 33,3 ms por par, menos conversão, upscaling e nitidez |
| Atraso da captura até a tela, com geração | até 85 ms | Clarion mediu piso de cerca de 80 ms (M3, MS2130, modo Fast) |
| Sessão longa sem ventoinha | 30 minutos sem cair de 60 fps | o Air M2 não tem ventoinha |

O jogo já tem cerca de 180 ms de atraso próprio (medição da Digital Foundry no Series X, incluindo
controle e TV). O Tween não reduz esse número; a meta é somar o mínimo possível.

## Etapas

### Etapa 0: base importada (concluída)

- Código do Clarion 0.2.0 copiado e renomeado para Tween (`tools/import-upstream.sh`).
- Geração de quadros ligada por padrão, modo Fast (quadros intermediários em 720p).
- Documentação e ferramenta de medição (`tools/InterpBench/main.swift`) escritas.

### Etapa 1: compilar e medir no Air, sem placa (concluída em 2026-11-21)

1. Instalar o Xcode e compilar o app (`docs/SETUP.md`).
2. Corrigir o que a renomeação tiver quebrado, se algo quebrar.
3. Rodar `zsh scripts/bench.sh` (dois minutos) e depois o teste térmico de 30 minutos em 720p.
4. Registrar os números em `docs/MEDICAO.md`.

**Segue se:** o app compila e abre, e o bench dá veredito CABE em 1280×720, inclusive no teste de
30 minutos.
**Para se:** 720p não cabe em 20 ms. Nesse caso o Air M2 não sustenta a abordagem e não vale comprar
a placa.

**Resultado:** seguiu. O app compilou sem correções e abre. Veredito CABE em 1280×720 (p95 de 13,2 ms
em 60 s; pior janela de 15,3 ms em 30 minutos). 1080p não gerou saída no bench e ficou para
investigar; não bloqueia, porque o padrão é 720p. Pelo Xcode, o bench roda pelos schemes
`InterpBench`, `InterpBench-Termico` e `InterpBench-1080p`.

### Etapa 2: comprar a placa de captura

- Placa UVC com chip MS2130, que entrega 1080p60 em YUY2 por USB 3.0. É a única placa com a qual o
  Clarion foi medido.
- Adaptador ou cabo USB-C, se a placa vier com USB-A. Ligar direto no Mac, sem hub.

### Etapa 3: primeira execução com a placa

1. Ajustar o Xbox (`docs/SETUP.md`) e abrir o Tween.
2. Conferir nos Ajustes: formato 1920×1080 YUY2 a 60 fps, geração de quadros ligada, modo Fast.
3. Ler a linha LAT das estatísticas (tecla O) com um jogo a 30 fps, por alguns minutos.
4. Registrar em `docs/MEDICAO.md`: LAT, fps de saída, quadros descartados, ms de GPU.

**Segue se:** 60 fps de saída e LAT até 85 ms.
**Se não:** investigar com as notas de `docs/upstream/CLARION-NOTES.md` antes de mudar o renderizador.

### Etapa 4: enxugar o que não é do Tween (em andamento, branch `etapa-4-enxugar`)

Adiantada em 2026-11-21, antes da etapa 3, porque a placa ainda não foi comprada. Fica em um branch
separado; o `main` continua sendo a base medida na etapa 1. Nada aqui toca o renderizador nem a
captura.

Feito, cada item em um commit e compilando no Air:

- Transmissão ao vivo removida: RTMP, codificador, webcam, microfone, composição, chaves e a seção
  de transmissão dos Ajustes, com as referências em `TweenApp.swift`, `Settings.swift`,
  `SettingsView.swift`, `Overlay.swift` e `Recorder.swift`. O app caiu de cerca de 8.500 para 4.200
  linhas de Swift.
- Pasta `Tests/` e `scripts/check-stream.sh` removidos.
- Permissão de rede retirada de `Config/Tween.entitlements`; textos de câmera e microfone em
  `Config/Info.plist` ajustados.
- A captura de janela (`WindowCapture.swift`) fica: serve para testar sem placa e para o
  experimento com o Remote Play do Xbox.

Falta:

- Trocar o ícone e traduzir a interface.
- Depois da etapa 3, repetir as medições de `docs/MEDICAO.md` neste branch antes de juntá-lo ao
  `main`.

### Etapa 5: ajustes para o Air M2 e para o Series S

Detalhes e justificativas em `docs/AIR-M2.md`.

- Mostrar o estado térmico nas estatísticas e reduzir a carga quando o Mac esquentar.
- Tratar as quedas do Series S abaixo de 30 fps: medir o que o renderizador faz hoje quando os
  quadros reais chegam com mais de dois refreshes de distância e decidir se a geração deve ser
  suspensa nesses trechos.
- Ajustar a nitidez padrão para a imagem do Series S (720p interno reconstruído para 1080p).
- Testar se o Modo Jogo do macOS ativa com o app e se muda os números.

### Etapa 6: medição de ponta a ponta e decisão

1. Teste de latência com celular a 240 fps (`docs/MEDICAO.md`), comparando TV direta e Tween.
2. Meia hora de jogo real.

**Decisão final:** manter o projeto se a fluidez compensar o atraso a mais na prática.

## Fora do escopo

- Extrapolação de quadros, RIFE e qualquer modelo de IA próprio.
- HDR.
- Macs Intel e outros consoles (podem funcionar, mas não são testados).
- Transmissão ao vivo.
