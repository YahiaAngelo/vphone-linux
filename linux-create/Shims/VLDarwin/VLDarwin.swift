@_exported import Glibc
import Foundation

// Linux Foundation has no Objective-C autorelease runtime.
public func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}

// macOS names for Linux stat fields.
public extension stat {
    var st_mtimespec: timespec { st_mtim }
    var st_atimespec: timespec { st_atim }
    var st_ctimespec: timespec { st_ctim }
}

// macOS signatures: initgroups takes an int group, setgroups an int count.
@discardableResult
public func initgroups(_ name: UnsafePointer<CChar>, _ group: Int32) -> Int32 {
    Glibc.initgroups(name, gid_t(bitPattern: group))
}

@discardableResult
public func setgroups(_ count: Int32, _ groups: UnsafePointer<gid_t>?) -> Int32 {
    Glibc.setgroups(Int(count), groups)
}

/// macOS clonefile(2) on Linux: copy-on-write clones through the FICLONE ioctl (btrfs, XFS),
/// recursively for directories. Fails with -1/errno where the filesystem cannot reflink; callers
/// then copy the bytes, as vphone-cli already does off APFS. Symlinks are recreated.
public func clonefile(_ src: UnsafePointer<CChar>, _ dst: UnsafePointer<CChar>, _ flags: UInt32) -> Int32 {
    let FICLONE: UInt = 0x4004_9409
    func clone(_ s: String, _ d: String) -> Bool {
        var st = stat()
        guard lstat(s, &st) == 0 else { return false }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            guard mkdir(d, st.st_mode & 0o7777) == 0 else { return false }
            guard let dir = opendir(s) else { return false }
            defer { closedir(dir) }
            while let entry = readdir(dir) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                if name == "." || name == ".." { continue }
                guard clone(s + "/" + name, d + "/" + name) else { return false }
            }
            return true
        case S_IFLNK:
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(s, &buf, buf.count - 1)
            guard n >= 0 else { return false }
            return symlink(buf, d) == 0
        case S_IFREG:
            let from = open(s, O_RDONLY)
            guard from >= 0 else { return false }
            defer { close(from) }
            let to = open(d, O_WRONLY | O_CREAT | O_EXCL, st.st_mode & 0o7777)
            guard to >= 0 else { return false }
            defer { close(to) }
            return ioctl(to, FICLONE, from) == 0
        default:
            errno = ENOTSUP
            return false
        }
    }
    return clone(String(cString: src), String(cString: dst)) ? 0 : -1
}

// Glibc's SOCK_* constants are an enum; macOS code passes them as int.
public func socket(_ domain: Int32, _ type: __socket_type, _ proto: Int32) -> Int32 {
    Glibc.socket(domain, Int32(type.rawValue), proto)
}

// Linux has these lseek whences (same meaning as macOS) behind _GNU_SOURCE.
public let SEEK_DATA: Int32 = 3
public let SEEK_HOLE: Int32 = 4

/// macOS _NSGetExecutablePath on Linux: /proc/self/exe.
public func _NSGetExecutablePath(_ buffer: UnsafeMutablePointer<CChar>?, _ size: UnsafeMutablePointer<UInt32>) -> Int32 {
    var path = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
    let n = readlink("/proc/self/exe", &path, path.count - 1)
    guard n > 0 else { return -1 }
    guard let buffer, Int(size.pointee) > n else { size.pointee = UInt32(n + 1); return -1 }
    for i in 0..<n { buffer[i] = path[i] }
    buffer[n] = 0
    return 0
}

// macOS dirent has d_namlen; on Linux it is the length of the NUL-terminated d_name.
public extension dirent {
    var d_namlen: UInt16 {
        withUnsafeBytes(of: d_name) { raw in UInt16(strnlen(raw.bindMemory(to: CChar.self).baseAddress!, raw.count)) }
    }
}

// MARK: - File APIs (macOS names over Linux calls; see Shims/LinuxSys)

@_exported import LinuxSys

public let MAXPATHLEN: Int32 = PATH_MAX
public let MNAMELEN: Int32 = 1024
public let CLONE_NOFOLLOW: Int32 = 0x0001
public let CLONE_NOOWNERCOPY: Int32 = 0x0002
public let RENAME_EXCL: Int32 = 0x0004

// macOS fcntl commands, at their macOS values (unused by Linux's fcntl).
public let F_NOCACHE: Int32 = 48
public let F_GETPATH: Int32 = 50
public let F_FULLFSYNC: Int32 = 51 // Linux fcntl fails with EINVAL; callers fall back to fsync
public let F_LOG2PHYS_EXT: Int32 = 65
public let F_PUNCHHOLE: Int32 = 99

public struct log2phys {
    public var l2p_flags: UInt32 = 0
    public var l2p_contigbytes: off_t = 0
    public var l2p_devoffset: off_t = 0
    public init() {}
}

public struct fpunchhole_t {
    public var fp_flags: UInt32 = 0
    public var reserved: UInt32 = 0
    public var fp_offset: off_t = 0
    public var fp_length: off_t = 0
    public init() {}
}

/// F_GETPATH: the descriptor's path, from /proc/self/fd.
public func fcntl(_ fd: Int32, _ cmd: Int32, _ buffer: inout [CChar]) -> Int32 {
    guard cmd == F_GETPATH else { errno = EINVAL; return -1 }
    let n = readlink("/proc/self/fd/\(fd)", &buffer, buffer.count - 1)
    guard n >= 0 else { return -1 }
    buffer[n] = 0
    return 0
}

/// F_PUNCHHOLE through fallocate(PUNCH_HOLE | KEEP_SIZE).
public func fcntl(_ fd: Int32, _ cmd: Int32, _ hole: inout fpunchhole_t) -> Int32 {
    guard cmd == F_PUNCHHOLE else { errno = EINVAL; return -1 }
    return vl_punch_hole(fd, hole.fp_offset, hole.fp_length)
}

/// F_LOG2PHYS_EXT has no Linux equivalent here (FIEMAP would be); report unsupported.
public func fcntl(_ fd: Int32, _ cmd: Int32, _ request: inout log2phys) -> Int32 {
    errno = ENOTSUP
    return -1
}

public typealias copyfile_flags_t = UInt32
public let COPYFILE_ACL: Int32 = 1 << 0
public let COPYFILE_STAT: Int32 = 1 << 1
public let COPYFILE_XATTR: Int32 = 1 << 2
public let COPYFILE_DATA: Int32 = 1 << 3

/// fcopyfile(3) for the two flags vphone-cli uses: COPYFILE_DATA (copy_file_range, which
/// reflinks where it can) and COPYFILE_XATTR (every extended attribute).
public func fcopyfile(_ from: Int32, _ to: Int32, _ state: OpaquePointer?, _ flags: copyfile_flags_t) -> Int32 {
    if flags & copyfile_flags_t(COPYFILE_XATTR) != 0 {
        let size = flistxattr(from, nil, 0)
        if size > 0 {
            var names = [CChar](repeating: 0, count: size)
            let got = flistxattr(from, &names, size)
            var start = 0
            while got > 0, start < got {
                let name = names.withUnsafeBufferPointer { String(cString: $0.baseAddress! + start) }
                start += name.utf8.count + 1
                let length = fgetxattr(from, name, nil, 0)
                guard length >= 0 else { continue }
                var value = [UInt8](repeating: 0, count: max(length, 1))
                let read = fgetxattr(from, name, &value, length)
                guard read >= 0 else { continue }
                if fsetxattr(to, name, value, read, 0) != 0 { return -1 }
            }
        }
    }
    if flags & copyfile_flags_t(COPYFILE_DATA) != 0 {
        while true {
            let n = vl_copy_file_range(from, to, 1 << 30)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                // Filesystems without copy_file_range: plain read/write.
                guard errno == EXDEV || errno == ENOSYS || errno == EOPNOTSUPP || errno == EINVAL else { return -1 }
                var buffer = [UInt8](repeating: 0, count: 1 << 20)
                while true {
                    let r = read(from, &buffer, buffer.count)
                    if r == 0 { return 0 }
                    if r < 0 { if errno == EINTR { continue }; return -1 }
                    var done = 0
                    while done < r {
                        let w = buffer.withUnsafeBytes { write(to, $0.baseAddress! + done, r - done) }
                        if w < 0 { if errno == EINTR { continue }; return -1 }
                        done += w
                    }
                }
            }
        }
    }
    return 0
}

/// fclonefileat(2): a new file `name` in `dirfd`, a FICLONE copy of `src`. Fails (ENOTSUP or
/// the ioctl's errno, nothing left behind) where the filesystem cannot reflink.
public func fclonefileat(_ src: Int32, _ dirfd: Int32, _ name: UnsafePointer<CChar>, _ flags: UInt32) -> Int32 {
    var st = stat()
    guard fstat(src, &st) == 0 else { return -1 }
    let mode = (flags & UInt32(CLONE_NOOWNERCOPY) != 0 ? st.st_mode & 0o777 : st.st_mode & 0o7777)
    let out = openat(dirfd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard out >= 0 else { return -1 }
    if vl_ficlone(out, src) != 0 {
        let saved = errno
        close(out)
        unlinkat(dirfd, name, 0)
        errno = saved
        return -1
    }
    close(out)
    return 0
}

/// renamex_np(2) with RENAME_EXCL: renameat2(RENAME_NOREPLACE).
public func renamex_np(_ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>, _ flags: UInt32) -> Int32 {
    if flags & UInt32(RENAME_EXCL) != 0 { return vl_renameat2_noreplace(from, to) }
    return rename(from, to)
}

// MARK: - Extended attributes and ACLs (macOS signatures)

public let XATTR_NOFOLLOW: Int32 = 0x0001

public func listxattr(_ path: UnsafePointer<CChar>, _ names: UnsafeMutablePointer<CChar>?, _ size: Int, _ options: Int32) -> Int {
    options & XATTR_NOFOLLOW != 0 ? llistxattr(path, names, size) : LinuxSys.listxattr(path, names, size)
}

public func getxattr(_ path: UnsafePointer<CChar>, _ name: UnsafePointer<CChar>, _ value: UnsafeMutableRawPointer?,
                     _ size: Int, _ position: UInt32, _ options: Int32) -> Int {
    options & XATTR_NOFOLLOW != 0 ? lgetxattr(path, name, value, size) : LinuxSys.getxattr(path, name, value, size)
}

// macOS extended (NFSv4-style) ACLs do not exist on Linux: every file reads as having none,
// which is what macOS reports for a file without one.
public typealias acl_t = OpaquePointer
public let ACL_TYPE_EXTENDED: Int32 = 0x0100
public func acl_get_link_np(_ path: UnsafePointer<CChar>, _ type: Int32) -> acl_t? { errno = ENOENT; return nil }
public func acl_get_file(_ path: UnsafePointer<CChar>, _ type: Int32) -> acl_t? { errno = ENOENT; return nil }
public func acl_to_text(_ acl: acl_t, _ length: UnsafeMutablePointer<Int>?) -> UnsafeMutablePointer<CChar>? { nil }
@discardableResult public func acl_free(_ object: UnsafeMutableRawPointer?) -> Int32 { 0 }

public let COPYFILE_SECURITY: Int32 = COPYFILE_STAT | COPYFILE_ACL
public let COPYFILE_NOFOLLOW: Int32 = 1 << 18

/// copyfile(3), path-based, for COPYFILE_DATA / COPYFILE_SECURITY / COPYFILE_XATTR: a directory
/// source creates the directory (not its contents, as without COPYFILE_RECURSIVE); a file is
/// copied over (created or truncated); SECURITY copies mode and, as root, owner. Like macOS, the
/// source is followed unless COPYFILE_NOFOLLOW (then a symlink is recreated).
public func copyfile(_ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>, _ state: OpaquePointer?, _ flags: copyfile_flags_t) -> Int32 {
    var st = stat()
    let nofollow = flags & copyfile_flags_t(COPYFILE_NOFOLLOW) != 0
    guard (nofollow ? lstat(from, &st) : stat(from, &st)) == 0 else { return -1 }
    let security = flags & copyfile_flags_t(COPYFILE_SECURITY) != 0
    switch st.st_mode & S_IFMT {
    case S_IFDIR:
        if mkdir(to, st.st_mode & 0o7777) != 0 && errno != EEXIST { return -1 }
        if security {
            _ = chmod(to, st.st_mode & 0o7777)
            if geteuid() == 0 { _ = lchown(to, st.st_uid, st.st_gid) }
        }
        return 0
    case S_IFLNK:
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(from, &buf, buf.count - 1)
        guard n >= 0 else { return -1 }
        return symlink(buf, to)
    default:
        let input = open(from, O_RDONLY | O_CLOEXEC)
        guard input >= 0 else { return -1 }
        defer { close(input) }
        let output = open(to, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, st.st_mode & 0o7777)
        guard output >= 0 else { return -1 }
        defer { close(output) }
        let dataFlags = flags & copyfile_flags_t(COPYFILE_DATA | COPYFILE_XATTR)
        if dataFlags != 0, fcopyfile(input, output, nil, dataFlags) != 0 { return -1 }
        if security {
            _ = fchmod(output, st.st_mode & 0o7777)
            if geteuid() == 0 { _ = fchown(output, st.st_uid, st.st_gid) }
        }
        return 0
    }
}

// CoreFoundation type IDs, for the one use vphone-cli has: "is this NSNumber a boolean". Linux
// Foundation's booleans are NSNumbers whose objCType is "B" or "c" (property lists decode
// integers as "q", so a Bool is not confused with a one-byte integer there).
public func CFBooleanGetTypeID() -> UInt { 1 }
public func CFGetTypeID(_ number: NSNumber) -> UInt {
    let type = String(cString: number.objCType)
    return type == "B" || type == "c" ? CFBooleanGetTypeID() : 2
}

// macOS renameatx_np(2). vphone-cli 2.12 swaps two paths atomically to publish restored OTA
// files (and the guest daemon uses it for system apps). Linux has renameat2(RENAME_EXCHANGE);
// the call sites pass Swift strings, so the shim takes strings too.
public let RENAME_SWAP: Int32 = 0x0000_0002

// glibc has the symbol, but Swift's Glibc module only declares renameat2 under _GNU_SOURCE.
@_silgen_name("renameat2")
private func vphone_renameat2(_ olddirfd: Int32, _ oldpath: UnsafePointer<CChar>,
                              _ newdirfd: Int32, _ newpath: UnsafePointer<CChar>,
                              _ flags: UInt32) -> Int32

@discardableResult
public func renameatx_np(_ fromFD: Int32, _ from: String, _ toFD: Int32, _ to: String, _ flags: UInt32) -> Int32 {
    let exchange: UInt32 = 2 // RENAME_EXCHANGE
    return from.withCString { fromPath in
        to.withCString { toPath in
            if flags & UInt32(RENAME_SWAP) != 0 {
                return vphone_renameat2(fromFD, fromPath, toFD, toPath, exchange)
            }
            return renameat(fromFD, fromPath, toFD, toPath)
        }
    }
}

// macOS confstr(_CS_DARWIN_USER_CACHE_DIR) is the per-user cache directory. Linux has no such
// selector; vphone-cli 2.12 uses it for the paravirtualized-graphics shader cache. macOS returns
// a trailing slash, and the caller drops the last byte.
public func vphoneUserCacheDir(_ buffer: UnsafeMutablePointer<CChar>?, _ length: Int) -> Int {
    let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache", isDirectory: true).path + "/"
    return path.withCString { source in
        let needed = strlen(source) + 1
        guard let buffer else { return needed }
        guard length >= needed else { return 0 }
        buffer.update(from: source, count: needed)
        return needed
    }
}
