//
//  XYZParser.swift
//  LAMMPSCore
//
//  Parses (multi-frame) XYZ / extended-XYZ trajectories into [Arv].
//

import Foundation

public enum XYZParser {
    /// Parse a possibly multi-frame XYZ trajectory and return the atoms of the
    /// LAST complete frame (the final state of the run).
    ///
    /// Format per frame:
    ///   line 1: atom count (integer)
    ///   line 2: comment (ignored — may be an extended-XYZ `Lattice=...` header)
    ///   next N lines: `<element> <x> <y> <z> [extra columns ignored]`
    public static func parseLastFrame(_ text: String) -> [Arv] {
        let frames = parseFrames(text)
        return frames.last ?? []
    }

    /// Parse and return the first complete frame.
    public static func parseFirstFrame(_ text: String) -> [Arv] {
        return parseFrames(text, stopAfterFirst: true).first ?? []
    }

    /// Parse every complete frame in the trajectory.
    public static func parseFrames(_ text: String, stopAfterFirst: Bool = false) -> [[Arv]] {
        parseTrajectory(text, stopAfterFirst: stopAfterFirst).map(\.atoms)
    }

    /// Full parse: adds the extended-XYZ cell (`Lattice="…"`, `pbc="T T T"`)
    /// and the columns declared by `Properties=species:S:1:pos:R:3:…` —
    /// numeric ones as Frame.columns, string ones as Frame.labels.
    ///
    /// `Arv` itself is untouched by the extra columns (charge included) so that
    /// `parseFrames` keeps returning exactly what it always did.
    public static func parseTrajectory(_ text: String, stopAfterFirst: Bool = false) -> Trajectory {
        // `\r\n` is ONE Swift Character, so splitting on "\n" does not split a
        // CRLF file at all (whole file = one line → zero frames). isNewline
        // matches "\n", "\r\n" and a lone "\r".
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var frames: Trajectory = []
        var i = 0

        while i < lines.count {
            // Locate the next atom-count line (an integer on its own).
            let countToken = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let count = Int(countToken), count > 0 else {
                i += 1
                continue
            }

            let atomsStart = i + 2 // skip count line + comment line
            guard atomsStart + count <= lines.count else { break } // truncated frame

            let comment = String(lines[i + 1])
            let box = extendedBox(comment)
            let extras = extendedColumns(comment)   // (name, isNumeric, token index)

            var frame: [Arv] = []
            frame.reserveCapacity(count)
            var columns = [String: [Float]](minimumCapacity: extras.count)
            var labels = [String: [String]]()
            for e in extras where e.numeric { columns[e.name] = [] }
            for e in extras where !e.numeric { labels[e.name] = [] }

            for j in atomsStart..<(atomsStart + count) {
                let parts = lines[j].split(whereSeparator: \.isWhitespace)
                guard parts.count >= 4,
                      let x = Double(parts[1]),
                      let y = Double(parts[2]),
                      let z = Double(parts[3]),
                      x.isFinite, y.isFinite, z.isFinite else { continue }
                frame.append(Arv(element: String(parts[0]), x: x, y: y, z: z))
                for e in extras {
                    let token = e.column < parts.count ? String(parts[e.column]) : ""
                    if e.numeric {
                        columns[e.name]?.append(Float(token) ?? .nan)
                    } else {
                        labels[e.name]?.append(token)
                    }
                }
            }

            frames.append(Frame(atoms: frame, box: box, columns: columns, labels: labels))
            if stopAfterFirst { break }
            i = atomsStart + count
        }

        return frames
    }

    // MARK: - Extended-XYZ comment line

    /// `key="v v v"` or `key=v` from an extended-XYZ comment line.
    private static func headerValue(_ comment: String, _ key: String) -> String? {
        guard let r = comment.range(of: key + "=", options: .caseInsensitive) else { return nil }
        let rest = comment[r.upperBound...]
        if rest.first == "\"" {
            let body = rest.dropFirst()
            guard let end = body.firstIndex(of: "\"") else { return nil }
            return String(body[..<end])
        }
        return String(rest.prefix { !$0.isWhitespace })
    }

    /// `Lattice="ax ay az bx by bz cx cy cz"` → a box with the origin at 0.
    /// Only the diagonal defines the extent; off-diagonal terms are kept as
    /// tilt (see SimulationBox: minimum image is orthogonal-only for now).
    static func extendedBox(_ comment: String) -> SimulationBox? {
        guard let lattice = headerValue(comment, "Lattice") else { return nil }
        let v = lattice.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
        guard v.count >= 9 else { return nil }
        let pbc = headerValue(comment, "pbc")?.split(whereSeparator: \.isWhitespace).map {
            $0.lowercased().hasPrefix("t")
        } ?? [true, true, true]
        func flag(_ i: Int) -> Bool { i < pbc.count ? pbc[i] : true }
        let tilt = SIMD3(v[3], v[6], v[7])   // xy, xz, yz
        return SimulationBox(lo: SIMD3(0, 0, 0), hi: SIMD3(v[0], v[4], v[8]),
                             periodicX: flag(0), periodicY: flag(1), periodicZ: flag(2),
                             tilt: (tilt.x == 0 && tilt.y == 0 && tilt.z == 0) ? nil : tilt)
    }

    /// `Properties=species:S:1:pos:R:3:charge:R:1:resname:S:1` → the per-atom
    /// columns beyond species+pos, with the token index each occupies.
    /// A multi-component property becomes `name_x/_y/_z` (or `name_0…`).
    static func extendedColumns(_ comment: String) -> [(name: String, numeric: Bool, column: Int)] {
        guard let spec = headerValue(comment, "Properties") else { return [] }
        let fields = spec.split(separator: ":").map(String.init)
        var out: [(name: String, numeric: Bool, column: Int)] = []
        var column = 0
        var f = 0
        while f + 2 < fields.count {
            let name = fields[f]
            let type = fields[f + 1].uppercased()
            guard let n = Int(fields[f + 2]), n > 0 else { break }
            f += 3
            let numeric = (type == "R" || type == "I")
            let isPosition = (name == "pos" || name == "species")
            for k in 0..<n {
                if !isPosition {
                    let suffix = n == 1 ? "" : (n == 3 ? ["_x", "_y", "_z"][k] : "_\(k)")
                    out.append((name + suffix, numeric, column))
                }
                column += 1
            }
        }
        return out
    }
}
