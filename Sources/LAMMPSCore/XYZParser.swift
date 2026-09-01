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
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var frames: [[Arv]] = []
        var i = 0

        while i < lines.count {
            // Locate the next atom-count line (an integer on its own).
            let countToken = lines[i].trimmingCharacters(in: .whitespaces)
            guard let count = Int(countToken), count > 0 else {
                i += 1
                continue
            }

            let atomsStart = i + 2 // skip count line + comment line
            guard atomsStart + count <= lines.count else { break } // truncated frame

            var frame: [Arv] = []
            frame.reserveCapacity(count)
            for j in atomsStart..<(atomsStart + count) {
                let parts = lines[j].split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard parts.count >= 4,
                      let x = Double(parts[1]),
                      let y = Double(parts[2]),
                      let z = Double(parts[3]),
                      x.isFinite, y.isFinite, z.isFinite else { continue }
                frame.append(Arv(element: String(parts[0]), x: x, y: y, z: z))
            }

            frames.append(frame)
            if stopAfterFirst { break }
            i = atomsStart + count
        }

        return frames
    }
}
