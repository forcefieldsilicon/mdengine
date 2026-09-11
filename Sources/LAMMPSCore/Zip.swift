//
//  Zip.swift — a minimal ZIP writer (PKZIP appnote 4.4.x, methods 0/8) in Foundation + Compression.
//
//  Why: the .xlsx exporter used to shell out to /usr/bin/zip. Process is unavailable in an App
//  Store sandbox and on iOS, and it was the last spawned process in LAMMPSCore. An .xlsx is an
//  ordinary zip container, so this is the same shape as `Tar.swift` (GJOB-152): local headers,
//  a central directory, CRC-32, raw DEFLATE from the Compression framework.
//
//  Scope: write-only, no zip64 (fine below 4 GB / 65 535 entries), no encryption, UTF-8 names.
//  Readers verified: /usr/bin/unzip, Numbers, Excel (see ZipTests).
//

import Foundation

public enum Zip {

    public struct Entry {
        public let path: String          // forward slashes, no leading "/"
        public let data: Data
        public let deflate: Bool         // false = stored (method 0); true = method 8
        public init(path: String, data: Data, deflate: Bool = true) {
            self.path = path
            self.data = data
            self.deflate = deflate
        }
        /// Convenience for text parts (XML, CSV): UTF-8, deflated.
        public init(path: String, text: String) {
            self.init(path: path, data: Data(text.utf8), deflate: true)
        }
    }

    public struct ZipError: Error, LocalizedError {
        public let message: String
        public init(_ m: String) { message = m }
        public var errorDescription: String? { message }
    }

    /// Build the whole archive in memory. Entries are written in order; put
    /// `[Content_Types].xml` first for Office files (readers expect it early).
    public static func archive(_ entries: [Entry], date: Date = Date()) throws -> Data {
        guard entries.count < 0xFFFF else { throw ZipError("too many entries for a zip without zip64") }
        let (dosTime, dosDate) = dosDateTime(date)
        var out = Data()
        var central = Data()

        for e in entries {
            let name = Data(e.path.utf8)
            guard name.count < 0xFFFF else { throw ZipError("entry name too long: \(e.path)") }
            let crc = Tar.crc32(e.data)
            var method: UInt16 = 0
            var payload = e.data
            if e.deflate, !e.data.isEmpty {
                let d = try Tar.deflate(e.data)
                if d.count < e.data.count { method = 8; payload = d }    // store when deflate does not help
            }
            guard payload.count < 0xFFFF_FFFF, e.data.count < 0xFFFF_FFFF else {
                throw ZipError("entry too large for a zip without zip64: \(e.path)")
            }
            let offset = UInt32(out.count)

            // Local file header
            out.le32(0x0403_4b50)
            out.le16(20)                      // version needed: 2.0 (deflate)
            out.le16(0x0800)                  // general purpose flags: bit 11 = UTF-8 names
            out.le16(method)
            out.le16(dosTime); out.le16(dosDate)
            out.le32(crc)
            out.le32(UInt32(payload.count))
            out.le32(UInt32(e.data.count))
            out.le16(UInt16(name.count))
            out.le16(0)                       // extra length
            out.append(name)
            out.append(payload)

            // Central directory entry
            central.le32(0x0201_4b50)
            central.le16(0x0314)              // version made by: 2.0, host = Unix (3)
            central.le16(20)
            central.le16(0x0800)
            central.le16(method)
            central.le16(dosTime); central.le16(dosDate)
            central.le32(crc)
            central.le32(UInt32(payload.count))
            central.le32(UInt32(e.data.count))
            central.le16(UInt16(name.count))
            central.le16(0)                   // extra
            central.le16(0)                   // comment
            central.le16(0)                   // disk number start
            central.le16(0)                   // internal attributes
            central.le32(0o100644 << 16)      // external attributes: -rw-r--r--
            central.le32(offset)
            central.append(name)
        }

        let cdOffset = UInt32(out.count)
        out.append(central)
        // End of central directory
        out.le32(0x0605_4b50)
        out.le16(0); out.le16(0)              // this disk, disk with CD
        out.le16(UInt16(entries.count)); out.le16(UInt16(entries.count))
        out.le32(UInt32(central.count))
        out.le32(cdOffset)
        out.le16(0)                           // comment length
        return out
    }

    /// Write straight to a file (atomically: temp file + replace).
    public static func write(_ entries: [Entry], to url: URL, date: Date = Date()) throws {
        try archive(entries, date: date).write(to: url, options: .atomic)
    }

    /// Names of the entries in a zip we wrote (or any plain zip): walks the central directory.
    /// Used by tests and by callers that want to sanity-check a container without a full reader.
    public static func entryNames(_ zip: Data) throws -> [String] {
        guard zip.count >= 22 else { throw ZipError("not a zip: too short") }
        // Find the end-of-central-directory record (no comment → it is the last 22 bytes).
        var eocd = zip.count - 22
        while eocd >= 0, Tar.readLE32(zip, eocd) != 0x0605_4b50 { eocd -= 1 }
        guard eocd >= 0 else { throw ZipError("not a zip: no end-of-central-directory record") }
        func le16(_ at: Int) -> Int { Int(zip[at]) + Int(zip[at + 1]) * 256 }
        let count = le16(eocd + 10)
        var p = Int(Tar.readLE32(zip, eocd + 16))
        var names: [String] = []
        for _ in 0..<count {
            guard p + 46 <= zip.count, Tar.readLE32(zip, p) == 0x0201_4b50 else { throw ZipError("corrupt central directory") }
            let nameLen = le16(p + 28)
            let extraLen = le16(p + 30)
            let commentLen = le16(p + 32)
            let nameStart = p + 46
            names.append(String(decoding: zip[nameStart..<(nameStart + nameLen)], as: UTF8.self))
            p = nameStart + nameLen + extraLen + commentLen
        }
        return names
    }

    // MARK: - helpers

    /// MS-DOS time/date fields (2-second resolution, 1980 epoch) as the zip format wants them.
    static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        // Every intermediate is spelled Int on purpose: as one packed expression the constraint solver has
        // to consider every integer overload of <<, | and / at once, and times out outright on Linux
        // (GJOB-190). Same arithmetic, one type per line.
        let year: Int = max(1980, min(2107, c.year ?? 1980))
        let hour: Int = c.hour ?? 0, minute: Int = c.minute ?? 0, second: Int = c.second ?? 0
        let month: Int = c.month ?? 1, day: Int = c.day ?? 1
        let t: Int = (hour << 11) | (minute << 5) | (second / 2)
        let d: Int = ((year - 1980) << 9) | (month << 5) | day
        return (UInt16(t), UInt16(d))
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
}
