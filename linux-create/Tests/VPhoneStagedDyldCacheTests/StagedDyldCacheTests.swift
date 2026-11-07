import Foundation
import Glibc
import VLCryptoKit
import XCTest
@testable import VPhoneCoreKit

final class StagedDyldCacheTests: XCTestCase {
    func testLaunchdBackupCannotProveUnreceiptedCachePatchesAreLive() throws {
        XCTAssertEqual(try VPhoneStagedDyldCache.priorGuestPatches(
            wasInstalled: false, receipt: nil,
        ), [])
        let recorded: Set<String> = ["dyld-boot-arm64e_x1_bootstrap"]
        XCTAssertEqual(try VPhoneStagedDyldCache.priorGuestPatches(
            wasInstalled: true, receipt: recorded,
        ), recorded)
        XCTAssertThrowsError(try VPhoneStagedDyldCache.priorGuestPatches(wasInstalled: true, receipt: nil))
    }

    final class Faults {
        var write: ((Int32, UnsafeRawPointer, Int, off_t) -> Int)?
        var sync: ((Int32) -> Int32)?
        var create: ((Int32, String, Int32, mode_t) -> Int32)?
        var journalSync: ((Int32) -> Int32)?
        var guestBytesRead = 0
    }

    struct Fixture {
        let root: URL
        let remote: VPhoneConfinedDirectory
        let bundle: VPhoneConfinedDirectory
        let work: VPhoneConfinedDirectory
        let workDirectory: VPhoneConfinedDirectory
        let workParent: VPhoneConfinedDirectory
        let stage: VPhoneStagedDyldCache
        let pending: VPhoneStagedDyldCache.PendingPublication
        let faults: Faults
        let seed: VPhoneConfinedDirectory?
        let main = "dyld_shared_cache_arm64e"
    }

    func fixture(undo: Bool = true, seedContents: Data? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let directory = try VPhoneConfinedDirectory.pin(absolutePath: root.path)
        let remote = try directory.directory("remote", create: true, mode: 0o700)
        let bundle = try directory.directory("bundle", create: true, mode: 0o700)
        let workDirectory = try directory.directory("work", create: true, mode: 0o700)
        let work = try workDirectory.directory("dyld-stage", create: true, mode: 0o700)
        try bundle.writeFile("Disk.img", contents: Data("disk image identity".utf8), mode: 0o600)
        try remote.writeFile("dyld_shared_cache_arm64e", contents: Data("abcdefgh".utf8), mode: 0o640)
        try remote.writeFile("dyld_shared_cache_arm64e.symbols", contents: Data("symbols".utf8), mode: 0o640)
        if undo { try remote.writeFile(VPhoneStagedDyldCache.undoName, contents: Data("old undo".utf8), mode: 0o600) }
        let faults = Faults()
        var seed: VPhoneConfinedDirectory?
        if let seedContents {
            let directory = try workDirectory.directory("seed", create: true, mode: 0o700)
            try directory.writeFile("dyld_shared_cache_arm64e", contents: seedContents, mode: 0o400)
            try directory.writeFile("dyld_shared_cache_arm64e.symbols", contents: Data("symbols".utf8), mode: 0o400)
            seed = directory
        }
        let pending = try VPhoneStagedDyldCache.PendingPublication(bundleDirectory: bundle, sync: { faults.journalSync?($0) ?? Glibc.fsync($0) })
        var io = VPhoneStagedDyldCache.IO()
        let remotePath = try remote.path
        io.read = { descriptor, bytes, count, offset in
            let result = Glibc.pread(descriptor, bytes, count, offset)
            var path = [CChar](repeating: 0, count: 4096)
            if result > 0, readlink("/proc/self/fd/\(descriptor)", &path, path.count - 1) > 0,
               String(cString: path).hasPrefix(remotePath + "/") { faults.guestBytesRead += result }
            return result
        }
        io.write = { faults.write?($0, $1, $2, $3) ?? Glibc.pwrite($0, $1, $2, $3) }
        io.sync = { faults.sync?($0) ?? Glibc.fsync($0) }
        io.create = { faults.create?($0, $1, $2, $3) ?? Glibc.openat($0, $1, $2, $3) }
        let stage = try VPhoneStagedDyldCache(source: remote, directory: work, mainName: "dyld_shared_cache_arm64e", pending: pending,
                                            workDirectory: workDirectory, workParent: directory, seed: seed, verify: { _, _ in }, io: io)
        return Fixture(root: root, remote: remote, bundle: bundle, work: work, workDirectory: workDirectory, workParent: directory,
                       stage: stage, pending: pending, faults: faults, seed: seed)
    }

    func modify(_ fixture: Fixture, undo: Bool = true) throws {
        try Data("ABCDEFGH".utf8).write(to: fixture.stage.afterURL.appendingPathComponent(fixture.main))
        if undo { try Data("new and longer undo".utf8).write(to: fixture.stage.afterURL.appendingPathComponent(VPhoneStagedDyldCache.undoName)) }
    }

    func manifest(_ fixture: Fixture) throws -> VPhoneStagedDyldCache.Manifest {
        try JSONDecoder().decode(VPhoneStagedDyldCache.Manifest.self, from: fixture.work.readData("manifest.json"))
    }

    func testSeedAvoidsGuestReadsUntilPublicationAndKeepsDestinationSeparate() throws {
        let f = try fixture(undo: false, seedContents: Data("abcdefgh".utf8))
        XCTAssertEqual(f.faults.guestBytesRead, 0)
        try modify(f)
        try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: {})
        XCTAssertGreaterThanOrEqual(f.faults.guestBytesRead, 15)
        XCTAssertEqual(try f.remote.readData(f.main), Data("ABCDEFGH".utf8))
        XCTAssertEqual(try XCTUnwrap(f.seed).readData(f.main), Data("abcdefgh".utf8))
        XCTAssertEqual(try f.remote.openRegularFile(f.main).mode & 0o777, 0o640)
        XCTAssertEqual(try Data(contentsOf: f.stage.beforeURL.appendingPathComponent(f.main)), Data("abcdefgh".utf8))
    }

    func testDifferentSeedBytesRefusePublicationBeforeJournalOrWrites() throws {
        let f = try fixture(undo: false, seedContents: Data("DIFFERNT".utf8))
        XCTAssertEqual(f.faults.guestBytesRead, 0)
        XCTAssertThrowsError(try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: {}))
        XCTAssertGreaterThanOrEqual(f.faults.guestBytesRead, 8)
        XCTAssertEqual(try f.remote.readData(f.main), Data("abcdefgh".utf8))
        XCTAssertFalse(try f.bundle.exists(VPhoneStagedDyldCache.pendingName))
    }

    func testNoSeedStillReadsGuestBaselineAndPreservesExistingUndo() throws {
        let f = try fixture()
        XCTAssertGreaterThanOrEqual(f.faults.guestBytesRead, 23)
        XCTAssertEqual(try Data(contentsOf: f.stage.beforeURL.appendingPathComponent(VPhoneStagedDyldCache.undoName)), Data("old undo".utf8))
        XCTAssertThrowsError(try fixture(seedContents: Data("abcdefgh".utf8)))
    }

    func testPreparedSeedRetainsSelectedFamilyAfterOriginIsRemoved() throws {
        let f = try fixture(undo: false)
        let origin = try f.workDirectory.directory("origin", create: true, mode: 0o700)
        let seed = try f.workDirectory.directory("prepared", create: true, mode: 0o700)
        try origin.writeFile(f.main, contents: signedCache(), mode: 0o400)
        try origin.writeFile(f.main + ".symbols", contents: Data("symbols".utf8), mode: 0o400)
        try origin.writeFile(f.main + ".atlas", contents: Data("atlas".utf8), mode: 0o400)
        try origin.writeFile(f.main + "_x1", contents: Data("other architecture".utf8), mode: 0o400)
        XCTAssertTrue(try VPhoneStagedDyldCache.prepareSeed(from: origin, in: seed, mainName: f.main,
                                                          workDirectory: f.workDirectory, workParent: f.workParent))
        try f.workDirectory.removeItem("origin")
        XCTAssertEqual(try seed.entries().sorted(), [f.main, f.main + ".atlas", f.main + ".symbols"])
        XCTAssertEqual(try seed.readData(f.main), signedCache())
        try VPhoneDyldCacheAudit.verify(URL(fileURLWithPath: seed.path), f.main)
    }

    func testLowSpaceSkipsSeedPayloadAndKeepsGuestStagingAvailable() throws {
        let f = try fixture(undo: false)
        let seed = try f.workDirectory.directory("low-space-seed", create: true, mode: 0o700)
        let baselineBytes: UInt64 = 15
        let oldPathFits = baselineBytes * 4 + (1 << 30) + 1
        XCTAssertFalse(try VPhoneStagedDyldCache.prepareSeed(
            from: f.remote, in: seed, mainName: f.main, workDirectory: f.workDirectory,
            workParent: f.workParent, availableBytes: oldPathFits,
        ))
        XCTAssertTrue(try seed.entries().isEmpty)
        XCTAssertEqual(try f.remote.readData(f.main), Data("abcdefgh".utf8))
        // A new unseeded stager can still capture the guest and publish.
        let fallback = try f.workDirectory.directory("fallback-stage", create: true, mode: 0o700)
        let stage = try VPhoneStagedDyldCache(source: f.remote, directory: fallback, mainName: f.main, pending: f.pending,
                                            workDirectory: f.workDirectory, workParent: f.workParent, verify: { _, _ in }, io: .init())
        try Data("ABCDEFGH".utf8).write(to: stage.afterURL.appendingPathComponent(f.main))
        try stage.publish(validateUndo: { _ in }, synchronizeGuest: {})
        XCTAssertEqual(try f.remote.readData(f.main), Data("ABCDEFGH".utf8))
        XCTAssertNil(VPhoneStagedDyldCache.seedSpaceRequired(for: UInt64.max))
        XCTAssertNil(VPhoneStagedDyldCache.seedSpaceRequired(for: UInt64.max / 5))
    }

    func testChangedOnlyUndoLastAndInodeMetadataPreserved() throws {
        let f = try fixture()
        let original = try f.remote.openRegularFile(f.main)
        let symbols = try f.remote.openRegularFile(f.main + ".symbols")
        let attribute = Data("preserve me".utf8)
        attribute.withUnsafeBytes { bytes in
            XCTAssertEqual(fsetxattr(original.descriptor, "user.vphone-test", bytes.baseAddress, bytes.count, 0), 0)
        }
        try modify(f)
        // Force ordinary short positive writes: the copy must complete them.
        f.faults.write = { Glibc.pwrite($0, $1, min(3, $2), $3) }
        var synced = false
        try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: { synced = true })
        XCTAssertTrue(synced)
        XCTAssertEqual(try f.remote.readData(f.main), Data("ABCDEFGH".utf8))
        XCTAssertEqual(try f.remote.readData(VPhoneStagedDyldCache.undoName), Data("new and longer undo".utf8))
        let current = try f.remote.openRegularFile(f.main)
        XCTAssertEqual(current.inode, original.inode)
        XCTAssertEqual(current.mode, original.mode)
        XCTAssertEqual(current.owner, original.owner)
        XCTAssertEqual(try f.remote.openRegularFile(f.main + ".symbols").inode, symbols.inode)
        var bytes = [UInt8](repeating: 0, count: attribute.count)
        XCTAssertEqual(fgetxattr(current.descriptor, "user.vphone-test", &bytes, bytes.count), attribute.count)
        XCTAssertEqual(Data(bytes), attribute)
        XCTAssertEqual(try manifest(f).published, [f.main, VPhoneStagedDyldCache.undoName])
    }

    func testZeroWriteAndENOSPCStopBeforeUndoAndRetainRecovery() throws {
        for code: Int32 in [0, ENOSPC] {
            let f = try fixture()
            try modify(f)
            f.faults.write = { _, _, _, _ in errno = code; return code == 0 ? 0 : -1 }
            var synced = false
            XCTAssertThrowsError(try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: { synced = true }))
            XCTAssertFalse(synced)
            XCTAssertEqual(try f.remote.readData(VPhoneStagedDyldCache.undoName), Data("old undo".utf8))
            XCTAssertEqual(try Data(contentsOf: f.stage.beforeURL.appendingPathComponent(f.main)), Data("abcdefgh".utf8))
            XCTAssertEqual(try Data(contentsOf: f.stage.afterURL.appendingPathComponent(f.main)), Data("ABCDEFGH".utf8))
            XCTAssertEqual(try manifest(f).state, "publishing")
        }
    }

    func testFsyncFailureStopsPublication() throws {
        let f = try fixture()
        try modify(f)
        f.faults.sync = { descriptor in
            var metadata = stat()
            if fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG { errno = EIO; return -1 }
            return Glibc.fsync(descriptor)
        }
        XCTAssertThrowsError(try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: {}))
        XCTAssertEqual(try f.remote.readData(VPhoneStagedDyldCache.undoName), Data("old undo".utf8))
        XCTAssertEqual(try manifest(f).state, "publishing")
    }

    func testHashMismatchAndDestinationMutationRefusePublication() throws {
        let f = try fixture()
        try modify(f)
        f.faults.write = { fd, bytes, count, offset in
            let corrupt = [UInt8](repeating: 0, count: count)
            return corrupt.withUnsafeBytes { Glibc.pwrite(fd, $0.baseAddress!, count, offset) }
        }
        XCTAssertThrowsError(try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: {}))
        XCTAssertEqual(try f.remote.readData(VPhoneStagedDyldCache.undoName), Data("old undo".utf8))
        let other = try fixture()
        try modify(other)
        try other.remote.writeFile(other.main, contents: Data("mutation".utf8), mode: 0o640)
        XCTAssertThrowsError(try other.stage.publish(validateUndo: { _ in }, synchronizeGuest: {}))
        XCTAssertEqual(try manifest(other).state, "patched")
    }

    func testFreshUndoRaceCannotOverwriteInterveningLog() throws {
        let f = try fixture(undo: false)
        try modify(f)
        let intervening = Data("intervening undo".utf8)
        f.faults.create = { directory, name, flags, mode in
            let inserted = Glibc.openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            XCTAssertGreaterThanOrEqual(inserted, 0)
            defer { close(inserted) }
            intervening.withUnsafeBytes { XCTAssertEqual(Glibc.write(inserted, $0.baseAddress!, $0.count), $0.count) }
            return Glibc.openat(directory, name, flags, mode)
        }
        var synced = false
        XCTAssertThrowsError(try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: { synced = true }))
        XCTAssertFalse(synced)
        XCTAssertEqual(try f.remote.readData(VPhoneStagedDyldCache.undoName), intervening)
        XCTAssertEqual(try manifest(f).published, [f.main])
        XCTAssertEqual(try manifest(f).state, "publishing")
        XCTAssertEqual(try Data(contentsOf: f.stage.beforeURL.appendingPathComponent(f.main)), Data("abcdefgh".utf8))
        XCTAssertEqual(try Data(contentsOf: f.stage.afterURL.appendingPathComponent(f.main)), Data("ABCDEFGH".utf8))
    }

    func testFreshUndoCreationAndGuestSyncFailureAreFatal() throws {
        let f = try fixture(undo: false)
        try modify(f)
        f.faults.create = { _, _, _, _ in errno = EIO; return -1 }
        XCTAssertThrowsError(try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: {}))
        XCTAssertFalse(try f.remote.exists(VPhoneStagedDyldCache.undoName))
        let other = try fixture(undo: false)
        try modify(other)
        XCTAssertThrowsError(try other.stage.publish(validateUndo: { _ in }, synchronizeGuest: { throw CocoaError(.fileWriteUnknown) }))
        XCTAssertEqual(try manifest(other).state, "publishing")
        XCTAssertEqual(try other.remote.readData(VPhoneStagedDyldCache.undoName), Data("new and longer undo".utf8))
    }

    func testReceiptDirectoryFsyncFailureRetainsRecoveryUntilDurableCompletion() throws {
        let f = try fixture()
        try modify(f)
        try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: {})
        let completion = VPhoneStagedDyldCache.Completion(sync: { _ in errno = EIO; return -1 })
        XCTAssertThrowsError(try completion.recordReceipt(in: f.bundle, pending: f.pending, synchronizeGuest: {}) {
            try f.bundle.writeFile("receipt.json", contents: Data("receipt".utf8), mode: 0o600)
        })
        // Apply the same cleanup decision the installer uses after unwinding.
        if completion.shouldRemoveWork(hasStagedCache: true) { try FileManager.default.removeItem(at: f.stage.beforeURL.deletingLastPathComponent()) }
        XCTAssertTrue(try f.work.exists("before"))
        XCTAssertTrue(try f.work.exists("after"))
        XCTAssertTrue(try f.bundle.exists(VPhoneStagedDyldCache.pendingName))
        XCTAssertFalse(completion.shouldRemoveWork(hasStagedCache: true))
        let success = VPhoneStagedDyldCache.Completion()
        try success.recordReceipt(in: f.bundle, pending: f.pending, synchronizeGuest: {}) {
            try f.bundle.writeFile("receipt.json", contents: Data("durable receipt".utf8), mode: 0o600)
        }
        XCTAssertTrue(success.shouldRemoveWork(hasStagedCache: true))
        XCTAssertFalse(try f.bundle.exists(VPhoneStagedDyldCache.pendingName))
        XCTAssertNoThrow(try VPhoneStagedDyldCache.PendingPublication(bundleDirectory: f.bundle))
    }

    func testFinalGuestSyncFailureRetainsRecoveryAndSkipsReceipt() throws {
        let f = try fixture()
        try modify(f)
        try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: {})
        let completion = VPhoneStagedDyldCache.Completion()
        var receiptWritten = false

        XCTAssertThrowsError(try completion.recordReceipt(
            in: f.bundle,
            pending: f.pending,
            synchronizeGuest: { throw CocoaError(.fileWriteUnknown) },
        ) {
            receiptWritten = true
            try f.bundle.writeFile("receipt.json", contents: Data("receipt".utf8), mode: 0o600)
        })

        XCTAssertFalse(receiptWritten)
        XCTAssertFalse(try f.bundle.exists("receipt.json"))
        XCTAssertTrue(try f.bundle.exists(VPhoneStagedDyldCache.pendingName))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.stage.beforeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.stage.afterURL.path))
        XCTAssertFalse(completion.shouldRemoveWork(hasStagedCache: true))
    }

    func testPendingJournalFsyncFailureStopsBeforeFirstDestinationWrite() throws {
        for failingCall in [1, 2] {
            let f = try fixture()
            try modify(f)
            var calls = 0
            f.faults.journalSync = { descriptor in
                calls += 1
                if calls == failingCall { errno = EIO; return -1 }
                return Glibc.fsync(descriptor)
            }
            XCTAssertThrowsError(try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: {}))
            XCTAssertEqual(try f.remote.readData(f.main), Data("abcdefgh".utf8))
            XCTAssertEqual(try f.remote.readData(VPhoneStagedDyldCache.undoName), Data("old undo".utf8))
            XCTAssertTrue(try f.bundle.exists(VPhoneStagedDyldCache.pendingName))
            XCTAssertThrowsError(try VPhoneStagedDyldCache.PendingPublication(bundleDirectory: f.bundle))
        }
    }

    func testRecoveryParentFsyncFailureRetainsStageBeforeJournalOrDestinationWrite() throws {
        for failingParent in [0, 1] {
            let f = try fixture()
            try modify(f)
            let parents = [f.workDirectory.descriptor, f.workParent.descriptor]
            var journalStarted = false, destinationWritten = false
            f.faults.sync = { descriptor in
                if descriptor == parents[failingParent] { errno = EIO; return -1 }
                return Glibc.fsync(descriptor)
            }
            f.faults.journalSync = { descriptor in journalStarted = true; return Glibc.fsync(descriptor) }
            f.faults.write = { descriptor, bytes, count, offset in
                destinationWritten = true
                return Glibc.pwrite(descriptor, bytes, count, offset)
            }
            XCTAssertThrowsError(try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: {}))
            XCTAssertFalse(journalStarted)
            XCTAssertFalse(destinationWritten)
            XCTAssertFalse(try f.bundle.exists(VPhoneStagedDyldCache.pendingName))
            XCTAssertEqual(try f.remote.readData(f.main), Data("abcdefgh".utf8))
            XCTAssertTrue(try f.work.exists("before"))
            XCTAssertTrue(try f.work.exists("after"))
            XCTAssertFalse(VPhoneStagedDyldCache.Completion().shouldRemoveWork(hasStagedCache: true))
        }
    }

    func testRecoveryParentsAreDurableBeforeJournalAndFirstDestinationWrite() throws {
        let f = try fixture()
        try modify(f)
        var events: [String] = []
        let workDescriptor = f.workDirectory.descriptor, parentDescriptor = f.workParent.descriptor
        f.faults.sync = { descriptor in
            if descriptor == workDescriptor { events.append("work directory") }
            if descriptor == parentDescriptor { events.append("work parent") }
            return Glibc.fsync(descriptor)
        }
        f.faults.journalSync = { descriptor in
            var metadata = stat()
            XCTAssertEqual(fstat(descriptor, &metadata), 0)
            events.append(metadata.st_mode & S_IFMT == S_IFDIR ? "journal directory" : "journal file")
            return Glibc.fsync(descriptor)
        }
        f.faults.write = { descriptor, bytes, count, offset in
            if !events.contains("destination") { events.append("destination") }
            return Glibc.pwrite(descriptor, bytes, count, offset)
        }
        try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: {})
        XCTAssertEqual(Array(events.prefix(5)), ["work directory", "work parent", "journal file", "journal directory", "destination"])
    }

    func testDiskReplacementBeforePublicationIsRefused() throws {
        let f = try fixture()
        try modify(f)
        try f.bundle.writeFile("Disk.img", contents: Data("replacement disk".utf8), mode: 0o600)
        XCTAssertThrowsError(try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: {}))
        XCTAssertEqual(try f.remote.readData(f.main), Data("abcdefgh".utf8))
        XCTAssertFalse(try f.bundle.exists(VPhoneStagedDyldCache.pendingName))
    }

    func testUnreadableOrSymlinkPendingJournalStillRefusesRetry() throws {
        let f = try fixture()
        try f.bundle.writeFile(VPhoneStagedDyldCache.pendingName, contents: Data("{".utf8), mode: 0o600)
        XCTAssertThrowsError(try VPhoneStagedDyldCache.PendingPublication(bundleDirectory: f.bundle))
        try f.bundle.removeItem(VPhoneStagedDyldCache.pendingName)
        try f.bundle.createSymlink(target: f.stage.beforeURL.path, at: VPhoneStagedDyldCache.pendingName)
        XCTAssertThrowsError(try VPhoneStagedDyldCache.PendingPublication(bundleDirectory: f.bundle))
        XCTAssertTrue(try f.work.exists("before"))
    }

    func testWholeChunkFailureLeavesAuditableFamilyButBlocksFreshInvocation() throws {
        let f = try fixture()
        var main = signedCache(), chunk = signedCache()
        // A modern main header declares the second signed chunk and its UUID.
        func little(_ value: UInt32, at offset: Int, in data: inout Data) {
            for index in 0 ..< 4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        little(0x200, at: 0x10, in: &main)
        little(0x240, at: 0x188, in: &main)
        little(1, at: 0x18c, in: &main)
        chunk[0x58] = 2
        main.replaceSubrange(0x240 ..< 0x250, with: chunk.subdata(in: 0x58 ..< 0x68))
        main.replaceSubrange(0x258 ..< 0x25c, with: Data(".01\0".utf8))
        func reattest(_ data: inout Data) {
            data.replaceSubrange(4164 ..< 4196, with: Data(SHA256.hash(data: data.prefix(4096))))
        }
        reattest(&main); reattest(&chunk)
        try f.remote.writeFile(f.main, contents: main, mode: 0o640)
        try f.remote.writeFile(f.main + ".01", contents: chunk, mode: 0o640)
        let recovery = try f.work.directory("transaction", create: true, mode: 0o700)
        var failSecondChunk = false
        var io = VPhoneStagedDyldCache.IO()
        io.write = { descriptor, bytes, count, offset in
            if failSecondChunk {
                var path = [CChar](repeating: 0, count: 4096)
                let length = readlink("/proc/self/fd/\(descriptor)", &path, path.count - 1)
                if length > 0, String(cString: path).hasSuffix(".01") { errno = ENOSPC; return -1 }
            }
            return Glibc.pwrite(descriptor, bytes, count, offset)
        }
        let stage = try VPhoneStagedDyldCache(source: f.remote, directory: recovery, mainName: f.main, pending: f.pending,
                                            workDirectory: f.work, workParent: f.workDirectory,
                                            verify: VPhoneDyldCacheAudit.verify, io: io)
        main[0x300] = 1; chunk[0x300] = 1
        reattest(&main); reattest(&chunk)
        try main.write(to: stage.afterURL.appendingPathComponent(f.main))
        try chunk.write(to: stage.afterURL.appendingPathComponent(f.main + ".01"))
        try Data("new undo".utf8).write(to: stage.afterURL.appendingPathComponent(VPhoneStagedDyldCache.undoName))
        failSecondChunk = true
        XCTAssertThrowsError(try stage.publish(validateUndo: { _ in }, synchronizeGuest: {}))
        XCTAssertEqual(try f.remote.readData(f.main), main)
        XCTAssertEqual(try f.remote.readData(VPhoneStagedDyldCache.undoName), Data("old undo".utf8))
        // Each whole chunk is still signed. Auditing alone cannot authorize a retry.
        try VPhoneDyldCacheAudit.verify(URL(fileURLWithPath: try f.remote.path), f.main)
        var newWorkStarted = false
        XCTAssertThrowsError(try {
            let pending = try VPhoneStagedDyldCache.PendingPublication(bundleDirectory: f.bundle)
            newWorkStarted = true
            let work = try f.work.directory("retry", create: true, mode: 0o700)
            let retry = try VPhoneStagedDyldCache(source: f.remote, directory: work, mainName: f.main, pending: pending,
                                                workDirectory: f.work, workParent: f.workDirectory)
            try retry.publish(validateUndo: { _ in }, synchronizeGuest: {})
        }())
        XCTAssertFalse(newWorkStarted)
        XCTAssertFalse(try f.work.exists("retry"))
        XCTAssertTrue(try recovery.exists("before"))
        XCTAssertTrue(try recovery.exists("after"))
        XCTAssertTrue(try f.bundle.exists(VPhoneStagedDyldCache.pendingName))
        let rawJournal = try JSONSerialization.jsonObject(with: f.bundle.readData(VPhoneStagedDyldCache.pendingName))
        let journal = try XCTUnwrap(rawJournal as? [String: Any])
        XCTAssertEqual(journal["recoveryStage"] as? String, try recovery.path)
    }

    func testUndoValidationFailureStopsBeforeAnyWrite() throws {
        let f = try fixture()
        try modify(f)
        XCTAssertThrowsError(try f.stage.publish(validateUndo: { _ in throw CocoaError(.fileReadCorruptFile) }, synchronizeGuest: {}))
        XCTAssertEqual(try f.remote.readData(f.main), Data("abcdefgh".utf8))
        XCTAssertEqual(try manifest(f).state, "patched")
    }

    func testRemovingFinalUndoIsPublishedLast() throws {
        let f = try fixture()
        try modify(f, undo: false)
        try FileManager.default.removeItem(at: f.stage.afterURL.appendingPathComponent(VPhoneStagedDyldCache.undoName))
        try f.stage.publish(validateUndo: { _ in }, synchronizeGuest: {})
        XCTAssertFalse(try f.remote.exists(VPhoneStagedDyldCache.undoName))
        XCTAssertEqual(try manifest(f).published, [f.main, VPhoneStagedDyldCache.undoName])
    }

    func testCorruptStagingCopyIsRejectedAndSourceIsUntouched() throws {
        let f = try fixture()
        let failed = try f.work.directory("failed-copy", create: true, mode: 0o700)
        var io = VPhoneStagedDyldCache.IO()
        io.write = { descriptor, _, count, offset in
            let zeros = [UInt8](repeating: 0, count: count)
            return zeros.withUnsafeBytes { Glibc.pwrite(descriptor, $0.baseAddress!, count, offset) }
        }
        XCTAssertThrowsError(try VPhoneStagedDyldCache(source: f.remote, directory: failed, mainName: f.main, pending: f.pending,
                                                   workDirectory: f.work, workParent: f.workDirectory, verify: { _, _ in }, io: io))
        XCTAssertEqual(try f.remote.readData(f.main), Data("abcdefgh".utf8))
        let state = try JSONDecoder().decode(VPhoneStagedDyldCache.Manifest.self, from: failed.readData("manifest.json"))
        XCTAssertEqual(state.state, "copying")
    }

    func testNativeAuditFailureStopsBeforePublication() throws {
        let f = try fixture()
        try signedCache().write(to: URL(fileURLWithPath: try f.remote.path).appendingPathComponent(f.main))
        let work = try f.work.directory("signed-cache", create: true, mode: 0o700)
        let stage = try VPhoneStagedDyldCache(source: f.remote, directory: work, mainName: f.main, pending: f.pending,
                                            workDirectory: f.work, workParent: f.workDirectory)
        var broken = signedCache()
        broken[0x200] ^= 1
        try broken.write(to: stage.afterURL.appendingPathComponent(f.main))
        XCTAssertThrowsError(try stage.publish(validateUndo: { _ in }, synchronizeGuest: {}))
        XCTAssertEqual(try f.remote.readData(f.main), signedCache())
    }

    func signedCache() -> Data {
        let pageSize = 4096, cdOffset = pageSize + 20, hashOffset = 48
        var data = Data(repeating: 0, count: pageSize + 20 + hashOffset + 32)
        func put(_ value: UInt64, _ offset: Int, _ length: Int, big: Bool = false) {
            for index in 0 ..< length { data[offset + index] = UInt8(truncatingIfNeeded: value >> ((big ? length - index - 1 : index) * 8)) }
        }
        data.replaceSubrange(0 ..< 16, with: Data("dyld_v1  arm64e\0\0".utf8))
        put(0x100, 0x10, 4); put(1, 0x14, 4)
        put(UInt64(pageSize), 0x28, 8); put(UInt64(data.count - pageSize), 0x30, 8)
        data[0x58] = 1
        put(0xfade0cc0, pageSize, 4, big: true); put(UInt64(data.count - pageSize), pageSize + 4, 4, big: true)
        put(1, pageSize + 8, 4, big: true); put(20, pageSize + 16, 4, big: true)
        put(0xfade0c02, cdOffset, 4, big: true); put(UInt64(hashOffset + 32), cdOffset + 4, 4, big: true)
        put(0x20000, cdOffset + 8, 4, big: true); put(UInt64(hashOffset), cdOffset + 16, 4, big: true)
        put(44, cdOffset + 20, 4, big: true); put(1, cdOffset + 28, 4, big: true)
        put(UInt64(pageSize), cdOffset + 32, 4, big: true)
        data[cdOffset + 36] = 32; data[cdOffset + 37] = 2; data[cdOffset + 39] = 12
        let hash = Data(SHA256.hash(data: data.prefix(pageSize)))
        data.replaceSubrange(cdOffset + hashOffset ..< cdOffset + hashOffset + 32, with: hash)
        return data
    }

    func testNativeAuditAcceptsWholeCoverageAndRejectsBadPageAndUnlistedChunk() throws {
        let f = try fixture()
        var cache = signedCache()
        let path = f.stage.afterURL.appendingPathComponent(f.main)
        try cache.write(to: path)
        try VPhoneDyldCacheAudit.verify(f.stage.afterURL, f.main)
        cache[0x200] ^= 1
        try cache.write(to: path)
        XCTAssertThrowsError(try VPhoneDyldCacheAudit.verify(f.stage.afterURL, f.main))
        try signedCache().write(to: path)
        let unknown = f.stage.afterURL.appendingPathComponent(f.main + ".unexpected")
        try Data([1]).write(to: unknown)
        XCTAssertThrowsError(try VPhoneDyldCacheAudit.verify(f.stage.afterURL, f.main))
    }

    func testFrozenNativeAuditWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["VPHONE_STAGED_AUDIT_MAIN"],
              let output = ProcessInfo.processInfo.environment["VPHONE_STAGED_AUDIT_REPORT"] else {
            throw XCTSkip("A frozen cache and private report path were not provided")
        }
        let main = URL(fileURLWithPath: path)
        let report = try VPhoneDyldCacheAudit.audit(main.deletingLastPathComponent(), main.lastPathComponent)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: output))
        XCTAssertGreaterThan(report.chunks, 0)
        XCTAssertGreaterThan(report.pages, 0)
    }
}
