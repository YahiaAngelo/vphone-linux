#!/bin/bash
# Builds PerfTest's benchmarks natively for the host (Linux or macOS), to compare with the VM.
set -e
cd "$(dirname "$0")"
swiftc -O -swift-version 5 ../Sources/PerfTest/Bench.swift main.swift -o perftest-host
echo "built $(pwd)/perftest-host"
