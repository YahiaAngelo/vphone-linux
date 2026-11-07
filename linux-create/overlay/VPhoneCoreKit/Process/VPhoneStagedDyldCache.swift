#if os(Linux)
import CryptoKit
import Foundation
import Glibc

/// Keep random cache edits on the host. Publication is sequential and is not a
/// family-wide transaction: any error must stop the installer before boot.
public final class VPhoneStagedDyldCache {
    public static let undoName = ".vphone-dsc-undo.json"
    public static let pendingName = ".vphone-dsc-pending.json"

    /// A launchd backup proves earlier mutation, not completed publication.
    public static func priorGuestPatches(
        wasInstalled: Bool, receipt: Set<String>?
    ) throws -> Set<String> {
        guard !wasInstalled || receipt != nil else {
            throw Failure(
                "Unresolved or legacy CFW state: launchd.plist.bak exists but no valid Guest patch receipt was found. "
                    + "Preserve the VM disk and retained CFW artifacts for manual inspection; automatic recovery is unavailable."
            )
        }
        return receipt ?? []
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ message: String) { description = message }
    }

    struct IO {
        var read: (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int = { Glibc.pread($0, $1, $2, $3) }
        var write: (Int32, UnsafeRawPointer, Int, off_t) -> Int = { Glibc.pwrite($0, $1, $2, $3) }
        var sync: (Int32) -> Int32 = { Glibc.fsync($0) }
        var create: (Int32, String, Int32, mode_t) -> Int32 = { Glibc.openat($0, $1, $2, $3) }
    }

    /// A per-bundle stop marker, not an automatic recovery mechanism. A whole
    /// chunk can be internally signed while its original bytes have not yet
    /// reached the undo log; a fresh audit cannot establish retry safety.
    public final class PendingPublication {
        private struct Identity: Codable, Equatable {
            let device: UInt64
            let inode: UInt64
            let size: Int64?
        }

        private struct Journal: Codable {
            let schemaVersion: Int
            let bundle: Identity
            let disk: Identity
            let recoveryStage: String
        }

        private let bundleDirectory: VPhoneConfinedDirectory
        private let bundleIdentity: Identity
        private let diskIdentity: Identity
        private let sync: (Int32) -> Int32
        private var journalIdentity: Identity?
        private var journalBytes: Data?
        private var published = false

        public convenience init(bundleDirectory: VPhoneConfinedDirectory) throws {
            try self.init(bundleDirectory: bundleDirectory, sync: { Glibc.fsync($0) })
        }

        init(bundleDirectory: VPhoneConfinedDirectory, sync: @escaping (Int32) -> Int32) throws {
            if try bundleDirectory.exists(VPhoneStagedDyldCache.pendingName) {
                let metadata = try bundleDirectory.status(VPhoneStagedDyldCache.pendingName)
                let journal = metadata.map { $0.st_size <= 65536 && $0.st_mode & S_IFMT == S_IFREG } == true
                    ? (try? JSONDecoder().decode(Journal.self, from: bundleDirectory.readData(VPhoneStagedDyldCache.pendingName))) : nil
                throw Failure("Unresolved dyld cache publication in \(try bundleDirectory.path). Recovery stage: \(journal?.recoveryStage ?? "unknown; inspect the pending journal"). Repair the prior publication before booting or retrying CFW.")
            }
            self.bundleDirectory = bundleDirectory
            self.sync = sync
            let metadata = try bundleDirectory.metadata()
            bundleIdentity = Identity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino), size: nil)
            let disk = try bundleDirectory.openRegularFile("Disk.img", requireSingleLink: true)
            diskIdentity = Identity(device: UInt64(disk.device), inode: UInt64(disk.inode), size: Int64(disk.size))
        }

        func begin(recoveryStage: String) throws {
            guard journalIdentity == nil else { throw Failure("Dyld cache publication was already started") }
            let bundle = try bundleDirectory.metadata()
            let disk = try bundleDirectory.openRegularFile("Disk.img", requireSingleLink: true)
            guard bundleIdentity == Identity(device: UInt64(bundle.st_dev), inode: UInt64(bundle.st_ino), size: nil),
                  diskIdentity == Identity(device: UInt64(disk.device), inode: UInt64(disk.inode), size: Int64(disk.size))
            else { throw Failure("VM bundle or Disk.img identity changed before cache publication") }
            let journal = Journal(schemaVersion: 1, bundle: bundleIdentity, disk: diskIdentity, recoveryStage: recoveryStage)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(journal)
            let file = openat(bundleDirectory.descriptor, VPhoneStagedDyldCache.pendingName,
                              O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw Failure("Could not exclusively create pending cache journal: \(String(cString: strerror(errno)))") }
            defer { close(file) }
            var metadata = stat()
            guard fstat(file, &metadata) == 0 else { throw Failure("Could not inspect pending cache journal") }
            journalIdentity = Identity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino), size: Int64(data.count))
            journalBytes = data
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Glibc.write(file, bytes.baseAddress! + offset, bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Failure("Pending cache journal write failed: \(String(cString: strerror(errno)))") }
                    offset += count
                }
            }
            guard sync(file) == 0, sync(bundleDirectory.descriptor) == 0 else {
                throw Failure("Pending cache journal fsync: \(String(cString: strerror(errno)))")
            }
        }

        func publicationSucceeded() { published = true }

        func requirePublished() throws {
            guard published, journalIdentity != nil else { throw Failure("Cache publication and guest sync have not completed") }
        }

        func clear() throws {
            try requirePublished()
            guard let expected = journalIdentity, let metadata = try bundleDirectory.status(VPhoneStagedDyldCache.pendingName),
                  metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
                  expected == Identity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino), size: Int64(metadata.st_size)),
                  try bundleDirectory.readData(VPhoneStagedDyldCache.pendingName) == journalBytes
            else { throw Failure("Pending cache journal changed; retained recovery stage") }
            guard unlinkat(bundleDirectory.descriptor, VPhoneStagedDyldCache.pendingName, 0) == 0,
                  sync(bundleDirectory.descriptor) == 0 else {
                throw Failure("Pending cache journal removal fsync: \(String(cString: strerror(errno)))")
            }
        }
    }

    /// Keep recovery copies until the receipt's renamed directory entry is
    /// durable on the host. A failed receipt or directory sync cannot release
    /// an already published cache's recovery stage.
    public final class Completion {
        private var completed = false
        private let sync: (Int32) -> Int32

        public convenience init() { self.init(sync: { Glibc.fsync($0) }) }
        init(sync: @escaping (Int32) -> Int32) { self.sync = sync }

        public func recordReceipt(in directory: VPhoneConfinedDirectory, pending: PendingPublication, write: () throws -> Void) throws {
            try pending.requirePublished()
            try write()
            guard sync(directory.descriptor) == 0 else {
                throw Failure("Receipt directory fsync: \(String(cString: strerror(errno)))")
            }
            try pending.clear()
            completed = true
        }

        public func shouldRemoveWork(hasStagedCache: Bool) -> Bool {
            completed || !hasStagedCache
        }
    }

    struct Fingerprint: Codable, Equatable {
        let size: Int64
        let sha256: String
    }

    struct Manifest: Codable {
        var state: String
        var before: [String: Fingerprint]
        var after: [String: Fingerprint]
        var published: [String]
        var currentFile: String?
    }

    public let directory: VPhoneConfinedDirectory
    public let beforeURL: URL
    public let afterURL: URL
    private let source: VPhoneConfinedDirectory
    private let before: VPhoneConfinedDirectory
    private let after: VPhoneConfinedDirectory
    private let mainName: String
    private let pending: PendingPublication
    private let workDirectory: VPhoneConfinedDirectory
    private let workParent: VPhoneConfinedDirectory
    private let verify: (URL, String) throws -> Void
    private let io: IO
    private var manifest: Manifest
    private var identities: [String: VPhoneConfinedFile] = [:]

    public convenience init(
        source: VPhoneConfinedDirectory,
        directory: VPhoneConfinedDirectory,
        mainName: String,
        pending: PendingPublication,
        workDirectory: VPhoneConfinedDirectory,
        workParent: VPhoneConfinedDirectory,
        seed: VPhoneConfinedDirectory? = nil
    ) throws {
        try self.init(source: source, directory: directory, mainName: mainName, pending: pending,
                      workDirectory: workDirectory, workParent: workParent,
                      seed: seed, verify: VPhoneDyldCacheAudit.verify, io: IO())
    }

    init(source: VPhoneConfinedDirectory, directory: VPhoneConfinedDirectory, mainName: String, pending: PendingPublication,
         workDirectory: VPhoneConfinedDirectory, workParent: VPhoneConfinedDirectory,
         seed: VPhoneConfinedDirectory? = nil,
         verify: @escaping (URL, String) throws -> Void, io: IO) throws {
        guard mainName.hasPrefix("dyld_shared_cache_"), !mainName.contains("/"),
              !mainName.contains("."), !mainName.isEmpty else { throw Failure("Unsafe main cache name") }
        self.source = source
        self.directory = directory
        self.mainName = mainName
        self.pending = pending
        self.workDirectory = workDirectory
        self.workParent = workParent
        self.verify = verify
        self.io = io
        before = try directory.directory("before", create: true, mode: 0o700)
        after = try directory.directory("after", create: true, mode: 0o700)
        beforeURL = URL(fileURLWithPath: try before.path)
        afterURL = URL(fileURLWithPath: try after.path)
        manifest = Manifest(state: "copying", before: [:], after: [:], published: [])
        let names = try familyNames(in: source)
        if let seed {
            guard !names.contains(Self.undoName), try familyNames(in: seed) == names else {
                throw Failure("Seed family differs from the fresh guest cache inventory")
            }
        }
        guard names.contains(mainName) else { throw Failure("Missing main cache \(mainName)") }
        var bytes: UInt64 = 0
        for name in names {
            let file = try source.openRegularFile(name, requireSingleLink: true)
            guard file.size > 0 else { throw Failure("Empty cache family file: \(name)") }
            guard file.mode & 0o7000 == 0 else { throw Failure("Unsupported special permission bits: \(name)") }
            let (total, overflow) = bytes.addingReportingOverflow(UInt64(file.size))
            guard !overflow else { throw Failure("Cache family size overflow") }
            bytes = total
            identities[name] = file
        }
        var space = statvfs()
        guard fstatvfs(directory.descriptor, &space) == 0 else { throw systemError("statvfs") }
        let (required, overflow) = bytes.multipliedReportingOverflow(by: 4)
        let (reserve, reserveOverflow) = required.addingReportingOverflow(1 << 30)
        let (available, availableOverflow) = UInt64(space.f_bavail).multipliedReportingOverflow(by: UInt64(space.f_frsize))
        guard !overflow, !reserveOverflow, !availableOverflow, available > reserve
        else { throw Failure("Insufficient local space for before/after cache and undo growth") }
        try saveManifest()
        for name in names {
            let guest = identities[name]!
            let file = try seed?.openRegularFile(name, requireSingleLink: true) ?? guest
            guard file.size == guest.size else { throw Failure("Seed size differs from guest cache: \(name)") }
            var metadata = stat()
            guard fstat(file.descriptor, &metadata) == 0, metadata.st_size == file.size else { throw systemError(name) }
            let original = try copy(file.descriptor, size: Int64(file.size), to: before, name: name)
            let saved = try before.openRegularFile(name, requireSingleLink: true)
            guard try fingerprint(saved.descriptor, name: name) == original,
                  Self.unchanged(file.descriptor, since: metadata)
            else { throw Failure("Cache changed or short copy while staging \(name)") }
            _ = try copy(saved.descriptor, size: original.size, to: after, name: name)
            let staged = try after.openRegularFile(name, requireSingleLink: true)
            guard try fingerprint(staged.descriptor, name: name) == original else {
                throw Failure("Staged copy hash mismatch: \(name)")
            }
            manifest.before[name] = original
            try saveManifest()
        }
        guard fsync(before.descriptor) == 0, fsync(after.descriptor) == 0 else {
            throw systemError("local cache directory fsync")
        }
        try verify(beforeURL, mainName)
        manifest.state = "staged"
        try saveManifest()
    }

    /// Capture only the selected family from the verified private read-only OS
    /// image. This local input never becomes the publication destination.
    public static func prepareSeed(
        from source: VPhoneConfinedDirectory, in directory: VPhoneConfinedDirectory,
        mainName: String, workDirectory: VPhoneConfinedDirectory, workParent: VPhoneConfinedDirectory
    ) throws -> Bool {
        var space = statvfs()
        guard fstatvfs(workDirectory.descriptor, &space) == 0 else {
            throw Failure("Seed statvfs: \(String(cString: strerror(errno)))")
        }
        let (available, overflow) = UInt64(space.f_bavail).multipliedReportingOverflow(by: UInt64(space.f_frsize))
        guard !overflow else { return false }
        return try prepareSeed(from: source, in: directory, mainName: mainName, workDirectory: workDirectory,
                               workParent: workParent, availableBytes: available)
    }

    static func seedSpaceRequired(for bytes: UInt64) -> UInt64? {
        let (families, overflow) = bytes.multipliedReportingOverflow(by: 5)
        let (required, reserveOverflow) = families.addingReportingOverflow(1 << 30)
        return overflow || reserveOverflow ? nil : required
    }

    static func prepareSeed(
        from source: VPhoneConfinedDirectory, in directory: VPhoneConfinedDirectory,
        mainName: String, workDirectory: VPhoneConfinedDirectory, workParent: VPhoneConfinedDirectory,
        availableBytes: UInt64
    ) throws -> Bool {
        guard try directory.entries().isEmpty else { throw Failure("Seed directory is not empty") }
        let names = try source.entries().filter { $0 == mainName || $0.hasPrefix(mainName + ".") }.sorted()
        guard names.contains(mainName), try !source.exists(undoName) else { throw Failure("Source is not a pristine cache seed") }
        var bytes: UInt64 = 0
        for name in names {
            let file = try source.openRegularFile(name, requireSingleLink: true)
            guard file.size > 0 else { throw Failure("Empty cache seed file: \(name)") }
            let (total, overflow) = bytes.addingReportingOverflow(UInt64(file.size))
            guard !overflow else { return false }
            bytes = total
        }
        // The optional extra family must leave the existing stager's full
        // 4B + 1 GiB reserve available. Otherwise keep the original guest path.
        guard let required = seedSpaceRequired(for: bytes), availableBytes > required else { return false }
        for name in names {
            let original = try source.openRegularFile(name, requireSingleLink: true)
            let expected = try fingerprint(original.descriptor, name: name, io: IO())
            try source.copyFile(from: name, to: name, in: directory)
            let copied = try directory.openRegularFile(name, requireSingleLink: true)
            guard try fingerprint(copied.descriptor, name: name, io: IO()) == expected,
                  try fingerprint(original.descriptor, name: name, io: IO()) == expected else {
                throw Failure("Seed copy verification failed: \(name)")
            }
            guard fsync(copied.descriptor) == 0 else { throw Failure("Seed file fsync: \(String(cString: strerror(errno)))") }
        }
        try VPhoneDyldCacheAudit.verify(URL(fileURLWithPath: directory.path), mainName)
        guard fsync(directory.descriptor) == 0, fsync(workDirectory.descriptor) == 0, fsync(workParent.descriptor) == 0 else {
            throw Failure("Seed directory durability failed: \(String(cString: strerror(errno)))")
        }
        return true
    }

    /// Validate the whole family before the first remote write. Existing
    /// cache inodes are retained, preserving xattrs, ACLs, ownership and flags.
    /// A new undo file is exclusively created and is always published last.
    public func publish(validateUndo: (URL) throws -> Void, synchronizeGuest: () throws -> Void) throws {
        let names = try familyNames(in: after)
        guard Set(names).subtracting([Self.undoName]) == Set(manifest.before.keys).subtracting([Self.undoName]) else {
            throw Failure("Patcher added or removed cache family members")
        }
        for name in names {
            let file = try after.openRegularFile(name, requireSingleLink: true)
            manifest.after[name] = try fingerprint(file.descriptor, name: name)
            guard fsync(file.descriptor) == 0 else { throw systemError("local patched cache fsync: \(name)") }
            if name != Self.undoName, manifest.after[name]?.size != manifest.before[name]?.size {
                throw Failure("Patcher changed cache file size: \(name)")
            }
        }
        guard fsync(after.descriptor) == 0 else { throw systemError("local patched directory fsync") }
        manifest.state = "patched"
        try saveManifest()
        try validateUndo(afterURL)
        try verify(afterURL, mainName)
        guard try familyNames(in: source) == manifest.before.keys.sorted() else {
            throw Failure("Destination cache inventory changed during staging")
        }
        for name in manifest.before.keys.sorted() {
            let current = try source.openRegularFile(name, requireSingleLink: true)
            guard let original = identities[name], current.device == original.device, current.inode == original.inode,
                  current.owner == original.owner, current.group == original.group, current.mode == original.mode,
                  try fingerprint(current.descriptor, name: name) == manifest.before[name]
            else { throw Failure("Destination changed during local patching: \(name)") }
        }
        // Make every newly created component of the recovery path durable
        // before a durable journal can refer to it or any remote byte changes.
        guard io.sync(workDirectory.descriptor) == 0 else { throw systemError("Recovery work directory fsync") }
        guard io.sync(workParent.descriptor) == 0 else { throw systemError("Recovery work parent fsync") }
        try pending.begin(recoveryStage: directory.path)
        manifest.state = "publishing"
        try saveManifest()
        let changed = Set(names).union(manifest.before.keys).filter { manifest.after[$0] != manifest.before[$0] }
            .sorted { left, right in
                if left == Self.undoName { return false }
                if right == Self.undoName { return true }
                return left < right
            }
        for name in changed {
            manifest.currentFile = name
            try saveManifest()
            if manifest.after[name] == nil {
                guard name == Self.undoName, let original = identities[name],
                      try source.refersTo(name, file: original) else { throw Failure("Undo identity changed before removal") }
                guard unlinkat(source.descriptor, name, 0) == 0 else { throw systemError(name) }
                try syncDirectory()
                manifest.published.append(name)
                manifest.currentFile = nil
                try saveManifest()
                continue
            }
            let input = try after.openRegularFile(name, requireSingleLink: true)
            if let original = identities[name] {
                let output = openat(source.descriptor, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard output >= 0 else { throw systemError(name) }
                defer { close(output) }
                var metadata = stat()
                guard fstat(output, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                      metadata.st_nlink == 1, metadata.st_dev == original.device, metadata.st_ino == original.inode,
                      metadata.st_uid == original.owner, metadata.st_gid == original.group,
                      metadata.st_mode == original.mode else { throw Failure("Destination identity changed: \(name)") }
                _ = try stream(input.descriptor, to: output, size: Int64(input.size), name: name)
                if input.size != original.size, ftruncate(output, input.size) != 0 { throw systemError(name) }
                guard io.sync(output) == 0 else { throw systemError(name) }
            } else {
                guard name == Self.undoName else { throw Failure("Unexpected new family member: \(name)") }
                // The atomic exclusive open cannot replace an undo log that
                // appeared after preflight. A failed fresh write may leave a
                // partial log: retain both recovery copies and stop before boot.
                let output = io.create(source.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard output >= 0 else { throw systemError(name) }
                defer { close(output) }
                _ = try stream(input.descriptor, to: output, size: Int64(input.size), name: name)
                guard fchmod(output, 0o644) == 0, io.sync(output) == 0 else { throw systemError(name) }
                // SSHFS may not implement directory fsync. The mandatory
                // guest sync below covers its new directory entry in that case.
                try syncDirectory()
            }
            let written = try source.openRegularFile(name, requireSingleLink: true)
            guard try fingerprint(written.descriptor, name: name) == manifest.after[name] else {
                throw Failure("Published cache hash mismatch: \(name)")
            }
            manifest.published.append(name)
            manifest.currentFile = nil
            try saveManifest()
        }
        try synchronizeGuest()
        pending.publicationSucceeded()
        manifest.state = "published-awaiting-receipt"
        try saveManifest()
    }

    private func familyNames(in directory: VPhoneConfinedDirectory) throws -> [String] {
        try directory.entries().filter { $0 == mainName || $0.hasPrefix(mainName + ".") || $0 == Self.undoName }.sorted()
    }

    private func copy(_ input: Int32, size: Int64, to directory: VPhoneConfinedDirectory, name: String) throws -> Fingerprint {
        let output = openat(directory.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw systemError(name) }
        defer { close(output) }
        let fingerprint = try stream(input, to: output, size: size, name: name)
        guard io.sync(output) == 0 else { throw systemError(name) }
        return fingerprint
    }

    private func stream(_ input: Int32, to output: Int32, size: Int64, name: String) throws -> Fingerprint {
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var offset: Int64 = 0
        var hasher = SHA256()
        while offset < size {
            let length = min(buffer.count, Int(size - offset))
            let count = buffer.withUnsafeMutableBytes { io.read(input, $0.baseAddress!, length, off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Failure("Short read or read failure copying \(name) at \(offset): errno \(errno)") }
            hasher.update(data: Data(buffer.prefix(count)))
            try buffer.withUnsafeBytes { bytes in
                var done = 0
                while done < count {
                    let written = io.write(output, bytes.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                    if written < 0, errno == EINTR { continue }
                    guard written > 0, written <= count - done else {
                        throw Failure("Short write or write failure copying \(name) at \(offset + Int64(done)): errno \(errno)")
                    }
                    done += written
                }
            }
            offset += Int64(count)
        }
        return Fingerprint(size: offset, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func fingerprint(_ descriptor: Int32, name: String) throws -> Fingerprint {
        try Self.fingerprint(descriptor, name: name, io: io)
    }

    private static func fingerprint(_ descriptor: Int32, name: String, io: IO) throws -> Fingerprint {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_size >= 0 else {
            throw Failure("\(name): \(String(cString: strerror(errno)))")
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var offset: Int64 = 0
        while offset < Int64(metadata.st_size) {
            let length = min(buffer.count, Int(Int64(metadata.st_size) - offset))
            let count = buffer.withUnsafeMutableBytes { io.read(descriptor, $0.baseAddress!, length, off_t(offset)) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Failure("Short read hashing \(name)") }
            hasher.update(data: Data(buffer.prefix(count)))
            offset += Int64(count)
        }
        guard unchanged(descriptor, since: metadata) else { throw Failure("File changed while hashing \(name)") }
        return Fingerprint(size: offset, sha256: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func unchanged(_ descriptor: Int32, since metadata: stat) -> Bool {
        var current = stat()
        return fstat(descriptor, &current) == 0 && current.st_size == metadata.st_size
            && current.st_mtim.tv_sec == metadata.st_mtim.tv_sec && current.st_mtim.tv_nsec == metadata.st_mtim.tv_nsec
            && current.st_ctim.tv_sec == metadata.st_ctim.tv_sec && current.st_ctim.tv_nsec == metadata.st_ctim.tv_nsec
    }

    private func saveManifest() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try directory.writeFile("manifest.json", contents: encoder.encode(manifest), mode: 0o600)
        guard fsync(directory.descriptor) == 0 else { throw systemError("local stage directory fsync") }
    }

    private func syncDirectory() throws {
        if io.sync(source.descriptor) != 0, errno != EINVAL, errno != ENOTSUP {
            throw systemError("cache directory fsync")
        }
    }

    private func systemError(_ path: String) -> Failure {
        Failure("\(path): \(String(cString: strerror(errno)))")
    }
}
#endif
