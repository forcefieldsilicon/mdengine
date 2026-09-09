//
//  SecondaryStructure.swift — DSSP (Kabsch & Sander 1983) from coordinates.
//
//  Secondary structure is not a coordinate you can read off a dump: it is the
//  backbone hydrogen-bond pattern. DSSP defines the bond electrostatically
//  (0.084·332·(1/r_ON + 1/r_CH − 1/r_OH − 1/r_CN) < −0.5 kcal/mol) with the
//  amide H reconstructed from the preceding peptide, then reads helices off
//  consecutive n-turns and sheets off bridges. Everything here needs is the
//  backbone N/CA/C/O and residue identity, which an extended XYZ carries in its
//  `name`/`resid`/`chain` columns — no `name` column means no DSSP, and the
//  caller says so rather than guessing.
//

import Foundation

public struct SecondaryStructure {
    /// One DSSP letter per residue: H G I (helix), E B (sheet), T S (turn,
    /// bend), "-" (coil).
    public let letters: [Character]
    /// "A:12" style residue labels, parallel to `letters`.
    public let residueLabels: [String]
    /// Class per atom of the frame: 0 coil · 1 helix · 2 strand · 3 turn/bend.
    public let perAtomClass: [Float]
    public var residueCount: Int { letters.count }

    /// Fraction of residues carrying any of `set`, over `range` (default all).
    public func fraction(_ set: Set<Character>, in range: Range<Int>? = nil) -> Double {
        let r = range ?? 0..<letters.count
        guard !r.isEmpty, r.lowerBound >= 0, r.upperBound <= letters.count else { return 0 }
        return Double(r.filter { set.contains(letters[$0]) }.count) / Double(r.count)
    }

    public static let helixLetters: Set<Character> = ["H", "G", "I"]
    public static let strandLetters: Set<Character> = ["E", "B"]
    public static let turnLetters: Set<Character> = ["T", "S"]

    /// Class index (matching `perAtomClass`) for a DSSP letter.
    public static func classIndex(_ letter: Character) -> Float {
        if helixLetters.contains(letter) { return 1 }
        if strandLetters.contains(letter) { return 2 }
        if turnLetters.contains(letter) { return 3 }
        return 0
    }
}

public enum DSSP {
    private struct Residue {
        var chain = ""
        var resid = 0
        var resname = ""
        var n: SIMD3<Double>?
        var ca: SIMD3<Double>?
        var c: SIMD3<Double>?
        var o: SIMD3<Double>?
        var h: SIMD3<Double>?
        var atoms: [Int] = []
        var label: String { "\(chain.isEmpty ? "-" : chain):\(resid)" }
    }

    /// nil when the frame carries no `name` column — DSSP cannot be guessed
    /// from elements alone (a C is not a Cα).
    public static func analyze(frame: Frame) -> SecondaryStructure? {
        guard let names = frame.label("name") else { return nil }
        let chains = frame.label("chain"), resids = frame.label("resid"), resnames = frame.label("resname")

        // --- residues, in file order --------------------------------------
        var residues: [Residue] = []
        var keyOfCurrent: String? = nil
        for i in 0..<frame.count {
            let name = names[i].trimmingCharacters(in: .whitespaces).uppercased()
            let chain = chains?[i].trimmingCharacters(in: .whitespaces) ?? ""
            let ridText = resids?[i].trimmingCharacters(in: .whitespaces)
            let key = ridText.map { "\(chain)|\($0)" }
            let startsNew: Bool
            if let key { startsNew = key != keyOfCurrent }
            else { startsNew = residues.isEmpty || (name == "N" && residues[residues.count - 1].n != nil) }
            if startsNew {
                var r = Residue()
                r.chain = chain
                r.resid = ridText.flatMap { Int($0) } ?? (residues.count + 1)
                r.resname = resnames?[i].trimmingCharacters(in: .whitespaces).uppercased() ?? ""
                residues.append(r)
                keyOfCurrent = key
            }
            let p = SIMD3(frame.atoms[i].x, frame.atoms[i].y, frame.atoms[i].z)
            var r = residues[residues.count - 1]
            switch name {
            case "N": r.n = p
            case "CA": r.ca = p
            case "C": r.c = p
            case "O", "OXT": if r.o == nil { r.o = p }
            default: break
            }
            r.atoms.append(i)
            residues[residues.count - 1] = r
        }
        guard residues.count >= 2 else { return nil }

        // --- amide hydrogens: H = N + (C_prev − O_prev)/|C_prev − O_prev| ---
        func bonded(_ i: Int) -> Bool {
            guard i > 0, let c = residues[i - 1].c, let n = residues[i].n,
                  residues[i - 1].chain == residues[i].chain else { return false }
            return length(n - c) < 2.5
        }
        // Chain segments: turns, helices and bends are only meaningful along an
        // unbroken backbone, so everything below is guarded by "same segment".
        var segment = [Int](repeating: 0, count: residues.count)
        for i in 1..<residues.count { segment[i] = bonded(i) ? segment[i - 1] : segment[i - 1] + 1 }
        func sameSegment(_ i: Int, _ j: Int) -> Bool {
            i >= 0 && j >= 0 && i < segment.count && j < segment.count && segment[i] == segment[j]
        }

        for i in residues.indices where bonded(i) && residues[i].resname != "PRO" {
            guard let n = residues[i].n, let cp = residues[i - 1].c, let op = residues[i - 1].o else { continue }
            let d = cp - op
            let l = length(d)
            if l > 1e-6 { residues[i].h = n + d / l }
        }

        // --- hydrogen bonds: donor i (N–H) → acceptor j (C=O) --------------
        let count = residues.count
        var bonds = Set<Int>()
        for i in 0..<count {
            guard let n = residues[i].n, let h = residues[i].h, let cai = residues[i].ca else { continue }
            for j in 0..<count where abs(i - j) >= 2 {
                guard let c = residues[j].c, let o = residues[j].o, let caj = residues[j].ca else { continue }
                guard length(cai - caj) < 9.0 else { continue }
                let e = 27.888 * (1 / length(o - n) + 1 / length(c - h) - 1 / length(o - h) - 1 / length(c - n))
                if e < -0.5 { bonds.insert(i * count + j) }
            }
        }
        func hbond(_ donor: Int, _ acceptor: Int) -> Bool {
            donor >= 0 && donor < count && acceptor >= 0 && acceptor < count
                && bonds.contains(donor * count + acceptor)
        }

        // --- turns, helices ------------------------------------------------
        var letters = [Character](repeating: " ", count: count)
        var turnFlag = [Bool](repeating: false, count: count)
        var helix: [Character?] = Array(repeating: nil, count: count)
        for n in [3, 4, 5] {
            let letter: Character = n == 3 ? "G" : (n == 4 ? "H" : "I")
            var turn = [Bool](repeating: false, count: count)
            for i in 0..<count where hbond(i + n, i) && sameSegment(i, i + n) { turn[i] = true }
            for i in 0..<count where turn[i] {
                for k in (i + 1)...(i + n - 1) where k < count { turnFlag[k] = true }
            }
            for i in 0..<(count - 1) where turn[i] && turn[i + 1] {
                for k in (i + 1)...(i + n) where k < count {
                    // Priority H > G > I: a longer-established helix wins.
                    if helix[k] == nil || (letter == "H") || (letter == "G" && helix[k] == "I") { helix[k] = letter }
                }
            }
        }

        // --- bridges and ladders -------------------------------------------
        // A bridge (i,j) is parallel or antiparallel; two bridges that are
        // neighbours in both strands form a ladder, and a ladder is a sheet (E).
        // An isolated bridge is B.
        var parallel = Set<Int>(), antiparallel = Set<Int>()
        if count >= 5 {
            for i in 1..<(count - 1) {
                var j = i + 3
                while j < count - 1 {
                    defer { j += 1 }
                    guard sameSegment(i - 1, i + 1), sameSegment(j - 1, j + 1) else { continue }
                    if (hbond(i, j - 1) && hbond(j + 1, i)) || (hbond(j, i - 1) && hbond(i + 1, j)) {
                        parallel.insert(i * count + j)
                    }
                    if (hbond(i, j) && hbond(j, i)) || (hbond(i - 1, j + 1) && hbond(j - 1, i + 1)) {
                        antiparallel.insert(i * count + j)
                    }
                }
            }
        }
        var bridgePartners = [Int: Bool]()          // residue → in a ladder (true) or isolated
        func note(_ i: Int, _ inLadder: Bool) { bridgePartners[i] = (bridgePartners[i] ?? false) || inLadder }
        for (set, step) in [(parallel, 1), (antiparallel, -1)] {
            for code in set {
                let i = code / count, j = code % count
                let ladder = set.contains((i + 1) * count + (j + step))
                    || set.contains((i - 1) * count + (j - step))
                note(i, ladder); note(j, ladder)
            }
        }

        // --- bend (κ > 70°) --------------------------------------------------
        var bend = [Bool](repeating: false, count: count)
        for i in 2..<max(2, count - 2) {
            guard sameSegment(i - 2, i + 2) else { continue }
            guard let a = residues[i - 2].ca, let b = residues[i].ca, let c = residues[i + 2].ca else { continue }
            let u = b - a, v = c - b
            let lu = length(u), lv = length(v)
            guard lu > 1e-9, lv > 1e-9 else { continue }
            let cosK = max(-1.0, min(1.0, (u * v).sum() / (lu * lv)))
            if acos(cosK) * 180 / .pi > 70 { bend[i] = true }
        }

        // --- summary letter, DSSP priority H B E G I T S ---------------------
        for i in 0..<count {
            if helix[i] == "H" { letters[i] = "H" }
            else if let inLadder = bridgePartners[i] { letters[i] = inLadder ? "E" : "B" }
            else if let h = helix[i] { letters[i] = h }
            else if turnFlag[i] { letters[i] = "T" }
            else if bend[i] { letters[i] = "S" }
            else { letters[i] = "-" }
        }

        var perAtom = [Float](repeating: 0, count: frame.count)
        for (r, residue) in residues.enumerated() {
            let cls = SecondaryStructure.classIndex(letters[r])
            for a in residue.atoms { perAtom[a] = cls }
        }
        return SecondaryStructure(letters: letters, residueLabels: residues.map { $0.label },
                                  perAtomClass: perAtom)
    }

    private static func length(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }
}
