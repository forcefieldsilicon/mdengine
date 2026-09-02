//
//  LammpsDumpParser.swift — parses native LAMMPS dump files
//  (`dump atom` / `dump custom`: ITEM: TIMESTEP blocks) into [Arv] frames.
//
//  Handles direct (x y z), unwrapped (xu yu zu), and scaled (xs ys zs)
//  coordinates — scaled positions are mapped through the frame's box bounds.
//  Element names come from an `element` column when the deck used
//  `dump_modify ... element ...`; otherwise the numeric atom type is used as
//  the element token. Triclinic tilt factors are ignored (orthogonal mapping).
//

import Foundation

public enum LammpsDumpParser {
    public static func parseFrames(_ text: String) -> [[Arv]] {
        // Byte-level parse: Substring-based parsing shares one atomic refcount
        // across every token, which serializes multicore parsing (measured:
        // parallel Substrings were SLOWER than sequential). Raw UTF-8 + strtod
        // keeps the hot loop ARC-free and parallelizes cleanly.
        var bytes = Array(text.utf8)
        bytes.append(0)   // strtod safety: NUL-terminate the buffer
        return bytes.withUnsafeBufferPointer { buf in
            parseBytes(buf.baseAddress!, buf.count - 1)
        }
    }

    /// Zero-copy-ish entry point: parse straight from file bytes — skips the
    /// Data → String UTF-8 validation pass a 500 MB dump doesn't need.
    public static func parseFrames(data: Data) -> [[Arv]] {
        var bytes = [UInt8](data)
        bytes.append(0)   // strtod safety
        return bytes.withUnsafeBufferPointer { buf in
            parseBytes(buf.baseAddress!, buf.count - 1)
        }
    }

    private static let timestepPrefix = Array("ITEM: TIMESTEP".utf8)

    private static func parseBytes(_ bytes: UnsafePointer<UInt8>, _ length: Int) -> [[Arv]] {
        // Frame starts: one linear scan over line starts.
        var starts: [Int] = []
        var pos = 0
        while pos < length {
            if length - pos >= timestepPrefix.count,
               memcmp(bytes + pos, timestepPrefix, timestepPrefix.count) == 0 {
                starts.append(pos)
            }
            guard let nl = memchr(bytes + pos, 0x0A, length - pos) else { break }
            pos = UnsafeRawPointer(nl).assumingMemoryBound(to: UInt8.self) - bytes + 1
        }
        guard !starts.isEmpty else { return [] }

        // Parse every frame on its own core; disjoint writes via the holder.
        var results = [[Arv]?](repeating: nil, count: starts.count)
        results.withUnsafeMutableBufferPointer { buffer in
            let holder = FrameResultBuffer(buffer)
            DispatchQueue.concurrentPerform(iterations: starts.count) { k in
                let limit = k + 1 < starts.count ? starts[k + 1] : length
                holder.buffer[k] = parseFrame(bytes, from: starts[k], limit: limit)
            }
        }
        // A malformed or truncated frame (an in-flight dump's final block)
        // parses to nil and is dropped; complete frames are unaffected.
        return results.compactMap { $0 }
    }

    /// Sendable wrapper: concurrentPerform writes to disjoint indices only.
    private final class FrameResultBuffer: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<[Arv]?>
        init(_ buffer: UnsafeMutableBufferPointer<[Arv]?>) { self.buffer = buffer }
    }

    /// Parse one ITEM: TIMESTEP block. nil = malformed/incomplete.
    private static func parseFrame(_ bytes: UnsafePointer<UInt8>, from start: Int,
                                   limit: Int) -> [Arv]? {
        var pos = start

        func nextLine() -> (s: Int, e: Int)? {
            guard pos < limit else { return nil }
            let s = pos
            let remaining = limit - pos
            if let nl = memchr(bytes + pos, 0x0A, remaining) {
                let e = UnsafeRawPointer(nl).assumingMemoryBound(to: UInt8.self) - bytes
                pos = e + 1
                return (s, e)
            }
            pos = limit
            return (s, limit)
        }
        func hasPrefix(_ line: (s: Int, e: Int), _ p: String) -> Bool {
            let u = Array(p.utf8)
            return line.e - line.s >= u.count && memcmp(bytes + line.s, u, u.count) == 0
        }
        func double(at offset: Int) -> Double {
            strtod(UnsafeRawPointer(bytes + offset).assumingMemoryBound(to: CChar.self), nil)
        }

        guard let tsHeader = nextLine(), hasPrefix(tsHeader, "ITEM: TIMESTEP"),
              nextLine() != nil,
              let nHeader = nextLine(), hasPrefix(nHeader, "ITEM: NUMBER OF ATOMS"),
              let nLine = nextLine() else { return nil }
        let count = Int(double(at: nLine.s))
        guard count > 0 else { return nil }

        guard let boxHeader = nextLine(), hasPrefix(boxHeader, "ITEM: BOX BOUNDS") else { return nil }
        var lo = [0.0, 0.0, 0.0], hi = [1.0, 1.0, 1.0]
        for d in 0..<3 {
            guard let line = nextLine() else { return nil }
            var end: UnsafeMutablePointer<CChar>?
            let a = strtod(UnsafeRawPointer(bytes + line.s).assumingMemoryBound(to: CChar.self), &end)
            if let end { lo[d] = a; hi[d] = strtod(end, nil) }
        }

        guard let atomsHeader = nextLine(), hasPrefix(atomsHeader, "ITEM: ATOMS") else { return nil }
        let headerText = String(decoding: UnsafeBufferPointer(
            start: bytes + atomsHeader.s, count: atomsHeader.e - atomsHeader.s), as: UTF8.self)
        let cols = headerText.split(separator: " ").dropFirst(2).map(String.init)

        func col(_ names: [String]) -> Int? {
            for n in names { if let k = cols.firstIndex(of: n) { return k } }
            return nil
        }
        let xDirect = col(["x", "xu"]), xScaled = col(["xs", "xsu"])
        let yDirect = col(["y", "yu"]), yScaled = col(["ys", "ysu"])
        let zDirect = col(["z", "zu"]), zScaled = col(["zs", "zsu"])
        let idCol = cols.firstIndex(of: "id")
        let elementCol = cols.firstIndex(of: "element")
        let typeCol = cols.firstIndex(of: "type")
        let chargeCol = col(["q", "charge"])
        guard (xDirect ?? xScaled) != nil, (yDirect ?? yScaled) != nil,
              (zDirect ?? zScaled) != nil else { return nil }

        var rows: [(id: Int, atom: Arv)] = []
        rows.reserveCapacity(count)
        var tokenStart = [Int](repeating: -1, count: cols.count)
        var tokenEnd = [Int](repeating: -1, count: cols.count)

        for _ in 0..<count {
            guard let line = nextLine() else { return nil }   // truncated frame
            // Tokenize the row: spaces/tabs separate up to cols.count fields.
            var t = line.s
            var field = 0
            while t < line.e, field < cols.count {
                while t < line.e, bytes[t] == 0x20 || bytes[t] == 0x09 { t += 1 }
                guard t < line.e else { break }
                tokenStart[field] = t
                while t < line.e, bytes[t] != 0x20, bytes[t] != 0x09 { t += 1 }
                tokenEnd[field] = t
                field += 1
            }
            func value(_ k: Int?) -> Double? {
                guard let k, k < field, tokenStart[k] >= 0 else { return nil }
                return double(at: tokenStart[k])
            }
            func coord(direct: Int?, scaled: Int?, axis: Int) -> Double? {
                if let v = value(direct) { return v }
                if let s = value(scaled) { return lo[axis] + s * (hi[axis] - lo[axis]) }
                return nil
            }
            guard let x = coord(direct: xDirect, scaled: xScaled, axis: 0),
                  let y = coord(direct: yDirect, scaled: yScaled, axis: 1),
                  let z = coord(direct: zDirect, scaled: zScaled, axis: 2),
                  x.isFinite, y.isFinite, z.isFinite else { continue }  // drop corrupt/NaN rows
            let element: String
            if let e = elementCol, e < field {
                element = String(decoding: UnsafeBufferPointer(
                    start: bytes + tokenStart[e], count: tokenEnd[e] - tokenStart[e]), as: UTF8.self)
            } else if let tc = typeCol, tc < field {
                element = String(decoding: UnsafeBufferPointer(
                    start: bytes + tokenStart[tc], count: tokenEnd[tc] - tokenStart[tc]), as: UTF8.self)
            } else {
                element = "?"
            }
            let id = value(idCol).map(Int.init) ?? rows.count
            rows.append((id, Arv(element: element, x: x, y: y, z: z, charge: value(chargeCol))))
        }
        rows.sort { $0.id < $1.id }   // dumps are unordered; keep atom identity stable
        return rows.map(\.atom)
    }
}

/// Front door for trajectory files: sniffs the format and dispatches to the
/// native-dump or XYZ parser.
public enum TrajectoryReader {
    public static func parseFrames(_ text: String) -> [[Arv]] {
        if isNativeDump(text) {
            return LammpsDumpParser.parseFrames(text)
        }
        return XYZParser.parseFrames(text)
    }

    /// Preferred for files: reads bytes once and — for native dumps — parses
    /// them directly, skipping the String round-trip (validation + a copy).
    /// XYZ falls back to text parsing (those files are typically small).
    public static func parseFrames(contentsOf url: URL) throws -> [[Arv]] {
        let data = try Data(contentsOf: url)
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        if head.contains("ITEM: TIMESTEP") {
            return LammpsDumpParser.parseFrames(data: data)
        }
        return XYZParser.parseFrames(String(decoding: data, as: UTF8.self))
    }

    public static func isNativeDump(_ text: String) -> Bool {
        text.prefix(2048).contains("ITEM: TIMESTEP")
    }

    /// Column names of a native dump's per-atom section (first frame's
    /// `ITEM: ATOMS ...` header); nil for XYZ input.
    public static func dumpFields(_ text: String) -> [String]? {
        guard isNativeDump(text) else { return nil }
        for line in text.split(separator: "\n").prefix(64) where line.hasPrefix("ITEM: ATOMS") {
            return line.split(separator: " ").dropFirst(2).map(String.init)
        }
        return nil
    }
}

/// Writes frames back out as XYZ / extended-XYZ.
public enum TrajectoryWriter {
    /// Plain XYZ, or — with `charges: true` — extended-XYZ whose comment line
    /// declares `Properties=species:S:1:pos:R:3:charge:R:1` and whose rows
    /// carry the per-atom charge as a fifth column (0 when unknown).
    public static func xyz(_ frames: [[Arv]], comment: String, charges: Bool = false) -> String {
        var out = ""
        for frame in frames {
            out += "\(frame.count)\n"
            out += charges ? "Properties=species:S:1:pos:R:3:charge:R:1 \(comment)\n" : "\(comment)\n"
            for a in frame {
                out += charges
                    ? "\(a.element) \(a.x) \(a.y) \(a.z) \(a.charge ?? 0)\n"
                    : "\(a.element) \(a.x) \(a.y) \(a.z)\n"
            }
        }
        return out
    }
}
