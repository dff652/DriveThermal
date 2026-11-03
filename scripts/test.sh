#!/bin/bash
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
cd "$PROJECT"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
  Sources/Health.swift Sources/Diagnostics.swift Tests/main.swift -o .build/test-health
.build/test-health
