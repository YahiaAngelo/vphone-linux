#if os(Linux)
import CryptoKit
import Foundation
import Glibc

/// Strict SHA-256 code-page audit for the pinned arm64 cache format. This
/// checks page slots, not CMS trust, special slots, or instruction semantics.
/// Symbols/map files and the exact unsigned .atlas sidecar are fingerprinted
/// by the staging manifest; their contents are outside signature coverage.
public enum VPhoneDyldCacheAudit {
    public struct Report: Encodable {
        public let chunks: Int
        public let pages: Int
        public let signedBytes: Int64
        public let excludedSidecars: [String]
        public let scope = "SHA-256 code-page slots; excludes CMS trust, special slots, and sidecar contents"
    }
    private struct Reader {
        let file: VPhoneConfinedFile
        let name: String

        func read(_ offset: Int, _ length: Int) throws -> Data {
            try require(offset >= 0 && length >= 0 && offset <= file.size && length <= file.size - offset, "read bounds: \(name)")
            var data = Data(count: length)
            try data.withUnsafeMutableBytes { bytes in
                var done = 0
                while done < length {
                    let count = pread(file.descriptor, bytes.baseAddress! + done, length - done, off_t(offset + done))
                    if count < 0, errno == EINTR { continue }
                    try require(count > 0, "short read: \(name) at \(offset + done)")
                    done += count
                }
            }
            return data
        }

        func header() throws -> Data {
            let head = try read(0, 0x68)
            let magic = String(decoding: head.prefix(16), as: UTF8.self)
            try require(magic.hasPrefix("dyld_v1") && magic.contains("arm64"), "unsupported cache magic: \(name)")
            let offset = Int(head.le32(0x10)), count = Int(head.le32(0x14))
            try require((0x68 ... 0x10000).contains(offset) && (1 ... 64).contains(count), "unsupported mapping table: \(name)")
            _ = try read(offset, count * 32)
            return try read(0, offset)
        }
    }

    public static func verify(_ directoryURL: URL, _ mainName: String) throws {
        _ = try audit(directoryURL, mainName)
    }

    public static func audit(_ directoryURL: URL, _ mainName: String) throws -> Report {
        let directory = try VPhoneConfinedDirectory.pin(absolutePath: directoryURL.path)
        func reader(_ name: String) throws -> Reader {
            Reader(file: try directory.openRegularFile(name, requireSingleLink: true), name: name)
        }
        let main = try reader(mainName)
        let head = try main.header()
        var family: [(String, Data)] = [(mainName, head.subdata(in: 0x58 ..< 0x68))]
        if head.count >= 0x190 {
            let offset = Int(head.le32(0x188)), count = Int(head.le32(0x18c))
            try require(count <= 4096 && (offset == 0) == (count == 0), "invalid subcache table")
            let modern = head.count >= 0x1cc
            let size = modern ? 56 : 24
            let table = try main.read(offset, count * size)
            for index in 0 ..< count {
                let start = index * size
                let suffix: String
                if modern {
                    let bytes = table.subdata(in: start + 24 ..< start + 56)
                    try require(bytes.contains(0), "unterminated subcache suffix")
                    suffix = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                    let safe = suffix.utf8.allSatisfy {
                        (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || [45, 46, 95].contains($0)
                    }
                    try require(safe && suffix.hasPrefix(".") && suffix.count > 1 && !suffix.contains("..")
                                && suffix != ".symbols" && suffix != ".map", "unsafe subcache suffix")
                } else { suffix = ".\(index + 1)" }
                family.append((mainName + suffix, table.subdata(in: start ..< start + 16)))
            }
        }
        try require(Set(family.map(\.0)).count == family.count && Set(family.map(\.1)).count == family.count,
                    "duplicate cache name or UUID")
        try require(family.allSatisfy { $0.1 != Data(repeating: 0, count: 16) }, "zero cache UUID")
        let declared = Set(family.map(\.0))
        var excluded: [String] = []
        for name in try directory.entries() where name.hasPrefix(mainName + ".") && !declared.contains(name) {
            if name.hasSuffix(".symbols") || name.hasSuffix(".map") { excluded.append(name); continue }
            if name == mainName + ".atlas" {
                let sidecar = try reader(name)
                try require(sidecar.file.size > 0, "empty atlas sidecar")
                try require(!(try sidecar.read(0, min(16, Int(sidecar.file.size)))).starts(with: Data("dyld".utf8)),
                            "atlas sidecar has a dyld header")
                excluded.append(name)
                continue
            }
            throw VPhoneStagedDyldCache.Failure("Unlisted cache family file: \(name)")
        }
        var pages = 0, signedBytes: Int64 = 0
        for (name, uuid) in family {
            let chunk = try reader(name)
            let chunkHead = try chunk.header()
            try require(chunkHead.subdata(in: 0x58 ..< 0x68) == uuid, "cache UUID mismatch: \(name)")
            let coverage = try verifyPages(chunk, header: chunkHead)
            pages += coverage.pages
            signedBytes += coverage.bytes
        }
        return Report(chunks: family.count, pages: pages, signedBytes: signedBytes, excludedSidecars: excluded.sorted())
    }

    private static func verifyPages(_ chunk: Reader, header: Data) throws -> (pages: Int, bytes: Int64) {
        let signatureOffset64 = header.le64(0x28), signatureSize64 = header.le64(0x30)
        try require(signatureOffset64 > 0 && signatureSize64 > 0 && signatureSize64 <= 64 << 20
                    && signatureOffset64 <= UInt64(chunk.file.size)
                    && signatureSize64 == UInt64(chunk.file.size) - signatureOffset64,
                    "unsupported signature bounds: \(chunk.name)")
        let signatureOffset = Int(signatureOffset64)
        let signature = try chunk.read(signatureOffset, Int(signatureSize64))
        try require(signature.count >= 12 && signature.be32(0) == 0xfade0cc0, "invalid signature superblob")
        let length = Int(signature.be32(4)), count = Int(signature.be32(8))
        try require((1 ... 256).contains(count) && length >= 12 + count * 8 && length <= signature.count, "invalid superblob index")
        var slots = Set<UInt32>(), ranges: [Range<Int>] = [], directory: Data?
        for index in 0 ..< count {
            let slot = signature.be32(12 + index * 8), offset = Int(signature.be32(16 + index * 8))
            try require(slots.insert(slot).inserted && offset >= 12 + count * 8 && offset <= length - 8, "invalid superblob entry")
            let magic = signature.be32(offset), size = Int(signature.be32(offset + 4))
            try require(size >= 8 && size <= length - offset, "invalid signature blob bounds")
            let range = offset ..< offset + size
            try require(ranges.allSatisfy { !$0.overlaps(range) }, "overlapping signature blobs")
            ranges.append(range)
            if slot == 0 {
                try require(magic == 0xfade0c02, "invalid CodeDirectory magic")
                directory = signature.subdata(in: range)
            } else {
                try require(magic != 0xfade0c02 && !(0x1000 ..< 0x1005).contains(slot), "unsupported alternate CodeDirectory")
            }
        }
        guard let cd = directory else { throw VPhoneStagedDyldCache.Failure("Missing CodeDirectory") }
        try require(cd.count >= 44, "truncated CodeDirectory")
        let version = cd.be32(8)
        let sizes: [UInt32: Int] = [0x20000: 44, 0x20001: 44, 0x20100: 48, 0x20200: 52,
                                    0x20300: 64, 0x20400: 88, 0x20500: 96, 0x20600: 108]
        guard let headerSize = sizes[version], cd.count >= headerSize else { throw VPhoneStagedDyldCache.Failure("Unsupported CodeDirectory version or size") }
        let hashes = Int(cd.be32(16)), special = Int(cd.be32(24)), countPages = Int(cd.be32(28)), limit = Int(cd.be32(32))
        try require(cd[36] == 32 && cd[37] == 2 && (12 ... 20).contains(cd[39]) && cd.be32(40) == 0,
                    "unsupported CodeDirectory hash shape")
        if version >= 0x20100 { try require(cd.be32(44) == 0, "scatter CodeDirectory unsupported") }
        if version >= 0x20300 { try require(cd.be32(52) == 0 && cd.be64(56) == 0, "64-bit CodeDirectory limit unsupported") }
        if version >= 0x20500 { try require(cd.be32(92) == 0, "pre-encryption hashes unsupported") }
        if version >= 0x20600 { try require(cd.subdata(in: 96 ..< 108) == Data(repeating: 0, count: 12), "linkage data unsupported") }
        let pageSize = 1 << Int(cd[39])
        try require(countPages > 0 && limit == signatureOffset && countPages * pageSize == limit,
                    "incomplete CodeDirectory page coverage")
        let stringsEnd = hashes - special * 32
        try require(stringsEnd >= headerSize && hashes <= cd.count && countPages * 32 <= cd.count - hashes,
                    "CodeDirectory hash bounds invalid")
        func checkString(_ offset: Int) throws {
            try require(offset >= headerSize && offset < stringsEnd, "invalid CodeDirectory string offset")
            try require(cd[offset ..< stringsEnd].contains(0), "unterminated CodeDirectory string")
        }
        try checkString(Int(cd.be32(20)))
        if version >= 0x20200, cd.be32(48) != 0 { try checkString(Int(cd.be32(48))) }
        for first in stride(from: 0, to: countPages, by: 64) {
            let pages = min(64, countPages - first)
            let data = try chunk.read(first * pageSize, pages * pageSize)
            for page in 0 ..< pages {
                let digest = Data(SHA256.hash(data: data[page * pageSize ..< (page + 1) * pageSize]))
                let offset = hashes + (first + page) * 32
                try require(digest == cd.subdata(in: offset ..< offset + 32), "CodeDirectory page mismatch: \(chunk.name) page \(first + page)")
            }
        }
        return (countPages, Int64(limit))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw VPhoneStagedDyldCache.Failure(message) }
    }
}

private extension Data {
    func le32(_ offset: Int) -> UInt32 { (0 ..< 4).reduce(0) { $0 | UInt32(self[offset + $1]) << ($1 * 8) } }
    func le64(_ offset: Int) -> UInt64 { (0 ..< 8).reduce(0) { $0 | UInt64(self[offset + $1]) << ($1 * 8) } }
    func be32(_ offset: Int) -> UInt32 { (0 ..< 4).reduce(0) { ($0 << 8) | UInt32(self[offset + $1]) } }
    func be64(_ offset: Int) -> UInt64 { (0 ..< 8).reduce(0) { ($0 << 8) | UInt64(self[offset + $1]) } }
}
#endif
