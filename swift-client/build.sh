#!/bin/zsh
set -eu
cd -- "${0:A:h}/.."
mkdir -p .build
swift build --package-path swift-client --scratch-path .build/swift-client -c release --product torus-client
cp .build/swift-client/release/torus-client .build/torus-client
