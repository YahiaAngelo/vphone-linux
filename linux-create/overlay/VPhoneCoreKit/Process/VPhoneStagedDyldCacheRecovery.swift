#if os(Linux)
import CryptoKit
import Foundation
import Glibc

extension VPhoneStagedDyldCache {
    /// Roll back only the journal's cache family. A successful rollback does
    /// not complete the interrupted CFW install or write its patch receipt.
    public static func recover(
        bundleDirectory: VPhoneConfinedDirectory,
        source: VPhoneConfinedDirectory,
        guestECID: String,
        allowLegacyJournal: Bool = false,
        synchronizeGuest: () throws -> Void
    ) throws -> VPhoneConfinedDirectory {
        try recover(bundleDirectory: bundleDirectory, source: source, guestECID: guestECID, allowLegacyJournal: allowLegacyJournal,
                    synchronizeGuest: synchronizeGuest, verify: VPhoneDyldCacheAudit.verify, io: IO())
    }

    static func recover(
        bundleDirectory: VPhoneConfinedDirectory,
        source: VPhoneConfinedDirectory,
        guestECID: String,
        allowLegacyJournal: Bool = false,
        synchronizeGuest: () throws -> Void,
        verify: (URL, String) throws -> Void,
        io: IO
    ) throws -> VPhoneConfinedDirectory {
        let pending = try PendingPublication.recovering(bundleDirectory: bundleDirectory, guestECID: guestECID, allowLegacy: allowLegacyJournal)
        defer { pending.releasePublicationLock() }
        guard let path = pending.recoveryStage, path.hasPrefix("/"), path != "/" else {
            throw Failure("Pending journal has no absolute recovery stage")
        }
        let stage = try VPhoneConfinedDirectory.pin(absolutePath: path, requireOwner: geteuid())
        let parentPath = (path as NSString).deletingLastPathComponent
        let work = try VPhoneConfinedDirectory.pin(absolutePath: parentPath, requireOwner: geteuid())
        for directory in [stage, work] {
            guard try directory.metadata().st_mode & 0o077 == 0 else {
                throw Failure("Recovery stage and work directory must be private")
            }
        }
        let manifestFile = try stage.openRegularFile("manifest.json", requireSingleLink: true)
        guard manifestFile.owner == geteuid(), manifestFile.mode & 0o077 == 0,
              manifestFile.size > 0, manifestFile.size <= 1 << 20 else {
            throw Failure("Recovery manifest is not a bounded private file owned by this account")
        }
        var manifest = try JSONDecoder().decode(Manifest.self, from: stage.readData("manifest.json"))
        try pending.validateRecoveryPlan(manifest)
        guard ["patched", "publishing", "published", "rolling-back", "rolled-back"].contains(manifest.state) else {
            throw Failure("Recovery manifest does not describe a prepared publication")
        }
        let mainNames = manifest.before.keys.filter { $0.hasPrefix("dyld_shared_cache_") && !$0.contains(".") && !$0.contains("/") }
        guard mainNames.count == 1 else { throw Failure("Recovery manifest has no unique main cache") }
        let main = mainNames[0]
        let names = Set(manifest.before.keys).union(manifest.after.keys)
        for name in names {
            guard name == undoName || name == main || (name.hasPrefix(main + ".") && !name.contains("/")),
                  !name.contains("\0") else { throw Failure("Unsafe recovery cache member: \(name)") }
        }
        guard Set(manifest.before.keys).subtracting([undoName]) == Set(manifest.after.keys).subtracting([undoName]),
              !manifest.before.isEmpty, !manifest.after.isEmpty else {
            throw Failure("Recovery manifest changes the cache family inventory")
        }
        let before = try stage.directory("before")
        let after = try stage.directory("after")
        for directory in [before, after] {
            let metadata = try directory.metadata()
            guard metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0 else {
                throw Failure("Recovery copies must remain private and owned by this account")
            }
        }
        let savedBefore = try recoveryCopies(in: before, expected: manifest.before, io: io)
        let savedAfter = try recoveryCopies(in: after, expected: manifest.after, io: io)
        try verify(URL(fileURLWithPath: before.path), main)
        try verify(URL(fileURLWithPath: after.path), main)
        let inventory = try recoveryNames(in: source, main: main)
        guard inventory.isSubset(of: names), Set(manifest.before.keys).subtracting([undoName]).isSubset(of: inventory) else {
            throw Failure("Guest cache inventory no longer matches the pending publication")
        }
        var destinations: [String: VPhoneConfinedFile] = [:]
        var observed: [String: Fingerprint] = [:]
        for name in inventory.sorted() {
            let file = try source.openRegularFile(name, requireSingleLink: true)
            guard file.mode & 0o7000 == 0 else { throw Failure("Guest cache has unexpected special permission bits: \(name)") }
            if name != undoName, let permissions = manifest.permissions?[name] {
                guard file.owner == permissions.owner, file.group == permissions.group,
                      file.mode & 0o777 == permissions.mode else {
                    throw Failure("Guest cache metadata changed before recovery: \(name)")
                }
            }
            observed[name] = try recoveryPreimage(file, before: savedBefore[name], after: savedAfter[name],
                                                rollingBack: manifest.state == "rolling-back" || manifest.state == "rolled-back",
                                                name: name, io: io)
            destinations[name] = file
        }
        try pending.requireOwnership()
        manifest.state = "rolling-back"
        try saveRecoveryManifest(manifest, in: stage)
        let ordered = names.sorted { $0 == undoName ? false : $1 == undoName ? true : $0 < $1 }
        for name in ordered {
            try pending.requireOwnership()
            if let destination = destinations[name] {
                guard try source.refersTo(name, file: destination),
                      try fingerprint(destination.descriptor, name: name, io: io) == observed[name] else {
                    throw Failure("Guest cache changed during recovery: \(name)")
                }
            } else if try source.exists(name) {
                throw Failure("Guest cache member appeared during recovery: \(name)")
            }
            if let expected = manifest.before[name], observed[name] == expected {
                if name != undoName { continue }
                if let permissions = manifest.permissions?[name], let destination = destinations[name],
                   destination.owner == permissions.owner, destination.group == permissions.group,
                   destination.mode & 0o777 == permissions.mode {
                    continue
                }
            }
            guard let original = savedBefore[name] else {
                if let destination = destinations[name] {
                    guard name == undoName, try source.refersTo(name, file: destination),
                          unlinkat(source.descriptor, name, 0) == 0 else {
                        throw Failure("Could not remove the pending publication's new undo log")
                    }
                }
                continue
            }
            let output: Int32
            if let destination = destinations[name] {
                output = openat(source.descriptor, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard output >= 0 else { throw Failure("Could not open cache recovery destination: \(name)") }
                var metadata = stat()
                guard fstat(output, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_nlink == 1, metadata.st_dev == destination.device, metadata.st_ino == destination.inode,
                      metadata.st_uid == destination.owner, metadata.st_gid == destination.group, metadata.st_mode == destination.mode else {
                    close(output)
                    throw Failure("Guest cache identity changed before recovery write: \(name)")
                }
            } else {
                guard name == undoName else { throw Failure("A cache inode is missing during recovery: \(name)") }
                output = io.create(source.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard output >= 0 else { throw Failure("Could not recreate the original undo log exclusively") }
            }
            defer { close(output) }
            try restoreRecoveryFile(original, to: output, name: name, io: io)
            if name == undoName {
                let directory = try source.metadata()
                let permissions = manifest.permissions?[name]
                    ?? destinations[name].map { Permissions(owner: $0.owner, group: $0.group, mode: $0.mode & 0o777) }
                    ?? Permissions(owner: directory.st_uid, group: directory.st_gid, mode: 0o644)
                guard fchown(output, permissions.owner, permissions.group) == 0,
                      fchmod(output, permissions.mode) == 0 else { throw Failure("Could not restore undo-log metadata") }
            }
            guard io.sync(output) == 0 else { throw Failure("Recovery file fsync failed: \(name)") }
            let restored = try source.openRegularFile(name, requireSingleLink: true)
            guard try fingerprint(restored.descriptor, name: name, io: io) == manifest.before[name] else {
                throw Failure("Recovered cache hash mismatch: \(name)")
            }
        }
        guard try recoveryNames(in: source, main: main) == Set(manifest.before.keys) else {
            throw Failure("Recovered cache inventory mismatch")
        }
        for name in manifest.before.keys {
            let file = try source.openRegularFile(name, requireSingleLink: true)
            guard try fingerprint(file.descriptor, name: name, io: io) == manifest.before[name] else {
                throw Failure("Recovered family changed before guest sync: \(name)")
            }
        }
        if io.sync(source.descriptor) != 0, errno != EINVAL, errno != ENOTSUP {
            throw Failure("Recovered cache directory fsync failed")
        }
        try synchronizeGuest()
        manifest.state = "rolled-back"
        try saveRecoveryManifest(manifest, in: stage)
        pending.publicationSucceeded()
        try pending.clear()
        return stage
    }

    private static func recoveryCopies(in directory: VPhoneConfinedDirectory, expected: [String: Fingerprint], io: IO) throws -> [String: VPhoneConfinedFile] {
        guard try Set(directory.entries()) == Set(expected.keys) else { throw Failure("Recovery copy inventory mismatch") }
        var result: [String: VPhoneConfinedFile] = [:]
        for (name, fingerprint) in expected {
            guard fingerprint.size > 0, fingerprint.sha256.count == 64,
                  fingerprint.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure("Invalid recovery fingerprint: \(name)")
            }
            let file = try directory.openRegularFile(name, requireSingleLink: true)
            guard file.owner == geteuid(), try Self.fingerprint(file.descriptor, name: name, io: io) == fingerprint else {
                throw Failure("Recovery copy hash mismatch: \(name)")
            }
            result[name] = file
        }
        return result
    }

    private static func recoveryNames(in source: VPhoneConfinedDirectory, main: String) throws -> Set<String> {
        Set(try source.entries().filter { $0 == main || $0.hasPrefix(main + ".") || $0 == undoName })
    }

    /// A torn write may contain either staged byte at each offset. Anything
    /// else is an unrelated edit and must not be overwritten by rollback.
    private static func recoveryPreimage(_ file: VPhoneConfinedFile, before: VPhoneConfinedFile?, after: VPhoneConfinedFile?,
                                        rollingBack: Bool, name: String, io: IO) throws -> Fingerprint {
        let maximum = max(before?.size ?? 0, after?.size ?? 0)
        guard file.size >= 0, file.size <= maximum,
              name == undoName || (file.size == before?.size && before?.size == after?.size) else {
            throw Failure("Guest cache size cannot be explained by the pending write: \(name)")
        }
        if name == undoName, let before {
            if let after {
                guard file.size >= min(before.size, after.size) else {
                    throw Failure("Existing undo log was truncated outside the pending write")
                }
            } else if !rollingBack {
                guard file.size == before.size else { throw Failure("Existing undo log changed before rollback") }
            }
        }
        var metadata = stat()
        guard fstat(file.descriptor, &metadata) == 0 else { throw Failure("Could not inspect recovery preimage") }
        var offset: off_t = 0
        var hasher = SHA256()
        while offset < file.size {
            let count = min(1 << 20, Int(file.size - offset))
            let current = try recoveryRead(file.descriptor, offset: offset, count: count, io: io)
            let oldCount = min(count, max(0, Int((before?.size ?? 0) - offset)))
            let newCount = min(count, max(0, Int((after?.size ?? 0) - offset)))
            let old: [UInt8] = try before.map { try recoveryRead($0.descriptor, offset: offset, count: oldCount, io: io) } ?? []
            let new: [UInt8] = try after.map { try recoveryRead($0.descriptor, offset: offset, count: newCount, io: io) } ?? []
            for index in 0 ..< count {
                let matchesOld = index < old.count && current[index] == old[index]
                let matchesNew = index < new.count && current[index] == new[index]
                guard matchesOld || matchesNew else {
                    throw Failure("Guest cache has unrelated bytes; refusing rollback: \(name)")
                }
            }
            hasher.update(data: Data(current))
            offset += off_t(count)
        }
        guard unchanged(file.descriptor, since: metadata) else { throw Failure("Recovery preimage changed while reading: \(name)") }
        return Fingerprint(size: Int64(file.size), sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func recoveryRead(_ descriptor: Int32, offset: off_t, count: Int, io: IO) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        try buffer.withUnsafeMutableBytes { bytes in
            var done = 0
            while done < count {
                let read = io.read(descriptor, bytes.baseAddress! + done, count - done, offset + off_t(done))
                if read < 0, errno == EINTR { continue }
                guard read > 0 else { throw Failure("Short recovery read at \(offset + off_t(done))") }
                done += read
            }
        }
        return buffer
    }

    private static func restoreRecoveryFile(_ input: VPhoneConfinedFile, to output: Int32, name: String, io: IO) throws {
        var offset: off_t = 0
        while offset < input.size {
            let bytes = try recoveryRead(input.descriptor, offset: offset, count: min(1 << 20, Int(input.size - offset)), io: io)
            try bytes.withUnsafeBytes { buffer in
                var done = 0
                while done < bytes.count {
                    let written = io.write(output, buffer.baseAddress! + done, bytes.count - done, offset + off_t(done))
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { throw Failure("Recovery write failed: \(name)") }
                    done += written
                }
            }
            offset += off_t(bytes.count)
        }
        guard ftruncate(output, input.size) == 0 else { throw Failure("Recovery truncate failed: \(name)") }
    }

    private static func saveRecoveryManifest(_ manifest: Manifest, in directory: VPhoneConfinedDirectory) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try directory.writeFile("manifest.json", contents: encoder.encode(manifest), mode: 0o600)
        guard fsync(directory.descriptor) == 0 else { throw Failure("Recovery manifest fsync failed") }
    }
}
#endif
