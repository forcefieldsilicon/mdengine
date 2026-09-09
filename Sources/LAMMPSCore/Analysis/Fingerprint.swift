//
//  Fingerprint.swift — *which chemistry* holds the interface together, per frame
//  and over a trajectory.
//
//  Contacts and H-bonds (AdhesionTool) say how much and roughly where. An
//  interaction fingerprint says what: salt bridges, π-stacking (face-to-face vs
//  T-shaped), cation–π, hydrophobic packing. All of it is name-based chemistry,
//  so it needs the extended XYZ's `name` column (PDB atom name) — `smd_pull.py`
//  writes it; without it the tool reports contacts and H-bonds only, and says so.
//
//  Geometric criteria are the conventional ones (PLIP / Arpeggio family):
//    salt bridge   cationic N ··· anionic O   < 4.0 Å           (residue pair counted once)
//    π-stack       ring-centroid distance     < 5.5 Å, inter-plane angle < 30°
//                  (face-to-face, lateral offset < 2.0 Å) or 60–90° (T-shaped)
//    cation–π      LYS NZ / ARG CZ ··· centroid < 6.0 Å
//    hydrophobic   side-chain C of a hydrophobic residue ··· C  < 4.0 Å (pair once)
//
//  Trajectory level: H-bond occupancy and mean lifetime, and per-residue contact
//  frequency — the honest version of "where does it stick". Walking a trajectory
//  is expensive, so `TrajectoryFingerprint.cached` keys on the trajectory
//  generation plus the parameters and polls `isCancelled` between frames; the
//  app decides *when* to ask (section expanded), this decides how much it costs
//  the second time (nothing).
//

import Foundation

/// Per-atom interaction class. The numbering is the field's categorical
/// palette, so it is part of the tool's contract: 0 none, 1/2 plain contact,
/// then the specific chemistries.
public enum InteractionClass: Int, CaseIterable {
    case none = 0, contactA = 1, contactB = 2, hbond = 3, saltBridge = 4, piStack = 5, hydrophobic = 6

    /// Higher wins when an atom qualifies for several: a lysine NZ in a salt
    /// bridge is a salt bridge, not "a contact".
    var priority: Int {
        switch self {
        case .none: return 0
        case .contactA, .contactB: return 1
        case .hydrophobic: return 2
        case .hbond: return 3
        case .piStack: return 4
        case .saltBridge: return 5
        }
    }

    static let legend: [(label: String, color: RGB)] = [
        ("none", RGB(0.6, 0.6, 0.6)),
        ("contact A", RGB(1.0, 0.55, 0.1)),
        ("contact B", RGB(0.2, 0.8, 1.0)),
        ("H-bond", RGB(0.35, 0.85, 0.45)),
        ("salt bridge", RGB(0.95, 0.25, 0.35)),
        ("π-stack / cation–π", RGB(0.75, 0.45, 0.95)),
        ("hydrophobic", RGB(0.95, 0.85, 0.25))
    ]
}

/// Per-residue tally for the interaction table.
public struct ResidueInteractions: Equatable {
    public var contacts = 0, hbonds = 0, saltBridges = 0, pi = 0, hydrophobic = 0
    public var total: Int { contacts + hbonds + saltBridges + pi + hydrophobic }
    public init() {}
}

public enum Fingerprint {

    // MARK: - Chemistry tables

    /// Cationic nitrogens by residue (HIS treated as the protonated HIP form —
    /// a fingerprint that silently drops every histidine is worse than one that
    /// over-reports it and says so).
    static let cationicN: [String: Set<String>] = [
        "LYS": ["NZ"], "LYN": ["NZ"],
        "ARG": ["NH1", "NH2", "NE"],
        "HIS": ["ND1", "NE2"], "HIP": ["ND1", "NE2"]
    ]
    /// Anionic oxygens. `OXT` (C-terminal carboxylate) counts in any residue.
    static let anionicO: [String: Set<String>] = ["ASP": ["OD1", "OD2"], "GLU": ["OE1", "OE2"]]
    static let terminalO = "OXT"
    /// Aromatic rings, in ring-bond order. TRP has both of its rings (they
    /// share CD2/CE2, which is why they are listed separately, not merged).
    static let rings: [String: [[String]]] = [
        "PHE": [["CG", "CD1", "CE1", "CZ", "CE2", "CD2"]],
        "TYR": [["CG", "CD1", "CE1", "CZ", "CE2", "CD2"]],
        "TRP": [["CG", "CD1", "NE1", "CE2", "CD2"],
                ["CD2", "CE2", "CZ2", "CH2", "CZ3", "CE3"]],
        "HIS": [["CG", "ND1", "CE1", "NE2", "CD2"]],
        "HID": [["CG", "ND1", "CE1", "NE2", "CD2"]],
        "HIE": [["CG", "ND1", "CE1", "NE2", "CD2"]],
        "HIP": [["CG", "ND1", "CE1", "NE2", "CD2"]]
    ]
    /// The cation of a cation–π: the charged head, not the whole side chain.
    static let cationPiAtoms: [String: Set<String>] = ["LYS": ["NZ"], "LYN": ["NZ"], "ARG": ["CZ"]]
    static let hydrophobicResidues: Set<String> = ["ALA", "VAL", "LEU", "ILE", "MET", "PHE", "TRP", "PRO", "TYR"]
    /// Backbone carbons — "side chain" starts at CB.
    static let backboneCarbons: Set<String> = ["C", "CA"]

    public struct Cutoffs: Equatable {
        public var saltBridge = 4.0
        public var ringCentroid = 5.5
        public var ringOffset = 2.0
        public var faceAngle = 30.0
        public var tShapedAngle = 60.0
        public var cationPi = 6.0
        public var hydrophobic = 4.0
        public init() {}
    }

    /// Counts and markings for one frame.
    public struct Result {
        public var saltBridges = 0
        public var faceToFace = 0
        public var tShaped = 0
        public var cationPi = 0
        public var hydrophobic = 0
        /// Per-atom class, `.none` where the atom takes part in nothing specific.
        public var classes: [InteractionClass] = []
        /// Group-A residues (display key) → tally.
        public var perResidue: [String: ResidueInteractions] = [:]
        public var piTypes: [String] = []
        public var any: Bool { saltBridges + faceToFace + tShaped + cationPi + hydrophobic > 0 }
    }

    /// One residue's atoms, as the geometry needs them.
    public struct Residue {
        public let displayKey: String
        public let resname: String
        public var atoms: [Int] = []
        public var inA = false
    }

    // MARK: - Per-frame fingerprint

    /// nil when the frame carries no `name` label — the caller reports why.
    ///
    /// `list` must have a cutoff of at least `cuts.hydrophobic`; salt bridges,
    /// rings and cation–π go brute force over the (few) chemically eligible
    /// atoms, which is cheaper than another grid.
    public static func analyze(frame: Frame, inA: [Bool], inB: [Bool],
                               residueSlot: [Int], residues: [Residue],
                               names: [String], resnames: [String],
                               hbondPairs: [(donor: Int, acceptor: Int)],
                               list: NeighborList, cuts: Cutoffs,
                               isCancelled: () -> Bool) throws -> Result {
        let n = frame.count
        let pos = frame.positions
        let box = frame.box
        var out = Result()
        out.classes = [InteractionClass](repeating: .none, count: n)

        func mark(_ i: Int, _ c: InteractionClass) {
            if c.priority > out.classes[i].priority { out.classes[i] = c }
        }
        func delta(_ i: Int, _ j: Int) -> SIMD3<Double> {
            var d = pos[j] - pos[i]
            if let box { d = box.minimumImage(d) }
            return d
        }
        func dist(_ i: Int, _ j: Int) -> Double {
            let d = delta(i, j)
            return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
        }
        func tallyA(_ slot: Int, _ body: (inout ResidueInteractions) -> Void) {
            guard slot >= 0, slot < residues.count, residues[slot].inA else { return }
            var t = out.perResidue[residues[slot].displayKey] ?? ResidueInteractions()
            body(&t)
            out.perResidue[residues[slot].displayKey] = t
        }

        // 1. Salt bridges ------------------------------------------------------
        var cations: [Int] = [], anions: [Int] = []
        for i in 0..<n where inA[i] || inB[i] {
            let rn = resnames[i], nm = names[i]
            if cationicN[rn]?.contains(nm) == true { cations.append(i) }
            if anionicO[rn]?.contains(nm) == true || nm == terminalO { anions.append(i) }
        }
        var bridgedPairs = Set<Int64>()
        for c in cations {
            if isCancelled() { throw AnalysisError.cancelled }
            for a in anions {
                guard (inA[c] && inB[a]) || (inB[c] && inA[a]) else { continue }
                guard dist(c, a) < cuts.saltBridge else { continue }
                mark(c, .saltBridge); mark(a, .saltBridge)
                let key = pairKey(residueSlot[c], residueSlot[a])
                if bridgedPairs.insert(key).inserted {
                    out.saltBridges += 1
                    tallyA(residueSlot[c]) { $0.saltBridges += 1 }
                    tallyA(residueSlot[a]) { $0.saltBridges += 1 }
                }
            }
        }

        // 2. Rings, π-stacking, cation–π --------------------------------------
        struct RingGeom { let slot: Int; let atoms: [Int]; let centroid: SIMD3<Double>; let normal: SIMD3<Double>; let inA: Bool }
        var ringList: [RingGeom] = []
        for (slot, res) in residues.enumerated() {
            guard let patterns = rings[res.resname] else { continue }
            var byName: [String: Int] = [:]
            for i in res.atoms where inA[i] || inB[i] { byName[names[i]] = i }
            for pattern in patterns {
                let idx = pattern.compactMap { byName[$0] }
                guard idx.count == pattern.count else { continue }
                guard let g = ringGeometry(idx, pos: pos, box: box) else { continue }
                ringList.append(RingGeom(slot: slot, atoms: idx, centroid: g.centroid,
                                         normal: g.normal, inA: inA[idx[0]]))
            }
        }
        for i in ringList.indices {
            if isCancelled() { throw AnalysisError.cancelled }
            for j in ringList.indices where j > i {
                let r1 = ringList[i], r2 = ringList[j]
                guard r1.inA != r2.inA else { continue }
                var d = r2.centroid - r1.centroid
                if let box { d = box.minimumImage(d) }
                let sep = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
                guard sep < cuts.ringCentroid else { continue }
                let cosA = min(1, abs(dot(r1.normal, r2.normal)))
                let angle = acos(cosA) * 180 / .pi
                let along = dot(d, r1.normal)
                let lateral = (max(0, sep * sep - along * along)).squareRoot()
                var kind: String?
                if angle < cuts.faceAngle && lateral < cuts.ringOffset {
                    out.faceToFace += 1; kind = "face-to-face"
                } else if angle >= cuts.tShapedAngle {
                    out.tShaped += 1; kind = "T-shaped"
                }
                guard let kind else { continue }
                out.piTypes.append(kind)
                for a in r1.atoms + r2.atoms { mark(a, .piStack) }
                tallyA(r1.slot) { $0.pi += 1 }
                tallyA(r2.slot) { $0.pi += 1 }
            }
        }
        for i in 0..<n where inA[i] || inB[i] {
            guard cationPiAtoms[resnames[i]]?.contains(names[i]) == true else { continue }
            for ring in ringList where ring.inA != inA[i] {
                var d = ring.centroid - pos[i]
                if let box { d = box.minimumImage(d) }
                guard (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot() < cuts.cationPi else { continue }
                out.cationPi += 1
                mark(i, .piStack)
                for a in ring.atoms { mark(a, .piStack) }
                tallyA(residueSlot[i]) { $0.pi += 1 }
                tallyA(ring.slot) { $0.pi += 1 }
            }
        }

        // 3. Hydrophobic contacts ---------------------------------------------
        let elements = frame.atoms.map { Groups.normalizedElement($0.element) }
        var phobicPairs = Set<Int64>()
        for i in 0..<n {
            if i & 0x3FF == 0, isCancelled() { throw AnalysisError.cancelled }
            guard inA[i] || inB[i], elements[i] == "C",
                  hydrophobicResidues.contains(resnames[i]),
                  !backboneCarbons.contains(names[i]) else { continue }
            list.forEachNeighbor(of: i) { j, d in
                guard d < cuts.hydrophobic, elements[j] == "C" else { return }
                guard (inA[i] && inB[j]) || (inB[i] && inA[j]) else { return }
                mark(i, .hydrophobic); mark(j, .hydrophobic)
                let key = pairKey(residueSlot[i], residueSlot[j])
                if phobicPairs.insert(key).inserted {
                    out.hydrophobic += 1
                    tallyA(residueSlot[i]) { $0.hydrophobic += 1 }
                    tallyA(residueSlot[j]) { $0.hydrophobic += 1 }
                }
            }
        }

        // 4. H-bond partners (counted by AdhesionTool; marked and tallied here)
        for (d, a) in hbondPairs {
            mark(d, .hbond); mark(a, .hbond)
            tallyA(residueSlot[d]) { $0.hbonds += 1 }
            tallyA(residueSlot[a]) { $0.hbonds += 1 }
        }
        return out
    }

    // MARK: - Geometry helpers

    static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

    static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    /// Centroid and unit normal of a ring. The normal is the cross product of
    /// the two centroid-relative vectors that span the largest area — the
    /// best-conditioned pair — so it is right whatever order the atom names
    /// came in, and does not need an eigen solver. Positions are taken in the
    /// image of the first ring atom so a ring split across a boundary is whole.
    static func ringGeometry(_ idx: [Int], pos: [SIMD3<Double>], box: SimulationBox?)
        -> (centroid: SIMD3<Double>, normal: SIMD3<Double>)? {
        guard idx.count >= 3 else { return nil }
        let anchor = pos[idx[0]]
        let p: [SIMD3<Double>] = idx.map { i in
            var d = pos[i] - anchor
            if let box { d = box.minimumImage(d) }
            return anchor + d
        }
        var centroid = SIMD3<Double>(repeating: 0)
        for q in p { centroid += q }
        centroid /= Double(p.count)
        let v = p.map { $0 - centroid }
        var normal = SIMD3<Double>(repeating: 0), best = 0.0
        for i in v.indices {
            for j in v.indices where j > i {
                let c = cross(v[i], v[j])
                let m = (c.x * c.x + c.y * c.y + c.z * c.z).squareRoot()
                if m > best { best = m; normal = c }
            }
        }
        guard best > 1e-9 else { return nil }
        return (centroid, normal / best)
    }

    static func pairKey(_ a: Int, _ b: Int) -> Int64 {
        let (lo, hi) = a <= b ? (a, b) : (b, a)
        return Int64(lo) &* 1_000_003 &+ Int64(hi)
    }

    /// Residue slots for a frame: one entry per (chain, resname, resid), each
    /// atom pointing at its slot. nil when the frame cannot name residues.
    public static func residueSlots(frame: Frame, inA: [Bool], inB: [Bool])
        -> (slot: [Int], residues: [Residue])? {
        guard let resname = frame.label("resname") else { return nil }
        let resid: [String]
        if let r = frame.label("resid") { resid = r }
        else if let r = frame.column("resid") { resid = r.map { String(Int($0)) } }
        else { return nil }
        let chain = frame.label("chain") ?? [String](repeating: "", count: frame.count)
        var index: [String: Int] = [:]
        var residues: [Residue] = []
        var slot = [Int](repeating: -1, count: frame.count)
        for i in 0..<frame.count {
            let rn = resname[i].trimmingCharacters(in: .whitespaces).uppercased()
            let key = "\(chain[i])|\(rn)|\(resid[i])"
            let s: Int
            if let existing = index[key] { s = existing } else {
                s = residues.count
                index[key] = s
                let display = chain[i].isEmpty ? "\(resname[i]) \(resid[i])" : "\(chain[i]):\(resname[i]) \(resid[i])"
                residues.append(Residue(displayKey: display, resname: rn))
            }
            slot[i] = s
            residues[s].atoms.append(i)
            if inA[i] { residues[s].inA = true }
            _ = inB
        }
        return (slot, residues)
    }
}

// MARK: - Trajectory level

/// H-bond occupancy + lifetime and per-residue contact frequency over a whole
/// trajectory. Built once per (trajectory generation, parameters) and cached.
public struct TrajectoryFingerprint {
    public struct HBondStat: Equatable {
        public let label: String
        /// Fraction of frames the donor–acceptor pair is bonded.
        public let occupancy: Double
        /// Mean length of a continuous bonded run, in `unit`.
        public let meanLifetime: Double
        /// Number of separate bonded runs.
        public let events: Int
    }
    public struct ResidueFrequency: Equatable {
        public let label: String
        public let frequency: Double
    }

    public let frameCount: Int
    public let hbonds: [HBondStat]
    public let residues: [ResidueFrequency]
    /// "ps" when the run's report interval is known, otherwise "frames".
    public let unit: String
    public let interval: Double

    // MARK: Computation

    /// Walks every frame: this is the expensive one. `isCancelled` is polled
    /// between frames, and a cancelled walk is never cached.
    public static func compute(trajectory: Trajectory,
                               selA: GroupSelector, selB: GroupSelector,
                               params: AdhesionTool.Parameters,
                               interval: Double, unit: String,
                               isCancelled: @escaping () -> Bool) throws -> TrajectoryFingerprint {
        var present: [String: [Bool]] = [:]
        var order: [String] = []
        var residuePresent: [String: [Bool]] = [:]
        var residueOrder: [String] = []
        let n = trajectory.count

        for (f, frame) in trajectory.enumerated() {
            if isCancelled() { throw AnalysisError.cancelled }
            let a = Groups.indices(selA, in: frame), b = Groups.indices(selB, in: frame)
            guard !a.isEmpty, !b.isEmpty else { continue }
            var inA = [Bool](repeating: false, count: frame.count)
            var inB = [Bool](repeating: false, count: frame.count)
            for i in a { inA[i] = true }
            for i in b { inB[i] = true }
            let elements = frame.atoms.map { Groups.normalizedElement($0.element) }
            let heavy = elements.map { $0 != "H" && $0 != "D" }
            let isPolar = elements.map { $0 == "N" || $0 == "O" }
            let slots = Fingerprint.residueSlots(frame: frame, inA: inA, inB: inB)
            let names = frame.label("name")

            // Contact frequency, per group-A residue.
            let contactList = NeighborList(frame: frame, cutoff: params.contactCutoff, isCancelled: isCancelled)
            if contactList.wasCancelled { throw AnalysisError.cancelled }
            var touched = Set<Int>()
            for i in a where heavy[i] {
                contactList.forEachNeighbor(of: i) { j, _ in
                    if inB[j] && heavy[j] { touched.insert(i) }
                }
            }
            if let slots {
                var hit = Set<String>()
                for i in touched where slots.slot[i] >= 0 { hit.insert(slots.residues[slots.slot[i]].displayKey) }
                for (_, res) in slots.residues.enumerated() where res.inA {
                    if residuePresent[res.displayKey] == nil {
                        residuePresent[res.displayKey] = [Bool](repeating: false, count: n)
                        residueOrder.append(res.displayKey)
                    }
                    residuePresent[res.displayKey]![f] = hit.contains(res.displayKey)
                }
            }

            // H-bonds, by donor/acceptor atom index (topology is fixed frame to frame).
            guard elements.contains("H") || elements.contains("D") else { continue }
            let hbList = params.hbondDistance <= params.contactCutoff
                ? contactList : NeighborList(frame: frame, cutoff: params.hbondDistance, isCancelled: isCancelled)
            let bondList = hbList.cutoff >= AdhesionTool.donorBondCutoff
                ? hbList : NeighborList(frame: frame, cutoff: AdhesionTool.donorBondCutoff, isCancelled: isCancelled)
            if hbList.wasCancelled || bondList.wasCancelled { throw AnalysisError.cancelled }
            let pairs = AdhesionTool.hydrogenBondPairs(frame: frame, donors: a, acceptorMask: inB,
                                                       elements: elements, isPolar: isPolar,
                                                       hbList: hbList, bondList: bondList, params: params)
                      + AdhesionTool.hydrogenBondPairs(frame: frame, donors: b, acceptorMask: inA,
                                                       elements: elements, isPolar: isPolar,
                                                       hbList: hbList, bondList: bondList, params: params)
            for (d, acc) in pairs {
                let label = pairLabel(d, acc, slots: slots, names: names, elements: elements)
                if present[label] == nil { present[label] = [Bool](repeating: false, count: n); order.append(label) }
                present[label]![f] = true
            }
        }

        func runs(_ series: [Bool]) -> [Int] {
            var out: [Int] = [], run = 0
            for v in series {
                if v { run += 1 } else if run > 0 { out.append(run); run = 0 }
            }
            if run > 0 { out.append(run) }
            return out
        }
        let stats: [HBondStat] = order.compactMap { label in
            guard let series = present[label] else { return nil }
            let r = runs(series)
            guard !r.isEmpty else { return nil }
            let occupied = r.reduce(0, +)
            return HBondStat(label: label, occupancy: Double(occupied) / Double(n),
                             meanLifetime: Double(occupied) / Double(r.count) * interval,
                             events: r.count)
        }.sorted { $0.occupancy == $1.occupancy ? $0.label < $1.label : $0.occupancy > $1.occupancy }

        let freqs: [ResidueFrequency] = residueOrder.compactMap { label in
            guard let series = residuePresent[label] else { return nil }
            let hits = series.reduce(0) { $0 + ($1 ? 1 : 0) }
            guard hits > 0 else { return nil }
            return ResidueFrequency(label: label, frequency: Double(hits) / Double(n))
        }.sorted { $0.frequency == $1.frequency ? $0.label < $1.label : $0.frequency > $1.frequency }

        return TrajectoryFingerprint(frameCount: n, hbonds: stats, residues: freqs,
                                     unit: unit, interval: interval)
    }

    static func pairLabel(_ d: Int, _ a: Int, slots: (slot: [Int], residues: [Fingerprint.Residue])?,
                          names: [String]?, elements: [String]) -> String {
        func side(_ i: Int) -> String {
            let atom = names.map { $0[i] } ?? "\(elements[i])\(i)"
            if let slots, slots.slot[i] >= 0 { return "\(slots.residues[slots.slot[i]].displayKey) \(atom)" }
            return "\(atom) #\(i)"
        }
        return "\(side(d)) → \(side(a))"
    }

    // MARK: Cache

    private struct Key: Hashable { let generation: Int; let params: String; let frames: Int }
    private static let lock = NSLock()
    private nonisolated(unsafe) static var entries: [(key: Key, value: TrajectoryFingerprint)] = []

    /// Cached by trajectory generation + parameters + frame count. Generation 0
    /// means "ephemeral" (an in-memory trajectory the caller assembled): those
    /// are computed but never cached, so a test never sees a stale answer.
    public static func cached(trajectory: Trajectory, generation: Int,
                              selA: GroupSelector, selB: GroupSelector,
                              params: AdhesionTool.Parameters,
                              interval: Double, unit: String,
                              isCancelled: @escaping () -> Bool) throws -> TrajectoryFingerprint {
        let paramKey = (try? JSONEncoder().encode(params)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let key = Key(generation: generation,
                      params: paramKey + "|" + selA.describedText + "|" + selB.describedText,
                      frames: trajectory.count)
        if generation != 0 {
            lock.lock()
            let hit = entries.first { $0.key == key }?.value
            lock.unlock()
            if let hit { return hit }
        }
        let built = try compute(trajectory: trajectory, selA: selA, selB: selB, params: params,
                                interval: interval, unit: unit, isCancelled: isCancelled)
        if generation != 0 {
            lock.lock()
            entries.removeAll { $0.key == key }
            entries.append((key, built))
            if entries.count > 2 { entries.removeFirst(entries.count - 2) }
            lock.unlock()
        }
        return built
    }

    public static func clearCache() { lock.lock(); entries.removeAll(); lock.unlock() }
}
