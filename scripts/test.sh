#!/bin/bash
set -euo pipefail
PROJECT=$(cd "$(dirname "$0")/.." && pwd)
cd "$PROJECT"
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
  Sources/Health.swift Sources/Diagnostics.swift Sources/ServiceProtocol.swift Tests/main.swift -o .build/test-health
.build/test-health
# Compile privileged entry points even in the public build, without installing
# or executing them and without requiring the private collector.
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
  Sources/Health.swift Sources/ServiceProtocol.swift Service/main.swift -o .build/test-service-build
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
  Sources/Health.swift Sources/ServiceProtocol.swift Service/Installer.swift -o .build/test-installer-build
