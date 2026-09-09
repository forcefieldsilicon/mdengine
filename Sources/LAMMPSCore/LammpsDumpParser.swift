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
        parseTrajectory(text).map(\.atoms)
    }

    /// Zero-copy-ish entry point: parse straight from file bytes — skips the
    /// Data → String UTF-8 validation pass a 500 MB dump doesn't need.
    public static func parseFrames(data: Data) -> [[Arv]] {
        parseTrajectory(data: data).map(\.atoms)
    }

    /// Full parse: atoms plus box bounds, timestep and every extra per-atom
    /// column (`q`, `c_*`, `v_*`, velocities, forces …) as Float32 columns.
    public static func parseTrajectory(_ text: String) -> Trajectory {
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

    public static func parseTrajectory(data: Data) -> Trajectory {
        var bytes = [UInt8](data)
        bytes.append(0)   // strtod safety
        return bytes.withUnsafeBufferPointer { buf in
            parseBytes(buf.baseAddress!, buf.count - 1)
        }
    }

    private static let timestepPrefix = Array("ITEM: TIMESTEP".utf8)

    private static func parseBytes(_ bytes: UnsafePointer<UInt8>, _ length: Int) -> Trajectory {
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
        var results = [Frame?](repeating: nil, count: starts.count)
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
        let buffer: UnsafeMutableBufferPointer<Frame?>
        init(_ buffer: UnsafeMutableBufferPointer<Frame?>) { self.buffer = buffer }
    }

    /// Parse one ITEM: TIMESTEP block. nil = malformed/incomplete.
    private static func parseFrame(_ bytes: UnsafePointer<UInt8>, from start: Int,
                                   limit: Int) -> Frame? {
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
        func isSep(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0D }
        func double(at offset: Int) -> Double {
            strtod(UnsafeRawPointer(bytes + offset).assumingMemoryBound(to: CChar.self), nil)
        }

        func text(_ line: (s: Int, e: Int)) -> String {
            String(decoding: UnsafeBufferPointer(start: bytes + line.s, count: line.e - line.s),
                   as: UTF8.self)
        }

        guard let tsHeader = nextLine(), hasPrefix(tsHeader, "ITEM: TIMESTEP"),
              let tsLine = nextLine(),
              let nHeader = nextLine(), hasPrefix(nHeader, "ITEM: NUMBER OF ATOMS"),
              let nLine = nextLine() else { return nil }
        let timestep = Int(double(at: tsLine.s))
        let count = Int(double(at: nLine.s))
        guard count > 0 else { return nil }

        guard let boxHeader = nextLine(), hasPrefix(boxHeader, "ITEM: BOX BOUNDS") else { return nil }
        // "ITEM: BOX BOUNDS [xy xz yz] pp pp pp" — flags say which axes wrap;
        // the xy/xz/yz form adds a third number per bounds line (tilt).
        let boxTokens = text(boxHeader).split(whereSeparator: \.isWhitespace).dropFirst(3).map(String.init)
        let triclinic = boxTokens.prefix(3) == ["xy", "xz", "yz"]
        let flags = triclinic ? Array(boxTokens.dropFirst(3)) : boxTokens
        var lo = [0.0, 0.0, 0.0], hi = [1.0, 1.0, 1.0], tilt = [0.0, 0.0, 0.0]
        for d in 0..<3 {
            guard let line = nextLine() else { return nil }
            var end: UnsafeMutablePointer<CChar>?
            let a = strtod(UnsafeRawPointer(bytes + line.s).assumingMemoryBound(to: CChar.self), &end)
            if let end {
                lo[d] = a
                var end2: UnsafeMutablePointer<CChar>?
                hi[d] = strtod(end, &end2)
                if triclinic, let end2 { tilt[d] = strtod(end2, nil) }
            }
        }
        func periodic(_ d: Int) -> Bool { d < flags.count ? flags[d].hasPrefix("p") : true }
        let box = SimulationBox(lo: SIMD3(lo[0], lo[1], lo[2]), hi: SIMD3(hi[0], hi[1], hi[2]),
                                periodicX: periodic(0), periodicY: periodic(1), periodicZ: periodic(2),
                                tilt: triclinic ? SIMD3(tilt[0], tilt[1], tilt[2]) : nil)

        guard let atomsHeader = nextLine(), hasPrefix(atomsHeader, "ITEM: ATOMS") else { return nil }
        let headerText = text(atomsHeader)
        // Split on any whitespace: a CRLF dump leaves "\r" glued to the LAST
        // column name ("z\r"), the column lookup below then misses, and the
        // whole frame is discarded as malformed.
        let cols = headerText.split(whereSeparator: \.isWhitespace).dropFirst(2).map(String.init)

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

        // Every column that is not a coordinate/element/type/id becomes a
        // Float32 per-atom column on the Frame (q, c_*, v_*, vx…, fx…).
        let consumed = Set([xDirect, xScaled, yDirect, yScaled, zDirect, zScaled,
                            elementCol, typeCol, idCol].compactMap { $0 })
        let extraCols = cols.indices.filter { !consumed.contains($0) }
        var extraValues = [[Float]](repeating: [], count: extraCols.count)
        for k in extraValues.indices { extraValues[k].reserveCapacity(count) }

        var ids: [Int] = []
        var atoms: [Arv] = []
        ids.reserveCapacity(count)
        atoms.reserveCapacity(count)
        var tokenStart = [Int](repeating: -1, count: cols.count)
        var tokenEnd = [Int](repeating: -1, count: cols.count)

        for _ in 0..<count {
            guard let line = nextLine() else { return nil }   // truncated frame
            // Tokenize the row: spaces/tabs/CR separate up to cols.count fields.
            // CR counts because a CRLF row's last byte is 0x0D inside the line
            // range — otherwise it lands inside the final token ("Fe\r").
            var t = line.s
            var field = 0
            while t < line.e, field < cols.count {
                while t < line.e, isSep(bytes[t]) { t += 1 }
                guard t < line.e else { break }
                tokenStart[field] = t
                while t < line.e, !isSep(bytes[t]) { t += 1 }
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
            let atomID = value(idCol).map(Int.init)
            ids.append(atomID ?? atoms.count)
            atoms.append(Arv(element: element, x: x, y: y, z: z,
                             charge: value(chargeCol), id: atomID))
            for (k, c) in extraCols.enumerated() {
                extraValues[k].append(Float(value(c) ?? .nan))
            }
        }

        // Dumps are unordered; keep atom identity stable — and reorder the
        // extra columns with the same permutation so they stay parallel.
        let order = atoms.indices.sorted { ids[$0] == ids[$1] ? $0 < $1 : ids[$0] < ids[$1] }
        var columns: [String: [Float]] = [:]
        for (k, c) in extraCols.enumerated() {
            columns[cols[c]] = order.map { extraValues[k][$0] }
        }
        return Frame(atoms: order.map { atoms[$0] }, box: box, timestep: timestep, columns: columns)
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

    /// Full parse (atoms + box + timestep + per-atom columns).
    public static func parseTrajectory(_ text: String) -> Trajectory {
        isNativeDump(text) ? LammpsDumpParser.parseTrajectory(text) : XYZParser.parseTrajectory(text)
    }

    public static func parseTrajectory(contentsOf url: URL) throws -> Trajectory {
        let data = try Data(contentsOf: url)
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        if head.contains("ITEM: TIMESTEP") {
            return LammpsDumpParser.parseTrajectory(data: data)
        }
        return XYZParser.parseTrajectory(String(decoding: data, as: UTF8.self))
    }

    public static func isNativeDump(_ text: String) -> Bool {
        text.prefix(2048).contains("ITEM: TIMESTEP")
    }

    /// Column names of a native dump's per-atom section (first frame's
    /// `ITEM: ATOMS ...` header); nil for XYZ input.
    public static func dumpFields(_ text: String) -> [String]? {
        guard isNativeDump(text) else { return nil }
        for line in text.split(whereSeparator: \.isNewline).prefix(64) where line.hasPrefix("ITEM: ATOMS") {
            return line.split(whereSeparator: \.isWhitespace).dropFirst(2).map(String.init)
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
