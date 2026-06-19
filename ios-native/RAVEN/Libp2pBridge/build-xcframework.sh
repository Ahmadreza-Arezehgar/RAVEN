#!/usr/bin/env bash
# Build the serverless libp2p bridge as an iOS xcframework via gomobile.
#
# Prereqs (one-time):
#   brew install go
#   go install golang.org/x/mobile/cmd/gomobile@latest
#   go install golang.org/x/mobile/cmd/gobind@latest
#   (Xcode must be installed — gomobile uses it for the iOS toolchain.)
#
# Output: RavenLibp2p.xcframework (device arm64 + simulator arm64/x86_64).
# Then in Xcode: drag RavenLibp2p.xcframework into the RAVEN target →
# "Embed & Sign". See README.md.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="$HOME/go/bin:$PATH"

echo "▶ go mod tidy"
go mod tidy

echo "▶ go build (host sanity check)"
go build ./...

echo "▶ gomobile bind → RavenLibp2p.xcframework (heavy)"
rm -rf RavenLibp2p.xcframework
gomobile bind -target=ios,iossimulator -o RavenLibp2p.xcframework .

echo "✅ built:"
du -sh RavenLibp2p.xcframework
