//
//  Bonds.swift — distance-criterion bond perception + protein backbone trace.
//
//  MD trajectories carry no topology: an XYZ frame is a bag of atoms. Every
//  viewer that draws sticks therefore *perceives* bonds geometrically, and the
//  standard criterion is the covalent-radius sum with a tolerance:
//
//      bonded(i, j)  ⟺  d(i, j) ≤ tolerance × (r_i + r_j)
//
//  Radii are Cordero et al., "Covalent radii revisited", Dalton Trans. 2008,
//  2832–2838 (the same table VMD/ASE/Open Babel start from). tolerance = 1.15
//  is the usual compromise: it keeps a stretched C–C bond and still rejects a
//  second-shell contact in most molecular systems.
//
//  Two deliberate departures from "chemistry", both for rendering:
//
//  • **H–H is never bonded.** With Cordero radii the rule is nearly free
//    (geminal H…H is ~1.8 Å, the criterion allows 1.15 × 0.62 = 0.71 Å), but
//    it is the guard that keeps a raised tolerance, or a compressed water,
//    from drawing an H–H stick that no force field has. Every viewer does it.
//  • **Open boundaries.** The neighbour search ignores the cell even when the
//    frame has one: a bond found through the periodic image would draw as a
//    line straight across the whole box. A molecule wrapped at the boundary
//    therefore renders with a gap, which is honest — the atoms really are on
//    opposite sides of the picture.
//

import Foundation

/// Perceived topology for one frame: bonds as index pairs, plus the Cα trace.
public struct BondSet {
    /// Two atom indices per bond, flat (`pairs[2k]`, `pairs[2k+1]`).
    public var pairs: [UInt32]
    /// One polyline of Cα atom indices per chain, ordered by residue id.
    /// Empty unless the frame carries residue labels.
    public var backbone: [[UInt32]]

    public init(pairs: [UInt32] = [], backbone: [[UInt32]] = []) {
        self.pairs = pairs
        self.backbone = backbone
    }

    public var bondCount: Int { pairs.count / 2 }
    public var isEmpty: Bool { pairs.isEmpty && backbone.isEmpty }

    /// Neighbours of `atom` implied by `pairs` — the test/debug view; the
    /// renderer never needs it.
    public func neighbors(of atom: Int) -> [Int] {
        var out: [Int] = []
        let a = UInt32(atom)
        for k in stride(from: 0, to: pairs.count, by: 2) {
            if pairs[k] == a { out.append(Int(pairs[k + 1])) }
            else if pairs[k + 1] == a { out.append(Int(pairs[k])) }
        }
        return out
    }
}

public enum BondPerception {

    /// The usual viewer tolerance on the covalent-radius sum.
    public static let defaultTolerance: Double = 1.15
    /// Above this atom count perception is skipped: the bond list itself is
    /// fine, but the line buffer it feeds (2 vertices per half-bond) grows
    /// past what a 60 Hz redraw can rebuild while scrubbing.
    public static let defaultMaxAtoms = 200_000

    /// Covalent radii in Å (Cordero et al. 2008). Transition metals use the
    /// low-spin value where the paper gives two. Anything absent — including a
    /// native dump's numeric type token — falls back to 1.5 Å, which bonds
    /// generously rather than drawing a structure with no sticks at all.
    public static let unknownRadius: Double = 1.5
    public static let covalentRadii: [String: Double] = [
        "H": 0.31, "He": 0.28,
        "Li": 1.28, "Be": 0.96, "B": 0.84, "C": 0.76, "N": 0.71, "O": 0.66,
        "F": 0.57, "Ne": 0.58,
        "Na": 1.66, "Mg": 1.41, "Al": 1.21, "Si": 1.11, "P": 1.07, "S": 1.05,
        "Cl": 1.02, "Ar": 1.06,
        "K": 2.03, "Ca": 1.76, "Sc": 1.70, "Ti": 1.60, "V": 1.53, "Cr": 1.39,
        "Mn": 1.39, "Fe": 1.32, "Co": 1.26, "Ni": 1.24, "Cu": 1.32, "Zn": 1.22,
        "Ga": 1.22, "Ge": 1.20, "As": 1.19, "Se": 1.20, "Br": 1.20, "Kr": 1.16,
        "Rb": 2.20, "Sr": 1.95, "Y": 1.90, "Zr": 1.75, "Nb": 1.64, "Mo": 1.54,
        "Ru": 1.46, "Rh": 1.42, "Pd": 1.39, "Ag": 1.45, "Cd": 1.44, "In": 1.42,
        "Sn": 1.39, "Sb": 1.39, "Te": 1.38, "I": 1.39, "Xe": 1.40,
        "Cs": 2.44, "Ba": 2.15, "W": 1.62, "Pt": 1.36, "Au": 1.36, "Hg": 1.32,
        "Tl": 1.45, "Pb": 1.46, "Bi": 1.48,
    ]

    /// Radius for an element token. Tokens are matched case-insensitively
    /// ("AL" and "al" are aluminium) so dump files with shouty symbols work.
    public static func radius(for element: String) -> Double {
        if let r = covalentRadii[element] { return r }
        guard let first = element.first else { return unknownRadius }
        let normalized = String(first).uppercased() + element.dropFirst().lowercased()
        return covalentRadii[normalized] ?? unknownRadius
    }

    /// Why perception was skipped for a frame of this size, or nil if it runs.
    public static func skipReason(atomCount: Int, maxAtoms: Int = defaultMaxAtoms) -> String? {
        guard atomCount > maxAtoms else { return nil }
        return "Bonds are not drawn above \(maxAtoms) atoms (this frame has \(atomCount)); "
             + "the stick geometry costs more to rebuild than the frame itself."
    }

    /// Perceive bonds (and, when the labels are there, the backbone trace).
    /// Returns nil when the frame is over `maxAtoms` — see `skipReason` — or
    /// when `isCancelled` fires; callers discard a nil rather than clearing
    /// what is already on screen.
    public static func perceive(frame: Frame,
                                tolerance: Double = defaultTolerance,
                                maxAtoms: Int = defaultMaxAtoms,
                                isCancelled: @escaping () -> Bool = { false }) -> BondSet? {
        let atoms = frame.atoms
        guard !atoms.isEmpty, skipReason(atomCount: atoms.count, maxAtoms: maxAtoms) == nil else {
            return nil
        }
        let tol = max(0.01, tolerance)

        var radii = [Double](repeating: unknownRadius, count: atoms.count)
        var isHydrogen = [Bool](repeating: false, count: atoms.count)
        var cache: [String: Double] = [:]
        var maxRadius = 0.0
        for (i, a) in atoms.enumerated() {
            let r: Double
            if let hit = cache[a.element] { r = hit } else { r = radius(for: a.element); cache[a.element] = r }
            radii[i] = r
            isHydrogen[i] = (a.element == "H" || a.element == "h" || a.element == "D")
            maxRadius = Swift.max(maxRadius, r)
        }
        // One cutoff for the whole frame: the largest pair that can bond.
        let cutoff = tol * 2 * maxRadius
        let positions = frame.positions
        // Open boundaries on purpose (see the file header): a bond through a
        // periodic image would draw across the box.
        let neighbors = NeighborList(positions: positions, cutoff: cutoff, box: nil,
                                     isCancelled: isCancelled)
        if neighbors.wasCancelled { return nil }

        var pairs: [UInt32] = []
        pairs.reserveCapacity(atoms.count * 4)
        for i in 0..<atoms.count {
            if i % 10_000 == 0, isCancelled() { return nil }
            let ri = radii[i], hi = isHydrogen[i]
            neighbors.forEachNeighbor(of: i) { j, d in
                guard j > i else { return }                 // each bond once
                guard !(hi && isHydrogen[j]) else { return } // never H–H
                guard d > 0.05, d <= tol * (ri + radii[j]) else { return }
                pairs.append(UInt32(i))
                pairs.append(UInt32(j))
            }
        }
        return BondSet(pairs: pairs, backbone: backbone(frame: frame))
    }

    // MARK: - Backbone trace

    /// One Cα polyline per chain, residues in ascending `resid`.
    ///
    /// Requires a residue id — `labels["resid"]` or the numeric column an
    /// extended XYZ writes for `resid:I:1` — and takes the chain from
    /// `labels["chain"]` (everything is one chain when that label is absent).
    /// The α carbon is `labels["name"] == "CA"` where atom names exist; where
    /// they do not (the common extended-XYZ case: species/chain/resname/resid
    /// and nothing else) it is the residue's FIRST carbon, which is Cα in the
    /// PDB atom order every builder writes (N, H…, CA, HA, C, O, CB…).
    public static func backbone(frame: Frame) -> [[UInt32]] {
        guard let resid = residueIDs(frame) else { return [] }
        let names = frame.label("name")
        let chains = frame.label("chain")
        let atoms = frame.atoms

        // chain → resid → representative atom index (first match wins).
        var byChain: [String: [Int: Int]] = [:]
        for i in atoms.indices {
            guard let rid = resid[i] else { continue }
            let isAlpha: Bool
            if let names { isAlpha = names[i] == "CA" }
            else { isAlpha = (atoms[i].element == "C") }
            guard isAlpha else { continue }
            let chain = chains?[i] ?? ""
            if byChain[chain]?[rid] == nil { byChain[chain, default: [:]][rid] = i }
        }

        return byChain.keys.sorted().compactMap { chain in
            guard let residues = byChain[chain], residues.count >= 2 else { return nil }
            return residues.keys.sorted().map { UInt32(residues[$0]!) }
        }
    }

    /// Residue id per atom from either the string label or the numeric column.
    private static func residueIDs(_ frame: Frame) -> [Int?]? {
        if let label = frame.label("resid") { return label.map { Int($0) } }
        if let column = frame.column("resid") { return column.map { Int($0.rounded()) } }
        if let label = frame.label("resnum") { return label.map { Int($0) } }
        if let column = frame.column("resnum") { return column.map { Int($0.rounded()) } }
        return nil
    }
}
