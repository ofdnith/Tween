#!/bin/bash
# Importa o Clarion (MIT) como base do Tween: copia, renomeia e aplica os ajustes iniciais.
# Registro de como a base foi gerada (Clarion no commit fa00201). Já foi executado; não rode de novo
# sobre o projeto. Precisa do sed do GNU (Linux); no macOS o `sed -i` tem outra sintaxe.
# Uso: import-upstream.sh <pasta do clone do Clarion> <pasta de saída (nova, vazia)>
set -euo pipefail
SRC=$(cd "$1" && pwd)
OUT=$2
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

# 1. Código e recursos, sem o histórico git e sem os documentos de topo (reescritos para o Tween).
(cd "$SRC" && tar cf - --exclude=./.git --exclude=./README.md --exclude=./CLAUDE.md \
    --exclude=./LICENSE --exclude=./docs --exclude=./.gitignore .) | (cd "$OUT" && tar xf -)

# 2. Documentos originais, intactos, como referência.
mkdir -p "$OUT/docs/upstream"
cp "$SRC/README.md"    "$OUT/docs/upstream/CLARION-README.md"
cp "$SRC/CLAUDE.md"    "$OUT/docs/upstream/CLARION-NOTES.md"
cp "$SRC/docs/PLAN.md" "$OUT/docs/upstream/CLARION-PLAN.md"
cp "$SRC/LICENSE"      "$OUT/docs/upstream/CLARION-LICENSE"

cd "$OUT"

# 3. Nomes de pastas e arquivos.
mv Clarion Tween
mv Clarion.xcodeproj Tween.xcodeproj
mv Config/Clarion.entitlements Config/Tween.entitlements
mv Tween/ClarionApp.swift Tween/TweenApp.swift
mv "packaging/How to open Clarion.txt" "packaging/How to open Tween.txt"

# 4. Nomes dentro dos arquivos de texto (nunca em docs/upstream nem em imagens).
find . -type f \( -name '*.swift' -o -name '*.metal' -o -name '*.pbxproj' -o -name '*.plist' \
    -o -name '*.entitlements' -o -name '*.sh' -o -name '*.txt' -o -name '*.xcworkspacedata' \) \
    -not -path './docs/upstream/*' -print0 |
  xargs -0 sed -i \
    -e 's/io\.github\.ashenknight-afk\.clarion/io.github.ofdnith.tween/g' \
    -e 's/CLARION/TWEEN/g' -e 's/Clarion/Tween/g' -e 's/clarion/tween/g'

# 5. Ajustes iniciais do Tween.
# 5a. Geração de quadros ligada por padrão (é o propósito do app); "Fast" (720p) já é o padrão.
sed -i 's|frameGenerationEnabled = defaults.bool(forKey: Key.frameGeneration)|frameGenerationEnabled = defaults.object(forKey: Key.frameGeneration) as? Bool ?? true|' Tween/Settings.swift
grep -q 'Key.frameGeneration) as? Bool ?? true' Tween/Settings.swift
sed -i 's|/// Off by default: it adds latency.|/// On by default in Tween: 30→60 is what the app is for. It adds latency.|' Tween/Settings.swift

# 5b. Versão própria.
sed -i 's/MARKETING_VERSION = 0.2.0;/MARKETING_VERSION = 0.1.0;/g' Tween.xcodeproj/project.pbxproj

# 6. Conferência: nenhum "clarion" pode sobrar fora de docs/upstream.
if grep -rIil clarion . --exclude-dir=upstream; then
  echo "ERRO: ainda há referências a Clarion nos arquivos acima" >&2
  exit 1
fi
echo "import ok: $(find . -type f | wc -l) arquivos"
