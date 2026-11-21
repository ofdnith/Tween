#!/bin/zsh
# Compiles the streaming code with the checks in Tests/ and runs them. Prints "all checks passed" or fails.
# Later tasks add their Tween/ files to SOURCES and their check files in Tests/ are picked up by the glob.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=(
  Tween/AMF0.swift
  Tween/FLV.swift
  Tween/RTMPChunk.swift
  Tween/RTMPConnection.swift
  Tween/StreamVideoEncoder.swift
  Tween/StreamAudio.swift
  Tween/MicInput.swift
  Tween/CameraFeed.swift
  Tween/CaptureManager.swift
  Tween/StreamCompositor.swift
  Tween/Recorder.swift
  Tween/StreamKeyStore.swift
  Tween/BroadcastSite.swift
  Tween/Broadcaster.swift
)

mkdir -p build
swiftc -swift-version 5 -parse-as-library -sdk "$(xcrun --show-sdk-path)" -target "$(uname -m)-apple-macos14.0" \
  "${SOURCES[@]}" Tests/*.swift -o build/stream-checks
build/stream-checks "$PWD"
