# Medição

Toda decisão do projeto sai de um número medido no Air M2. Este arquivo diz como medir e guarda os
resultados. Arquivos CSV vão em `docs/medicoes/`.

## Antes de qualquer medição

- Mac na tomada, Modo Pouca Energia desligado.
- Tween fechado ao rodar o bench; nenhum outro app usando a placa ao medir o app. Duas cópias
  dividindo a placa e a GPU distorcem os números.
- Navegador e outros apps pesados fechados.
- Anote a temperatura ambiente aproximada nos testes térmicos.

## 1. Tempo por quadro gerado (etapa 1, sem placa)

```sh
zsh scripts/bench.sh
```

Roda 60 segundos em 1280×720 e 60 segundos em 1920×1080, no ritmo real de uso (30 pares de quadros
por segundo), com quadros sintéticos.

Como ler a saída:

| Coluna | Significado |
|---|---|
| p50, p95, máx | Tempo total para gerar um quadro, em ms: mediana, percentil 95 e pior caso |
| GPU p50 | Só a parte de GPU, pela contagem do Metal |
| térmico | Estado térmico do macOS: nominal, fair, serious, critical |
| veredito | CABE se o p95 total for até 20 ms e nenhuma janela de 10 s passar de 25 ms |

Limite do teste: os quadros são sintéticos. O custo do interpolador deve depender pouco do conteúdo,
mas isso é uma suposição; a qualidade da imagem gerada não é avaliada aqui.

## 2. Teste térmico (etapa 1, sem placa)

```sh
zsh scripts/bench.sh --seconds 1800 --size 1280x720 --csv docs/medicoes/termico-720p.csv
```

Trinta minutos em 720p. O que observar: em que minuto o estado sai de `nominal`, e se o p95 sobe
junto. O bench carrega só o interpolador; o app real também desenha, faz upscaling e toca áudio,
então o aquecimento em uso será um pouco maior.

## 3. Atraso da captura até a tela (etapa 3, com placa)

No Tween, tecla O até as estatísticas completas. A linha LAT é o tempo entre o carimbo de captura do
quadro e o quadro estar na tela. Inclui os 20 a 25 ms da placa e do macOS. Não inclui a saída HDMI
do console nem o atraso do painel.

Anote LAT, fps de entrada e de saída, quadros descartados e ms de GPU depois de alguns minutos com
um jogo a 30 fps. Com V-Sync desligado a linha LAT lê bem menos, mas passa a ser um limite inferior,
não o valor real.

## 4. Atraso de ponta a ponta (etapa 6, com placa)

1. No Tween, tecla L. Um quadrado no canto fica branco enquanto o centro da imagem está claro.
2. No jogo, escolha uma ação que acenda o centro da tela ao apertar um botão.
3. Filme o controle e a tela juntos em câmera lenta a 240 fps.
4. Conte os quadros do vídeo entre o botão afundar e o quadrado mudar. Cada quadro vale 4,2 ms.
5. Repita dez vezes e use a mediana.
6. Faça o mesmo com o Xbox ligado direto na TV em modo jogo, olhando a própria imagem do jogo.

## Resultados

### Tempo por quadro gerado

| Data | Tamanho | p50 | p95 | máx | GPU p50 | Pior janela | Térmico final | Veredito |
|---|---|---|---|---|---|---|---|---|
| 2026-11-21 | 1280×720 | 6,8 | 13,2 | 21,6 | ver nota | 14,3 | fair | CABE |
| 2026-11-21 | 1920×1080 | | | | | | | sem saída neste Mac (ver nota) |

Notas da medição de 2026-11-21 (MacBook Air M2, Mac14,15, 8 GB, macOS 26.5.2, Xcode 26.6, Modo Pouca
Energia desligado):

- O Mac já começou em `fair`, porque o bench rodou logo depois da compilação do app.
- A primeira janela de 10 s teve p95 de 14,3 ms; depois dela o p95 ficou entre 7,4 e 11,8 ms.
- A coluna GPU p50 deu 0,0 ms. O bench mede o command buffer que entrega ao interpolador, e o
  trabalho do interpolador não aparece nele. Enquanto isso não for corrigido, ignore a coluna.
- 1080p não gera saída neste Mac: o resultado foi o mesmo rodando depois de 720p e rodando sozinho
  (scheme `InterpBench-1080p`). O interpolador aceita a sessão em 1920×1080, mas deixa o quadro de
  destino vazio. No app, isso é o caso de "tamanho sem suporte": o modo Full cai no caminho direto,
  sem geração. No Air M2 só existe o modo Fast (720p).
- Dados brutos: `docs/medicoes/bench.csv`.

### Teste térmico de 30 minutos

| Data | Tamanho | Minuto em que saiu de nominal | p95 nos 5 min iniciais | p95 nos 5 min finais | Veredito |
|---|---|---|---|---|---|
| 2026-11-21 | 1280×720 | não saiu de `fair` (começou em `fair`) | 13,0 (pior janela) | 12,8 (pior janela) | CABE |

Notas do teste de 2026-11-21 (180 janelas de 10 s, `docs/medicoes/termico-720p.csv`):

- O estado térmico ficou em `fair` do começo ao fim, com uma passagem por `nominal` entre os minutos
  27 e 29. Nunca chegou a `serious`.
- O p95 não subiu com o tempo: a pior janela de cada bloco de 5 minutos ficou entre 12,8 e 15,3 ms,
  e a média do p95 entre 9,1 e 10,1 ms. A pior janela do teste foi de 15,3 ms, no minuto 10 a 15.
- Houve quadros isolados lentos: máximos de 34 a 62 ms em algumas janelas. Os três maiores (54 a
  62 ms) foram no primeiro minuto, enquanto o Xcode e o git eram usados no mesmo Mac. Um quadro acima
  de 33 ms é um quadro gerado perdido; falta contar quantos são com o Mac em repouso.
- Temperatura ambiente não anotada. O Mac estava em uso leve (navegador aberto) durante o teste.

### Atraso da captura até a tela

| Data | Placa e formato | Geração | LAT | fps saída | GPU ms | Observações |
|---|---|---|---|---|---|---|
| | | desligada | | | | |
| | | Fast | | | | |

### Atraso de ponta a ponta

| Data | Configuração | Mediana (ms) | Observações |
|---|---|---|---|
| | Xbox direto na TV | | |
| | Tween, geração desligada | | |
| | Tween, geração Fast | | |

## Referências externas

| Medição | Valor | Fonte |
|---|---|---|
| Atraso do GTA VI no Series X, com controle e TV | cerca de 180 ms | Digital Foundry |
| Quadro intermediário em 720p / 1080p, M3 | cerca de 10 / 21 ms | Clarion |
| Captura até a tela, sem geração, M3 e MS2130 | 43 a 66 ms | Clarion |
| Captura até a tela, geração Fast, M3 e MS2130 | piso de cerca de 80 ms | Clarion |
