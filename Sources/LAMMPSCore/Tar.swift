import Foundation
// Compression is Apple-only. Off-Apple (the Linux CLI, GJOB-190) the DEFLATE work is done by the
// pure-Swift path at the bottom of this file. Darwin/Glibc are here for fnmatch(3).
#if canImport(Compression)
import Compression
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// tar.gz without spawning `/usr/bin/tar` (GJOB-152).
///
/// Why this exists: `HostedClient.submit` tarred a deck directory and `fetch` untarred the results, both by
/// spawning tar. A sandboxed app cannot spawn arbitrary binaries, so the Mac App Store build lost the whole
/// accelerated flow, and iOS lost deck submission entirely. Everything here is Foundation + the Compression
/// framework, so it works in a sandbox and on the phone.
///
/// Scope is deliberately narrow — this is not a general archiver. It writes and reads the ustar subset the
/// endpoint's decks and results actually use: regular files and directories, no symlinks (the deck rule
/// already forbids them), no hard links, no sparse files, no pax extensions. Anything else in an incoming
/// archive is skipped rather than guessed at, and `unsupportedEntries` reports it so a caller can complain
/// instead of silently producing a partial extraction.
public enum Tar {
    public static let blockSize = 512
    /// GNU/ustar long names need a pax or GNU extension; 100 bytes is the plain-header limit and every path
    /// in a LAMMPS deck is far shorter. A longer one is an error, not a truncation.
    public static let maxNameLength = 100

    public struct TarError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
        init(_ m: String) { message = m }
    }

    // MARK: - writing

    /// tar the contents of `directory` (as `./relative/path` entries, matching what `tar -C dir .` produces),
    /// skipping any path component that matches one of `excluding`.
    public static func archive(directory: URL, excluding: [String] = []) throws -> Data {
        let fm = FileManager.default
        var out = Data()
        let root = directory.standardizedFileURL
        guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                                       options: [.skipsHiddenFiles]) else {
            throw TarError("cannot read \(root.path)")
        }
        // Sorted for a reproducible archive: the same deck must produce the same bytes, or a content hash of
        // an upload means nothing.
        var entries: [URL] = []
        for case let u as URL in walk { entries.append(u) }
        entries.sort { $0.path < $1.path }

        for url in entries {
            let rel = relativePath(of: url, under: root)
            if rel.isEmpty { continue }
            if excluded(rel, patterns: excluding) { continue }
            let vals = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            if vals.isDirectory == true {
                out.append(try header(name: "./" + rel + "/", size: 0, type: "5", url: url))
            } else if vals.isRegularFile == true {
                let data = try Data(contentsOf: url)
                out.append(try header(name: "./" + rel, size: data.count, type: "0", url: url))
                out.append(data)
                let pad = (blockSize - data.count % blockSize) % blockSize
                if pad > 0 { out.append(Data(count: pad)) }
            }
            // anything else (symlink, socket, device) is skipped: decks may not contain them
        }
        out.append(Data(count: blockSize * 2))          // two zero blocks end the archive
        return out
    }

    /// `archive` + gzip, i.e. what `tar -czf` writes.
    public static func archiveGzipped(directory: URL, excluding: [String] = []) throws -> Data {
        try gzip(archive(directory: directory, excluding: excluding))
    }

    static func relativePath(of url: URL, under root: URL) -> String {
        let a = url.standardizedFileURL.pathComponents, b = root.pathComponents
        guard a.count > b.count, Array(a.prefix(b.count)) == b else { return "" }
        return a.dropFirst(b.count).joined(separator: "/")
    }

    /// Exclusion with the same shape as `tar --exclude`: a glob tested against the whole relative path and
    /// against each individual path component, so `results` excludes a directory anywhere and `*.restart*`
    /// excludes `Al.restart.5000` wherever it sits.
    ///
    /// This uses `fnmatch(3)` rather than a hand-rolled matcher on purpose. The first version here only
    /// understood `*.ext` and exact components, which silently failed to match three of
    /// `HostedClient.deckExcludes` -- `*.ckpt*`, `*.restart*` and `results-*` -- and the cost of that bug is
    /// uploading gigabytes of checkpoints the exclude list exists to keep out.
    static func excluded(_ rel: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        let parts = rel.split(separator: "/").map(String.init)
        for p in patterns {
            if fnmatch(p, rel, 0) == 0 { return true }
            for part in parts where fnmatch(p, part, 0) == 0 { return true }
        }
        return false
    }

    static func header(name: String, size: Int, type: String, url: URL?) throws -> Data {
        guard name.utf8.count <= maxNameLength else {
            throw TarError("path too long for a plain tar header (\(name.utf8.count) > \(maxNameLength)): \(name)")
        }
        var h = [UInt8](repeating: 0, count: blockSize)
        func put(_ s: String, at offset: Int, width: Int) {
            for (i, b) in Array(s.utf8).prefix(width).enumerated() { h[offset + i] = b }
        }
        // ustar: name(0,100) mode(100,8) uid(108,8) gid(116,8) size(124,12) mtime(136,12) chksum(148,8)
        //        type(156,1) linkname(157,100) magic(257,6) version(263,2) uname(265,32) gname(297,32)
        put(name, at: 0, width: 100)
        put(String(format: "%07o", type == "5" ? 0o755 : 0o644), at: 100, width: 8)
        put("0000000", at: 108, width: 8)
        put("0000000", at: 116, width: 8)
        put(String(format: "%011o", size), at: 124, width: 12)
        let mtime = (try? url?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .flatMap { $0 } ?? Date()
        put(String(format: "%011o", Int(mtime.timeIntervalSince1970)), at: 136, width: 12)
        put(type, at: 156, width: 1)
        put("ustar", at: 257, width: 6)
        put("00", at: 263, width: 2)
        // checksum is computed with the checksum field read as spaces, then written as 6 octal digits + NUL
        for i in 148..<156 { h[i] = 0x20 }
        let sum = h.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum), at: 148, width: 7)
        h[154] = 0
        h[155] = 0x20
        return Data(h)
    }

    // MARK: - reading

    public struct Entry {
        public let path: String
        public let isDirectory: Bool
        public let data: Data
    }

    /// gunzip if needed, then extract into `destination`. Returns the paths written.
    @discardableResult
    public static func extract(_ archive: Data, to destination: URL) throws -> [String] {
        let raw = isGzip(archive) ? try gunzip(archive) : archive
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var written: [String] = []
        for entry in try entries(of: raw) {
            // Refuse to escape the destination: a `../` in an archive we did not write is the classic
            // path-traversal bug, and the endpoint's tarballs come back over the network.
            let target = destination.appendingPathComponent(entry.path).standardizedFileURL
            guard target.path == destination.standardizedFileURL.path
                    || target.path.hasPrefix(destination.standardizedFileURL.path + "/") else {
                throw TarError("archive entry escapes the destination: \(entry.path)")
            }
            if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try entry.data.write(to: target)
                written.append(entry.path)
            }
        }
        return written
    }

    /// Parse without writing anything. `unsupportedEntries` collects type flags we skipped.
    public static func entries(of raw: Data) throws -> [Entry] {
        var out: [Entry] = []
        var i = raw.startIndex
        while i + blockSize <= raw.endIndex {
            let block = raw[i..<(i + blockSize)]
            if block.allSatisfy({ $0 == 0 }) { break }             // end of archive
            let name = string(block, 0, 100)
            let prefix = string(block, 345, 155)
            let sizeField = string(block, 124, 12)
            guard let size = Int(sizeField.trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8) else {
                throw TarError("bad size field in tar header for \(name.isEmpty ? "<unnamed>" : name)")
            }
            let type = Character(UnicodeScalar(block[block.startIndex + 156]))
            let full = prefix.isEmpty ? name : prefix + "/" + name
            let clean = full.hasPrefix("./") ? String(full.dropFirst(2)) : full
            i += blockSize
            let dataEnd = min(i + size, raw.endIndex)
            let payload = size > 0 ? Data(raw[i..<dataEnd]) : Data()
            i += size + (blockSize - size % blockSize) % blockSize
            switch type {
            case "0", "\0": out.append(Entry(path: clean, isDirectory: false, data: payload))
            case "5":       out.append(Entry(path: clean, isDirectory: true, data: Data()))
            default:        continue                                // link/device/pax: skipped by design
            }
        }
        return out
    }

    static func string(_ b: Data, _ offset: Int, _ len: Int) -> String {
        let start = b.startIndex + offset
        let bytes = b[start..<min(start + len, b.endIndex)].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    // MARK: - gzip (RFC 1952) over Compression's raw DEFLATE

    public static func isGzip(_ d: Data) -> Bool {
        d.count > 2 && d[d.startIndex] == 0x1f && d[d.startIndex + 1] == 0x8b
    }

    public static func gzip(_ body: Data) throws -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff])   // magic, deflate, no flags, mtime 0, OS unknown
        out.append(try deflate(body))
        var crc = crc32(body).littleEndian
        var isize = UInt32(truncatingIfNeeded: body.count).littleEndian
        withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &isize) { out.append(contentsOf: $0) }
        return out
    }

    public static func gunzip(_ d: Data) throws -> Data {
        guard isGzip(d), d.count > 18 else { throw TarError("not a gzip stream") }
        let flags = d[d.startIndex + 3]
        var p = d.startIndex + 10
        if flags & 0x04 != 0 {                                             // FEXTRA
            guard p + 2 <= d.endIndex else { throw TarError("truncated gzip FEXTRA") }
            let n = Int(d[p]) | Int(d[p + 1]) << 8
            p += 2 + n
        }
        if flags & 0x08 != 0 { while p < d.endIndex, d[p] != 0 { p += 1 }; p += 1 }   // FNAME
        if flags & 0x10 != 0 { while p < d.endIndex, d[p] != 0 { p += 1 }; p += 1 }   // FCOMMENT
        if flags & 0x02 != 0 { p += 2 }                                              // FHCRC
        guard p < d.endIndex - 8 else { throw TarError("truncated gzip stream") }
        let body = Data(d[p..<(d.endIndex - 8)])
        let expanded = try inflate(body, hint: expectedSize(d))
        let want = readLE32(d, d.endIndex - 8)
        guard crc32(expanded) == want else { throw TarError("gzip CRC mismatch: the download is corrupt") }
        return expanded
    }

    static func expectedSize(_ d: Data) -> Int {
        // ISIZE is the uncompressed size mod 2^32; a useful starting buffer, not a guarantee.
        Int(readLE32(d, d.endIndex - 4))
    }

    static func readLE32(_ d: Data, _ at: Int) -> UInt32 {
        UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
    }

    static func deflate(_ input: Data) throws -> Data {
        #if canImport(Compression)
        return try transform(input, operation: COMPRESSION_STREAM_ENCODE, capacityHint: max(input.count / 2, 4096))
        #else
        return storedDeflate(input)
        #endif
    }

    static func inflate(_ input: Data, hint: Int) throws -> Data {
        #if canImport(Compression)
        return try transform(input, operation: COMPRESSION_STREAM_DECODE, capacityHint: max(hint, input.count * 4, 4096))
        #else
        return try pureInflate(input, hint: hint)
        #endif
    }

    #if canImport(Compression)
    /// Streamed so a multi-hundred-MB trajectory does not need a single buffer big enough for all of it.
    static func transform(_ input: Data, operation: compression_stream_operation, capacityHint: Int) throws -> Data {
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw TarError("could not start the compression stream")
        }
        defer { compression_stream_destroy(&stream) }
        let chunk = 64 * 1024
        var output = Data(capacity: capacityHint)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }

        return try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = input.count
            let flags = Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, flags)
                let produced = chunk - stream.dst_size
                if produced > 0 { output.append(dst, count: produced) }
                switch status {
                case COMPRESSION_STATUS_OK: continue
                case COMPRESSION_STATUS_END: return output
                default: throw TarError(operation == COMPRESSION_STREAM_ENCODE
                                        ? "compression failed" : "the archive is not valid DEFLATE data")
                }
            }
        }
    }

    #endif  // canImport(Compression)

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1 == 1) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    public static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: - pure-Swift DEFLATE (the off-Apple path, GJOB-190)
    //
    // The Linux CLI has no Compression framework, and dropping zlib in would mean a system dependency and a
    // C target in a package that has neither. These two functions are the whole substitute. They are always
    // compiled, on every platform, so the tests can cross-check them against Apple's implementation on macOS
    // instead of only finding out in CI that they disagree.
    //
    // Asymmetric on purpose:
    //  - inflate is a real RFC 1951 decoder (stored + fixed + dynamic Huffman) because results tarballs come
    //    back gzipped by GNU tar with dynamic Huffman blocks. Nothing less would read them.
    //  - deflate only emits stored blocks (BTYPE=00), i.e. gzip framing around uncompressed bytes. The only
    //    thing this side compresses is a deck directory -- input scripts and a data file, kilobytes to a few
    //    megabytes, already filtered by `deckExcludes` -- and every gunzip reads stored blocks. Trading ~0%
    //    compression on a small upload for not hand-writing a Huffman encoder is the right trade; if decks
    //    ever get big off-Apple, this is the place to add fixed-Huffman encoding.

    /// RFC 1951 stored blocks: 5 bytes of header per 65535-byte chunk, payload verbatim.
    static func storedDeflate(_ input: Data) -> Data {
        let bytes = [UInt8](input)
        var out = Data(capacity: bytes.count + 5 * (bytes.count / 65535 + 1))
        var i = 0
        repeat {                                            // repeat: empty input still needs a final block
            let n = min(65535, bytes.count - i)
            let final: UInt8 = (i + n >= bytes.count) ? 1 : 0
            out.append(final)                               // BFINAL in bit 0, BTYPE=00 in bits 1-2, then
            let len = UInt16(n), nlen = ~len                // the rest of the byte is skipped to the LEN/NLEN
            out.append(UInt8(len & 0xff)); out.append(UInt8(len >> 8))
            out.append(UInt8(nlen & 0xff)); out.append(UInt8(nlen >> 8))
            if n > 0 { out.append(contentsOf: bytes[i..<(i + n)]) }
            i += n
        } while i < bytes.count
        return out
    }

    /// Canonical Huffman table in the count/symbol form from zlib's puff.c: `counts[l]` is how many codes
    /// have length `l`, and `symbols` lists the symbols in code order. Decoding walks one bit at a time,
    /// which needs no lookup table and no maximum-code-length bookkeeping.
    struct Huffman {
        var counts: [Int]
        var symbols: [Int]

        init(lengths: [Int]) {
            counts = [Int](repeating: 0, count: 16)
            for l in lengths where l > 0 { counts[l] += 1 }
            var offsets = [Int](repeating: 0, count: 16)
            for l in 1..<15 { offsets[l + 1] = offsets[l] + counts[l] }
            symbols = [Int](repeating: 0, count: lengths.count)
            for (sym, l) in lengths.enumerated() where l > 0 {
                symbols[offsets[l]] = sym
                offsets[l] += 1
            }
        }
    }

    // RFC 1951 §3.2.5. Index 28 of the length table is the literal 258 with no extra bits.
    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
                             67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
                           1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    /// The order code lengths for the code-length alphabet arrive in (RFC 1951 §3.2.7).
    static let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// Inflate a raw DEFLATE stream (no zlib/gzip wrapper -- `gunzip` has already stripped those).
    static func pureInflate(_ input: Data, hint: Int) throws -> Data {
        let src = [UInt8](input)
        var out = [UInt8]()
        out.reserveCapacity(max(hint, src.count * 4, 4096))
        var bit = 0                                                  // absolute bit offset, LSB-first

        func bits(_ n: Int) throws -> Int {
            var v = 0
            for i in 0..<n {
                let byte = bit >> 3
                guard byte < src.count else { throw TarError("truncated DEFLATE stream") }
                v |= Int((src[byte] >> UInt8(bit & 7)) & 1) << i
                bit += 1
            }
            return v
        }

        func decode(_ h: Huffman) throws -> Int {
            var code = 0, first = 0, index = 0
            for len in 1...15 {
                code |= try bits(1)
                let count = h.counts[len]
                if code - first < count { return h.symbols[index + (code - first)] }
                index += count
                first = (first + count) << 1
                code <<= 1
            }
            throw TarError("invalid Huffman code in DEFLATE stream")
        }

        /// The literal/length + distance loop, shared by fixed and dynamic blocks.
        func block(literals: Huffman, distances: Huffman) throws {
            while true {
                let sym = try decode(literals)
                if sym < 256 {
                    out.append(UInt8(sym))
                } else if sym == 256 {
                    return                                           // end of block
                } else {
                    let li = sym - 257
                    guard li < lengthBase.count else { throw TarError("invalid length code \(sym)") }
                    let length = lengthBase[li] + (try bits(lengthExtra[li]))
                    let di = try decode(distances)
                    guard di < distBase.count else { throw TarError("invalid distance code \(di)") }
                    let dist = distBase[di] + (try bits(distExtra[di]))
                    guard dist <= out.count else { throw TarError("DEFLATE back-reference before the start of the stream") }
                    // Byte-at-a-time so overlapping copies (dist < length, how runs are encoded) work.
                    var from = out.count - dist
                    for _ in 0..<length { out.append(out[from]); from += 1 }
                }
            }
        }

        var fixedLiterals: Huffman { Huffman(lengths: (0..<288).map { $0 < 144 ? 8 : ($0 < 256 ? 9 : ($0 < 280 ? 7 : 8)) }) }
        var fixedDistances: Huffman { Huffman(lengths: [Int](repeating: 5, count: 30)) }

        while true {
            let final = try bits(1)
            switch try bits(2) {
            case 0:                                                  // stored
                bit = (bit + 7) & ~7                                 // LEN starts on a byte boundary
                let p = bit >> 3
                guard p + 4 <= src.count else { throw TarError("truncated stored DEFLATE block") }
                let len = Int(src[p]) | Int(src[p + 1]) << 8
                let nlen = Int(src[p + 2]) | Int(src[p + 3]) << 8
                guard len == (~nlen & 0xffff) else { throw TarError("corrupt stored DEFLATE block (LEN/NLEN mismatch)") }
                guard p + 4 + len <= src.count else { throw TarError("truncated stored DEFLATE block") }
                out.append(contentsOf: src[(p + 4)..<(p + 4 + len)])
                bit = (p + 4 + len) << 3
            case 1:
                try block(literals: fixedLiterals, distances: fixedDistances)
            case 2:
                let hlit = try bits(5) + 257, hdist = try bits(5) + 1, hclen = try bits(4) + 4
                var clen = [Int](repeating: 0, count: 19)
                for i in 0..<hclen { clen[codeLengthOrder[i]] = try bits(3) }
                let clHuff = Huffman(lengths: clen)
                // One run-length-coded list holds both alphabets; 16/17/18 repeats may straddle the split,
                // so decode the whole thing first and cut afterwards.
                var lengths = [Int]()
                lengths.reserveCapacity(hlit + hdist)
                while lengths.count < hlit + hdist {
                    let sym = try decode(clHuff)
                    switch sym {
                    case 0...15: lengths.append(sym)
                    case 16:
                        guard let prev = lengths.last else { throw TarError("DEFLATE repeat code with nothing to repeat") }
                        for _ in 0..<(3 + (try bits(2))) { lengths.append(prev) }
                    case 17: for _ in 0..<(3 + (try bits(3))) { lengths.append(0) }
                    case 18: for _ in 0..<(11 + (try bits(7))) { lengths.append(0) }
                    default: throw TarError("invalid code-length symbol \(sym)")
                    }
                }
                guard lengths.count == hlit + hdist else { throw TarError("DEFLATE code-length run overflows the alphabets") }
                try block(literals: Huffman(lengths: Array(lengths[0..<hlit])),
                          distances: Huffman(lengths: Array(lengths[hlit...])))
            default:
                throw TarError("reserved DEFLATE block type")
            }
            if final == 1 { break }
        }
        return Data(out)
    }
}
