import Foundation
import Img4tool
import Testing
import VLCryptoKit
import VPhonePatchKit
@testable import FirmwarePatcher

struct RestoreTXMTests {
    static var fixture: String? { ProcessInfo.processInfo.environment["VPHONE_RESTORE_TXM_187_100_3"] }

    private struct Metadata: Decodable {
        let containerSHA256: String
        let payloadSHA256: String
        let payloadSize: Int
        let legacyPayloadSHA256: String
    }

    private func metadata() throws -> Metadata {
        let metadataURL = try #require(Bundle.module.url(
            forResource: "release-187.100.3", withExtension: "json", subdirectory: "Fixtures",
        ))
        return try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
    }

    private func withFixture(_ body: (URL, Data) throws -> Void) throws {
        let metadata = try metadata()
        let input = try Data(contentsOf: URL(fileURLWithPath: #require(Self.fixture)))
        try #require(SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined() == metadata.containerSHA256)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("txm.im4p")
        try input.write(to: url)
        let payload = try IM4PHandler.load(contentsOf: url).payload
        try #require(payload.count == metadata.payloadSize)
        try #require(SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined() == metadata.payloadSHA256)
        try body(url, payload)
    }

    private func pipeline(_ url: URL) -> FirmwarePipeline {
        FirmwarePipeline(vmDirectory: url.deletingLastPathComponent(), variant: .jb, verbose: false, noBinpack: true)
    }

    @Test(arguments: [
        ("TrustedExecutionMonitor_Guarded-999.1.2\0", "TrustedExecutionMonitor_Guarded-999.1.2"),
        ("no embedded build", "unknown build"),
        ("TrustedExecutionMonitor-" + String(repeating: "9", count: 160), "unknown build"),
    ])
    func reportsUnsupportedBuildWithoutWriting(payload: String, label: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("txm.raw")
        let original = Data(payload.utf8)
        try original.write(to: url)
        do {
            _ = try pipeline(url).patchRestoreTXMPrecheckFile(at: url)
            Issue.record("unsupported restore TXM was accepted")
        } catch let error as PatcherError {
            #expect(error.description.contains("restore TXM \(label) is unsupported:"))
            #expect(error.description.contains("requires the original native policy pre-check"))
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test(.enabled(if: fixture != nil))
    func preservesNativeClassificationAndContainer() throws {
        try withFixture { url, original in
            let container = try IM4PHandler.load(contentsOf: url).im4p
            let selector = TXMDevPatcher(data: original, verbose: false)
            selector.patchSelector24ForcePass()
            try #require(selector.patches.map(\.patchID) == [
                "txm-boot-selector24_bypass.mov", "txm-boot-selector24_bypass.b",
            ])
            _ = try selector.apply()
            // Pinned-image expectations from the shared research fixture. The
            // release image has identical classifier instructions at these sites.
            var expected = selector.patchedData
            expected.replaceSubrange(0x31a60 ..< 0x31a64, with: ARM64.movX0_0)
            expected.replaceSubrange(0x30a28 ..< 0x30a2c, with: ARM64.nop)
            expected.replaceSubrange(0x32070 ..< 0x32074, with: ARM64.nop)
            expected.replaceSubrange(0x30824 ..< 0x30828, with: try #require(ARM64Encoder.encodeCompareBranch(
                nonzero: false, register: 0, from: 0x30824, to: 0x30a24, width64: true,
            )))
            expected.replaceSubrange(0x33080 ..< 0x33088, with:
                try #require(ARM64Encoder.encodeMovzW(rd: 21, imm16: 7))
                    + #require(ARM64Encoder.encodeB(from: 0x33084, to: 0x32f50)))

            #expect(try pipeline(url).patchRestoreTXMPrecheckFile(at: url) == 7)
            let output = try IM4PHandler.load(contentsOf: url)
            #expect(output.payload == expected)
            #expect(output.im4p?.fourcc == container?.fourcc)
            #expect(output.im4p?.description == container?.description)
            if let input = container?.data, let start = IM4PHandler.paypStart(in: input) {
                let rebuilt = try #require(output.im4p?.data)
                let rebuiltStart = try #require(IM4PHandler.paypStart(in: rebuilt))
                #expect(input[start...] == rebuilt[rebuiltStart...])
            }
        }
    }

    @Test(.enabled(if: fixture != nil))
    func refusesAlreadyBypassedCacheLookupWithoutWriting() throws {
        try withFixture { url, original in
            var changed = original
            changed.replaceSubrange(0x2c7e8 ..< 0x2c7ec, with: ARM64.movX0_0)
            try IM4PHandler.save(patchedData: changed, originalIM4P: IM4PHandler.load(contentsOf: url).im4p, to: url)
            let before = try Data(contentsOf: url)
            do {
                _ = try pipeline(url).patchRestoreTXMPrecheckFile(at: url)
                Issue.record("already-bypassed restore TXM was accepted")
            } catch let error as PatcherError {
                #expect(error.description.contains("restore TXM TrustedExecutionMonitor_Guarded-187.100.3 is unsupported:"))
            }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test(.enabled(if: fixture != nil))
    func refusesLegacyPrecheckOverrideWithoutWriting() throws {
        try withFixture { url, original in
            let old = TXMDevPatcher(data: original, verbose: false)
            old.patchSelector24ForcePass()
            try #require(old.patches.count == 2)
            _ = try old.apply()
            var changed = old.patchedData
            changed.replaceSubrange(0x30bd4 ..< 0x30be4, with:
                ARM64.movW8_0xA + ARM64.strbW8X19 + ARM64.movW0_0x90
                    + (try #require(ARM64Encoder.encodeB(from: 0x30be0, to: 0x30c7c))))
            // This is the retained old SSHRD's complete TXM payload, not just
            // a model of the four-instruction override.
            let legacyIdentity = try metadata().legacyPayloadSHA256
            try #require(SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined() == legacyIdentity)
            try IM4PHandler.save(patchedData: changed, originalIM4P: IM4PHandler.load(contentsOf: url).im4p, to: url)
            let before = try Data(contentsOf: url)
            #expect(throws: PatcherError.self) { try pipeline(url).patchRestoreTXMPrecheckFile(at: url) }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test(.enabled(if: fixture != nil), arguments: [0x30bc8, 0x30bd4, 0x30c54])
    func refusesChangedNativePrecheckWithoutWriting(offset: Int) throws {
        try withFixture { url, original in
            var changed = original
            changed.replaceSubrange(offset ..< offset + 4, with: ARM64.nop)
            try IM4PHandler.save(patchedData: changed, originalIM4P: IM4PHandler.load(contentsOf: url).im4p, to: url)
            let before = try Data(contentsOf: url)
            #expect(throws: PatcherError.self) { try pipeline(url).patchRestoreTXMPrecheckFile(at: url) }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test(.enabled(if: fixture != nil))
    func refusesBranchAroundNativePolicyWalkWithoutWriting() throws {
        try withFixture { url, original in
            var changed = original
            changed.replaceSubrange(0x30bf8 ..< 0x30bfc, with:
                try #require(ARM64Encoder.encodeB(from: 0x30bf8, to: 0x30c6c)))
            try IM4PHandler.save(patchedData: changed, originalIM4P: IM4PHandler.load(contentsOf: url).im4p, to: url)
            let before = try Data(contentsOf: url)
            #expect(throws: PatcherError.self) { try pipeline(url).patchRestoreTXMPrecheckFile(at: url) }
            #expect(try Data(contentsOf: url) == before)
        }
    }

    @Test(.enabled(if: fixture != nil))
    func refusesIncompleteSelector24WithoutWriting() throws {
        try withFixture { url, original in
            var changed = original
            let disassembler = ARM64Disassembler()
            var removed = 0
            for segment in MachOParser.parseSegments(from: original) where segment.name == "__TEXT_EXEC" {
                for instruction in disassembler.disassemble(in: original, at: Int(segment.fileOffset), count: Int(segment.fileSize / 4)) {
                    guard instruction.mnemonic == "mov", let operands = instruction.detail?.operands,
                          operands.count == 2, operands[0].reg == .w(0),
                          operands[1].type == .immediate, operands[1].imm == 0xa1 else { continue }
                    let offset = Int(instruction.address)
                    changed.replaceSubrange(offset ..< offset + 4, with: ARM64.nop)
                    removed += 1
                }
            }
            try #require(removed > 0)
            let native = TXMDevPatcher(data: changed, verbose: false)
            try native.patchExecutableRemap()
            try #require(native.patches.count == 5)
            native.patchSelector24ForcePass()
            try #require(native.patches.count == 5)
            try IM4PHandler.save(patchedData: changed, originalIM4P: IM4PHandler.load(contentsOf: url).im4p, to: url)
            let before = try Data(contentsOf: url)
            #expect(throws: PatcherError.self) { try pipeline(url).patchRestoreTXMPrecheckFile(at: url) }
            #expect(try Data(contentsOf: url) == before)
        }
    }
}
