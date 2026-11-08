#!/usr/bin/env bash
# Run the existing cache suite against the production Linux cache and confinement files.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
harness=$root/.build/staged-cache-harness
mkdir -p "$harness/Sources/VPhoneCoreKit" "$harness/Tests" "$harness/Shims"
for name in VPhoneConfinedDirectory VPhoneDyldCacheAudit VPhoneStagedDyldCache VPhoneStagedDyldCacheRecovery; do
  cp "$root/Sources/VPhoneCoreKit/Process/$name.swift" "$harness/Sources/VPhoneCoreKit/$name.swift"
done
for name in LinuxSys VLDarwin VLCryptoKit; do
  mkdir -p "$harness/Shims/$name"
  cp -R "$root/Shims/$name/." "$harness/Shims/$name/"
done
cp "$root/Tests/VPhoneStagedDyldCacheTests/StagedDyldCacheTests.swift" "$harness/Tests/"
cat > "$harness/Package.swift" <<'SWIFT'
// swift-tools-version:6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .unsafeFlags(["-Xfrontend", "-import-module", "-Xfrontend", "VLDarwin",
                  "-Xfrontend", "-import-module", "-Xfrontend", "FoundationNetworking"]),
]

let package = Package(
    name: "vphone-staged-cache-tests",
    dependencies: [.package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1")],
    targets: [
        .target(name: "LinuxSys", path: "Shims/LinuxSys"),
        .target(name: "VLDarwin", dependencies: ["LinuxSys"], path: "Shims/VLDarwin"),
        .target(name: "VLCryptoKit", dependencies: [.product(name: "Crypto", package: "swift-crypto")], path: "Shims/VLCryptoKit"),
        .target(name: "VPhoneCoreKit", dependencies: ["VLDarwin", "VLCryptoKit"],
                path: "Sources/VPhoneCoreKit", swiftSettings: swiftSettings),
        .testTarget(name: "VPhoneStagedDyldCacheTests", dependencies: ["VPhoneCoreKit", "VLDarwin", "VLCryptoKit"],
                    path: "Tests", swiftSettings: swiftSettings),
    ]
)
SWIFT
exec "${SWIFT:-swift}" test --package-path "$harness" --jobs "${SWIFT_JOBS:-2}" "$@"
