#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$PROJECT_DIR/.build"
CHECK_DIR="$(mktemp -d "$PROJECT_DIR/.build/discovery-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc "$PROJECT_DIR"/Sources/GuardianCore/*.swift \
    "$PROJECT_DIR/Tests/GuardianCoreTests/DiscoveryRegressionChecks.swift" \
    "$PROJECT_DIR/scripts/check-discovery.swift" -o "$CHECK_DIR/check-discovery"
"$CHECK_DIR/check-discovery"
