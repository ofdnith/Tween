#!/bin/zsh
# Compila e roda o InterpBench (tools/InterpBench/main.swift): tempo por quadro gerado neste Mac.
# Precisa do Xcode 26 ou mais novo (SDK do macOS 26). Opções: veja o topo de tools/InterpBench/main.swift.
#   zsh scripts/bench.sh
#   zsh scripts/bench.sh --seconds 1800 --size 1280x720 --csv docs/medicoes/termico-720p.csv
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build docs/medicoes
swiftc -O -swift-version 5 -sdk "$(xcrun --show-sdk-path)" -target arm64-apple-macos26.0 \
  tools/InterpBench/main.swift -o build/interp-bench
build/interp-bench "$@"
