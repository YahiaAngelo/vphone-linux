#if os(Linux)
import CryptoKit
import Darwin
import Foundation
import Glibc

/// Keep random cache edits on the host. Publication is sequential and is not a
/// family-wide transaction: any error must stop the installer before boot.
public final class VPhoneStagedDyldCache {
    public static let undoName = ".vphone-dsc-undo.json"
    public static let pendingName = ".vphone-dsc-pending.json"

    public static func priorGuestPatches(
        wasInstalled: Bool, receipt: Set<String>?, priorFallback: Set<String> = []
    ) -> Set<String> {
        receipt ?? (wasInstalled ? priorFallback : [])
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

    /// Fence ordinary boot until the complete cache family is durable. The
    /// retained stage also permits verified rollback through the SSH ramdisk.
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
            let recoveryPlanSHA256: String?
            let guestECID: String?
        }

        private let bundleDirectory: VPhoneConfinedDirectory
        private let bundleIdentity: Identity
        private let diskIdentity: Identity
        private let sync: (Int32) -> Int32
        private let guestECID: String?
        private var journalIdentity: Identity?
        private var journalBytes: Data?
        private var journalFile: VPhoneConfinedFile?
        private var journalCreated = false
        private var cleared = false
        private var published = false
        private var unchangedPublication = false
        var recoveryStage: String?
        private var recoveryPlanSHA256: String?

        public var retainsRecoveryFiles: Bool { journalCreated && !cleared }

        public convenience init(bundleDirectory: VPhoneConfinedDirectory, guestECID: String? = nil) throws {
            try self.init(bundleDirectory: bundleDirectory, guestECID: guestECID, sync: { Glibc.fsync($0) })
        }

        init(bundleDirectory: VPhoneConfinedDirectory, guestECID: String? = nil, sync: @escaping (Int32) -> Int32,
             recovering: Bool = false, allowLegacy: Bool = false) throws {
            self.bundleDirectory = bundleDirectory
            self.sync = sync
            if let guestECID {
                guard guestECID.count == 16,
                      guestECID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let value = UInt64(guestECID, radix: 16), value != 0 else {
                    throw Failure("Cache publication requires a normalized selected guest ECID")
                }
                self.guestECID = String(format: "%016llX", value)
            } else {
                self.guestECID = nil
            }
            let metadata = try bundleDirectory.metadata()
            bundleIdentity = Identity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino), size: nil)
            let disk = try bundleDirectory.openRegularFile("Disk.img", requireSingleLink: true)
            diskIdentity = Identity(device: UInt64(disk.device), inode: UInt64(disk.inode), size: Int64(disk.size))
            if try bundleDirectory.exists(VPhoneStagedDyldCache.pendingName) {
                if recovering {
                    let file = try bundleDirectory.openRegularFile(VPhoneStagedDyldCache.pendingName, requireSingleLink: true)
                    guard file.owner == geteuid(), file.mode & 0o777 == 0o600,
                          file.size > 0, file.size <= 65536 else {
                        throw Failure("Pending cache journal is not a private regular file owned by this account")
                    }
                    guard flock(file.descriptor, LOCK_EX | LOCK_NB) == 0 else {
                        throw Failure("A cache publisher or recovery process still owns the pending journal")
                    }
                    let bytes = try Self.readJournal(file)
                    let journal = try JSONDecoder().decode(Journal.self, from: bytes)
                    guard journal.schemaVersion == 2 || (journal.schemaVersion == 1 && allowLegacy) else {
                        throw Failure("Legacy pending journal: stop the original CFW command, then use cfw recover-cache --legacy-journal")
                    }
                    guard journal.schemaVersion == 1 || journal.recoveryPlanSHA256?.count == 64 else {
                        throw Failure("Pending journal has no complete recovery-plan digest")
                    }
                    guard self.guestECID != nil,
                          journal.schemaVersion == 1 || journal.guestECID == self.guestECID else {
                        throw Failure("Recovery guest ECID does not match the pending publication; refusing to contact another guest")
                    }
                    guard journal.bundle == bundleIdentity, journal.disk == diskIdentity else {
                        throw Failure("Pending cache journal does not describe this VM bundle and Disk.img")
                    }
                    journalFile = file
                    journalIdentity = Identity(device: UInt64(file.device), inode: UInt64(file.inode), size: Int64(file.size))
                    journalBytes = bytes
                    recoveryStage = journal.recoveryStage
                    recoveryPlanSHA256 = journal.recoveryPlanSHA256
                    journalCreated = true
                    try requireOwnership()
                    return
                }
                let metadata = try bundleDirectory.status(VPhoneStagedDyldCache.pendingName)
                let journal = metadata.map { $0.st_size <= 65536 && $0.st_mode & S_IFMT == S_IFREG } == true
                    ? (try? JSONDecoder().decode(Journal.self, from: bundleDirectory.readData(VPhoneStagedDyldCache.pendingName))) : nil
                let path = try bundleDirectory.path
                func quoted(_ value: String) -> String {
                    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
                }
                let command = "sudo vphone-cli cfw recover-cache -l \(quoted((path as NSString).deletingLastPathComponent)) \(quoted((path as NSString).lastPathComponent))"
                throw Failure("Unresolved dyld cache publication in \(path). Recovery stage: \(journal?.recoveryStage ?? "unknown; inspect the pending journal"). Boot the SSH ramdisk and run \(command) before retrying CFW or ordinary boot.")
            }
            if recovering { throw Failure("This VM has no pending cache publication to recover") }
        }

        static func recovering(bundleDirectory: VPhoneConfinedDirectory, guestECID: String, allowLegacy: Bool) throws -> PendingPublication {
            try PendingPublication(bundleDirectory: bundleDirectory, guestECID: guestECID, sync: { Glibc.fsync($0) },
                                   recovering: true, allowLegacy: allowLegacy)
        }

        public static func validateRecoveryTarget(bundleDirectory: VPhoneConfinedDirectory,
                                                 guestECID: String, allowLegacy: Bool = false) throws {
            let pending = try recovering(bundleDirectory: bundleDirectory, guestECID: guestECID, allowLegacy: allowLegacy)
            pending.releasePublicationLock()
        }

        private static func readJournal(_ file: VPhoneConfinedFile) throws -> Data {
            var metadata = stat()
            guard fstat(file.descriptor, &metadata) == 0, metadata.st_size > 0, metadata.st_size <= 65536 else {
                throw Failure("Pending cache journal is empty or too large")
            }
            var data = Data(count: Int(metadata.st_size))
            try data.withUnsafeMutableBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Glibc.pread(file.descriptor, bytes.baseAddress! + offset, bytes.count - offset, off_t(offset))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Failure("Could not read the complete pending cache journal") }
                    offset += count
                }
            }
            guard VPhoneStagedDyldCache.unchanged(file.descriptor, since: metadata) else {
                throw Failure("Pending cache journal changed while it was being read")
            }
            return data
        }

        func begin(recoveryStage: String, recoveryPlanSHA256: String) throws {
            guard journalIdentity == nil else { throw Failure("Dyld cache publication was already started") }
            guard let guestECID else { throw Failure("Cache publication requires the selected guest ECID") }
            let bundle = try bundleDirectory.metadata()
            let disk = try bundleDirectory.openRegularFile("Disk.img", requireSingleLink: true)
            guard bundleIdentity == Identity(device: UInt64(bundle.st_dev), inode: UInt64(bundle.st_ino), size: nil),
                  diskIdentity == Identity(device: UInt64(disk.device), inode: UInt64(disk.inode), size: Int64(disk.size))
            else { throw Failure("VM bundle or Disk.img identity changed before cache publication") }
            let journal = Journal(schemaVersion: 2, bundle: bundleIdentity, disk: diskIdentity,
                                  recoveryStage: recoveryStage, recoveryPlanSHA256: recoveryPlanSHA256, guestECID: guestECID)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(journal)
            let temporary = ".vphone-dsc-journal-\(UUID().uuidString)"
            let file = openat(bundleDirectory.descriptor, temporary,
                              O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0 else { throw Failure("Could not exclusively create pending cache journal: \(String(cString: strerror(errno)))") }
            var adopted = false
            defer {
                if !journalCreated {
                    var opened = stat(), named = stat()
                    if fstat(file, &opened) == 0,
                       fstatat(bundleDirectory.descriptor, temporary, &named, AT_SYMLINK_NOFOLLOW) == 0,
                       named.st_dev == opened.st_dev, named.st_ino == opened.st_ino {
                        unlinkat(bundleDirectory.descriptor, temporary, 0)
                    }
                }
                if !adopted { close(file) }
            }
            var metadata = stat()
            guard fchmod(file, 0o600) == 0, fstat(file, &metadata) == 0 else { throw Failure("Could not inspect pending cache journal") }
            journalFile = VPhoneConfinedFile(descriptor: file, metadata: metadata)
            adopted = true
            guard flock(file, LOCK_EX | LOCK_NB) == 0 else { throw Failure("Could not lock the pending cache journal") }
            journalIdentity = Identity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino), size: Int64(data.count))
            journalBytes = data
            self.recoveryStage = recoveryStage
            self.recoveryPlanSHA256 = recoveryPlanSHA256
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Glibc.write(file, bytes.baseAddress! + offset, bytes.count - offset)
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw Failure("Pending cache journal write failed: \(String(cString: strerror(errno)))") }
                    offset += count
                }
            }
            guard sync(file) == 0 else {
                throw Failure("Pending cache journal fsync: \(String(cString: strerror(errno)))")
            }
            // Publish a complete journal atomically. A torn temporary file
            // cannot strand a boot fence before any guest bytes are written.
            let prefix = "/proc/self/fd/\(bundleDirectory.descriptor)/"
            guard renamex_np(prefix + temporary, prefix + VPhoneStagedDyldCache.pendingName, UInt32(RENAME_EXCL)) == 0 else {
                throw Failure("Could not publish pending journal exclusively: \(String(cString: strerror(errno)))")
            }
            journalCreated = true
            guard sync(bundleDirectory.descriptor) == 0 else {
                throw Failure("Pending cache journal directory fsync: \(String(cString: strerror(errno)))")
            }
            try requireOwnership()
        }

        func publicationSucceeded() { published = true }

        func publicationUnchanged() throws {
            guard journalIdentity == nil, !journalCreated else {
                throw Failure("An active cache publication cannot be marked unchanged")
            }
            let bundle = try bundleDirectory.metadata()
            let disk = try bundleDirectory.openRegularFile("Disk.img", requireSingleLink: true)
            guard bundleIdentity == Identity(device: UInt64(bundle.st_dev), inode: UInt64(bundle.st_ino), size: nil),
                  diskIdentity == Identity(device: UInt64(disk.device), inode: UInt64(disk.inode), size: Int64(disk.size)),
                  try !bundleDirectory.exists(VPhoneStagedDyldCache.pendingName) else {
                throw Failure("VM identity or pending publication changed before the unchanged cache was committed")
            }
            unchangedPublication = true
            published = true
        }

        func releasePublicationLock() { journalFile = nil }

        func validateRecoveryPlan(_ manifest: Manifest) throws {
            if let recoveryPlanSHA256, try manifest.recoveryPlanSHA256() != recoveryPlanSHA256 {
                throw Failure("Recovery manifest no longer matches its pending journal")
            }
        }

        func requirePublished() throws {
            guard published, journalIdentity != nil || unchangedPublication else { throw Failure("Cache publication and guest sync have not completed") }
        }

        func clear() throws {
            try requirePublished()
            try requireOwnership()
            guard unlinkat(bundleDirectory.descriptor, VPhoneStagedDyldCache.pendingName, 0) == 0,
                  sync(bundleDirectory.descriptor) == 0 else {
                throw Failure("Pending cache journal removal fsync: \(String(cString: strerror(errno)))")
            }
            cleared = true
        }

        func requireOwnership() throws {
            let bundle = try bundleDirectory.metadata()
            let disk = try bundleDirectory.openRegularFile("Disk.img", requireSingleLink: true)
            guard bundleIdentity == Identity(device: UInt64(bundle.st_dev), inode: UInt64(bundle.st_ino), size: nil),
                  diskIdentity == Identity(device: UInt64(disk.device), inode: UInt64(disk.inode), size: Int64(disk.size)) else {
                throw Failure("VM bundle or Disk.img identity changed during cache publication")
            }
            guard let expected = journalIdentity, let metadata = try bundleDirectory.status(VPhoneStagedDyldCache.pendingName),
                  let journalFile,
                  metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
                  metadata.st_uid == geteuid(), metadata.st_mode & 0o777 == 0o600,
                  expected == Identity(device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino), size: Int64(metadata.st_size)),
                  try bundleDirectory.refersTo(VPhoneStagedDyldCache.pendingName, file: journalFile),
                  try Self.readJournal(journalFile) == journalBytes
            else { throw Failure("Pending cache journal changed; retained recovery stage") }
        }
    }

    /// The installer receipt describes the complete CFW run. Cache publication
    /// is committed separately once its bytes and guest sync are verified.
    public final class Completion {
        private let sync: (Int32) -> Int32

        public convenience init() { self.init(sync: { Glibc.fsync($0) }) }
        init(sync: @escaping (Int32) -> Int32) { self.sync = sync }

        public func recordReceipt(
            in directory: VPhoneConfinedDirectory,
            pending: PendingPublication,
            synchronizeGuest: () throws -> Void,
            write: () throws -> Void,
        ) throws {
            try pending.requirePublished()
            try synchronizeGuest()
            try write()
            guard sync(directory.descriptor) == 0 else {
                throw Failure("Receipt directory fsync: \(String(cString: strerror(errno)))")
            }
        }

        public func shouldRemoveWork(pending: PendingPublication) -> Bool {
            !pending.retainsRecoveryFiles
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
        var permissions: [String: Permissions]?

        func recoveryPlanSHA256() throws -> String {
            struct Plan: Encodable {
                let before: [String: Fingerprint]
                let after: [String: Fingerprint]
                let permissions: [String: Permissions]?
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Plan(before: before, after: after, permissions: permissions))
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Permissions: Codable {
        let owner: UInt32
        let group: UInt32
        let mode: UInt32
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
        manifest.permissions = [:]
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
            manifest.permissions?[name] = Permissions(owner: file.owner, group: file.group, mode: file.mode & 0o777)
        }
        var space = statvfs()
        guard fstatvfs(directory.descriptor, &space) == 0 else { throw systemError("statvfs") }
        let (available, availableOverflow) = UInt64(space.f_bavail).multipliedReportingOverflow(by: UInt64(space.f_frsize))
        guard !availableOverflow else { throw Failure("Local free-space calculation overflow") }
        try Self.requireStagingSpace(cacheBytes: bytes, availableBytes: available)
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
        spaceRequired(for: bytes, seed: true)
    }

    static func spaceRequired(for bytes: UInt64, seed: Bool = false) -> UInt64? {
        let (families, overflow) = bytes.multipliedReportingOverflow(by: seed ? 5 : 4)
        let (required, reserveOverflow) = families.addingReportingOverflow(1 << 30)
        return overflow || reserveOverflow ? nil : required
    }

    static func requireStagingSpace(cacheBytes: UInt64, availableBytes: UInt64) throws {
        guard let required = spaceRequired(for: cacheBytes), availableBytes > required else {
            throw Failure("Insufficient CFW scratch space: the selected cache family needs 4 times its size plus 1 GiB free (cache: \(cacheBytes) bytes, available: \(availableBytes) bytes). Select a larger --work-parent.")
        }
    }

    public static func preflightSpace(source: VPhoneConfinedDirectory, mainName: String,
                                      workDirectory: VPhoneConfinedDirectory) throws {
        let names = try source.entries().filter { $0 == mainName || $0.hasPrefix(mainName + ".") || $0 == undoName }
        guard names.contains(mainName) else { throw Failure("Missing main cache \(mainName)") }
        var bytes: UInt64 = 0
        for name in names {
            let file = try source.openRegularFile(name, requireSingleLink: true)
            guard file.size > 0 else { throw Failure("Empty cache family file: \(name)") }
            let (total, overflow) = bytes.addingReportingOverflow(UInt64(file.size))
            guard !overflow else { throw Failure("Cache family size overflow") }
            bytes = total
        }
        var space = statvfs()
        guard fstatvfs(workDirectory.descriptor, &space) == 0 else {
            throw Failure("CFW scratch statvfs: \(String(cString: strerror(errno)))")
        }
        let (available, overflow) = UInt64(space.f_bavail).multipliedReportingOverflow(by: UInt64(space.f_frsize))
        guard !overflow else { throw Failure("Local free-space calculation overflow") }
        try requireStagingSpace(cacheBytes: bytes, availableBytes: available)
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
        defer { pending.releasePublicationLock() }
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
        let changed = Set(names).union(manifest.before.keys).filter { manifest.after[$0] != manifest.before[$0] }
            .sorted { left, right in
                if left == Self.undoName { return false }
                if right == Self.undoName { return true }
                return left < right
            }
        if changed.isEmpty {
            try synchronizeGuest()
            manifest.state = "unchanged"
            try saveManifest()
            try pending.publicationUnchanged()
            return
        }
        // Make every newly created component of the recovery path durable
        // before a durable journal can refer to it or any remote byte changes.
        guard io.sync(workDirectory.descriptor) == 0 else { throw systemError("Recovery work directory fsync") }
        guard io.sync(workParent.descriptor) == 0 else { throw systemError("Recovery work parent fsync") }
        try pending.begin(recoveryStage: directory.path, recoveryPlanSHA256: manifest.recoveryPlanSHA256())
        manifest.state = "publishing"
        try saveManifest()
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
        manifest.state = "published"
        try saveManifest()
        try pending.clear()
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

    static func fingerprint(_ descriptor: Int32, name: String, io: IO) throws -> Fingerprint {
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

    static func unchanged(_ descriptor: Int32, since metadata: stat) -> Bool {
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
