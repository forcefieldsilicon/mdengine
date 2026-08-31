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
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var frames: [[Arv]] = []
        var i = 0

        while i < lines.count {
            guard lines[i].hasPrefix("ITEM: TIMESTEP") else { i += 1; continue }
            i += 2  // skip the timestep value line

            guard i + 1 < lines.count, lines[i].hasPrefix("ITEM: NUMBER OF ATOMS"),
                  let count = Int(lines[i + 1].trimmingCharacters(in: .whitespaces)),
                  count > 0 else { break }
            i += 2

            guard i < lines.count, lines[i].hasPrefix("ITEM: BOX BOUNDS") else { break }
            i += 1
            var lo = [0.0, 0.0, 0.0], hi = [1.0, 1.0, 1.0]
            for d in 0..<3 where i < lines.count {
                let parts = lines[i].split(separator: " ")
                if parts.count >= 2, let a = Double(parts[0]), let b = Double(parts[1]) {
                    lo[d] = a; hi[d] = b
                }
                i += 1
            }

            guard i < lines.count, lines[i].hasPrefix("ITEM: ATOMS") else { break }
            let cols = lines[i].split(separator: " ").dropFirst(2).map(String.init)
            i += 1

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
                  (zDirect ?? zScaled) != nil, i + count <= lines.count else { break }

            var rows: [(id: Int, atom: Arv)] = []
            rows.reserveCapacity(count)
            for r in i..<(i + count) {
                let p = lines[r].split(separator: " ")
                func value(_ k: Int?) -> Double? {
                    guard let k, k < p.count else { return nil }
                    return Double(p[k])
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
                if let e = elementCol, e < p.count {
                    element = String(p[e])
                } else if let t = typeCol, t < p.count {
                    element = String(p[t])
                } else {
                    element = "?"
                }
                let id = value(idCol).map(Int.init) ?? rows.count
                rows.append((id, Arv(element: element, x: x, y: y, z: z, charge: value(chargeCol))))
            }
            rows.sort { $0.id < $1.id }   // dumps are unordered; keep atom identity stable
            frames.append(rows.map(\.atom))
            i += count
        }
        return frames
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
