//
//  AdhesionTool.swift — "does B still stick to A, and where?" (design §2.3).
//
//  Per frame, for two groups: heavy-atom contacts under 4.5 Å (the standard
//  protein contact cutoff), hydrogen bonds by the Baker–Hubbard 1984 criteria
//  (D···A < 3.5 Å, D–H···A > 120°) when the frame has hydrogens — and the
//  distance criterion alone, *labelled as such*, when it does not — plus COM–COM
//  and minimum interface separation. The contact count is the scalar the app
//  charts over frames; `ruptureFrame` turns that series into the one number the
//  pull-off study wants, and lives here so MCP and the CLI get it too.
//
//  Since GJOB-146 it also reports the *interaction fingerprint*
//  (Fingerprint.swift: salt bridges, π-stacking, cation–π, hydrophobic packing —
//  which chemistry holds the interface), trajectory-level H-bond occupancy and
//  lifetimes, and the MM/GBSA side files (InteractionEnergy.swift) when a run
//  produced them.
//

import Foundation

public struct AdhesionTool: AnalysisTool {
    public static let id = "adhesion"
    public static let title = "Adhesion"
    public static let category = ToolCategory.adhesionBinding
    public static let functions: Set<ToolFunction> = [.perAtomField, .scalar, .timeSeries]
    public static let requirements: Set<ToolRequirement> = [.groups]
    /// Contacts are a count, not a texture: a strided subset would under-report
    /// it by the stride, so the live overlay runs full or not at all.
    public static let supportsStridedPreview = false

    /// Longest X–H bond we accept when looking for a donor's hydrogen.
    static let donorBondCutoff = 1.2

    /// Which per-atom field the overlay gets.
    public enum Quantity: String, Codable, Equatable, CaseIterable {
        /// 0 none · 1 A in contact · 2 B in contact (the original field).
        case contacts
        /// The full interaction fingerprint, 0…6 (see `InteractionClass`).
        case interactions
    }

    public struct Parameters: Codable, Equatable {
        /// nil = choose from the frame (chains, then resnames, then elements).
        public var groupA: GroupSelector?
        public var groupB: GroupSelector?
        public var contactCutoff: Double
        public var hbondDistance: Double
        /// Minimum D–H···A angle in degrees.
        public var hbondAngle: Double
        /// Break the contact count down by group-A residue when labels allow.
        public var perResidue: Bool
        /// Cationic-N ··· anionic-O distance that counts as a salt bridge.
        public var saltBridgeCutoff: Double
        /// Which per-atom field to produce.
        public var quantity: Quantity
        /// Walk the whole trajectory for H-bond occupancy/lifetimes and contact
        /// frequency (cached per trajectory generation + parameters).
        public var lifetimes: Bool

        public init(groupA: GroupSelector? = nil, groupB: GroupSelector? = nil,
                    contactCutoff: Double = 4.5, hbondDistance: Double = 3.5,
                    hbondAngle: Double = 120, perResidue: Bool = true,
                    saltBridgeCutoff: Double = 4.0, quantity: Quantity = .contacts,
                    lifetimes: Bool = true) {
            self.groupA = groupA
            self.groupB = groupB
            self.contactCutoff = contactCutoff
            self.hbondDistance = hbondDistance
            self.hbondAngle = hbondAngle
            self.perResidue = perResidue
            self.saltBridgeCutoff = saltBridgeCutoff
            self.quantity = quantity
            self.lifetimes = lifetimes
        }

        /// Hand-written so parameters persisted before the fingerprint existed
        /// still decode (every field falls back to its default), which is what
        /// saved inspector state and MCP callers send.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Parameters()
            groupA = try c.decodeIfPresent(GroupSelector.self, forKey: .groupA)
            groupB = try c.decodeIfPresent(GroupSelector.self, forKey: .groupB)
            contactCutoff = try c.decodeIfPresent(Double.self, forKey: .contactCutoff) ?? d.contactCutoff
            hbondDistance = try c.decodeIfPresent(Double.self, forKey: .hbondDistance) ?? d.hbondDistance
            hbondAngle = try c.decodeIfPresent(Double.self, forKey: .hbondAngle) ?? d.hbondAngle
            perResidue = try c.decodeIfPresent(Bool.self, forKey: .perResidue) ?? d.perResidue
            saltBridgeCutoff = try c.decodeIfPresent(Double.self, forKey: .saltBridgeCutoff) ?? d.saltBridgeCutoff
            quantity = try c.decodeIfPresent(Quantity.self, forKey: .quantity) ?? d.quantity
            lifetimes = try c.decodeIfPresent(Bool.self, forKey: .lifetimes) ?? d.lifetimes
        }
    }

    public static let defaultParameters = Parameters()

    /// One cell-list build plus a 27-cell sweep over group A.
    public static func estimatedCost(atoms: Int, params: Parameters) -> Double { 0.6 * Double(atoms) }

    // MARK: - Rupture

    /// First frame index from which the contact count is zero for the rest of
    /// the series — the rupture frame. nil when contacts never fall to zero, or
    /// when they come back afterwards (a re-binding event is not a rupture).
    public static func ruptureFrame(contactCounts: [Int: Int]) -> Int? {
        let frames = contactCounts.keys.sorted()
        var rupture: Int?
        for frame in frames.reversed() {
            guard contactCounts[frame] == 0 else { break }
            rupture = frame
        }
        return rupture
    }

    // MARK: - Analysis

    public static func analyze(frame: Frame, context: AnalysisContext,
                               params: Parameters) throws -> ToolResult {
        guard frame.count > 0 else { throw AnalysisError.notApplicable("Empty frame.") }
        var notes: [String] = []

        // 1. Groups ------------------------------------------------------------
        var selA = params.groupA, selB = params.groupB
        if selA == nil || selB == nil {
            guard let suggested = Groups.suggestPair(frame) else {
                throw AnalysisError.missingRequirement(.groups)
            }
            if selA == nil { selA = suggested.a }
            if selB == nil { selB = suggested.b }
            notes.append("Groups chosen automatically: A = \(selA!.describedText), B = \(selB!.describedText).")
        } else {
            notes.append("Groups set explicitly: A = \(selA!.describedText), B = \(selB!.describedText).")
        }
        let groupA = Groups.indices(selA!, in: frame)
        let groupB = Groups.indices(selB!, in: frame)
        guard !groupA.isEmpty else {
            throw AnalysisError.notApplicable("Group A (\(selA!.describedText)) selected no atoms.")
        }
        guard !groupB.isEmpty else {
            throw AnalysisError.notApplicable("Group B (\(selB!.describedText)) selected no atoms.")
        }

        let n = frame.count
        let elements = frame.atoms.map { Groups.normalizedElement($0.element) }
        let heavy = elements.map { $0 != "H" && $0 != "D" }
        let isPolar = elements.map { $0 == "N" || $0 == "O" }
        var inA = [Bool](repeating: false, count: n), inB = [Bool](repeating: false, count: n)
        for i in groupA { inA[i] = true }
        for i in groupB { inB[i] = true }
        if groupA.contains(where: { inB[$0] }) {
            notes.append("Groups overlap; shared atoms are counted once and coloured as A.")
        }

        // 2. Contacts ----------------------------------------------------------
        let list = context.neighborList(for: frame, cutoff: params.contactCutoff)
        if list.wasCancelled || context.isCancelled() { throw AnalysisError.cancelled }

        let residueKeys = residueLabels(frame, params: params, notes: &notes)
        var contactA = [Bool](repeating: false, count: n), contactB = [Bool](repeating: false, count: n)
        var contacts = 0
        var minDistance = Double.greatestFiniteMagnitude
        var residueContacts: [String: Int] = [:]

        for (step, i) in groupA.enumerated() {
            if step & 0x3FF == 0, context.isCancelled() { throw AnalysisError.cancelled }
            guard heavy[i] else { continue }
            list.forEachNeighbor(of: i) { j, d in
                guard inB[j], heavy[j] else { return }
                // Overlapping groups: the same pair also arrives from the other
                // side, so keep only one of the two visits.
                if inB[i] && inA[j] && j < i { return }
                contacts += 1
                contactA[i] = true
                contactB[j] = true
                if d < minDistance { minDistance = d }
                if let key = residueKeys?[i] { residueContacts[key, default: 0] += 1 }
            }
        }

        // Rupture is exactly the case with no pair inside the cutoff, so the
        // minimum distance still has to be answered — brute force, capped.
        if contacts == 0 {
            let heavyA = groupA.filter { heavy[$0] }, heavyB = groupB.filter { heavy[$0] }
            if !heavyA.isEmpty, !heavyB.isEmpty, heavyA.count * heavyB.count <= 4_000_000 {
                let pos = frame.positions
                for i in heavyA {
                    if context.isCancelled() { throw AnalysisError.cancelled }
                    for j in heavyB where j != i {
                        var d = pos[j] - pos[i]
                        if let box = frame.box { d = box.minimumImage(d) }
                        let d2 = d.x * d.x + d.y * d.y + d.z * d.z
                        if d2 < minDistance * minDistance { minDistance = d2.squareRoot() }
                    }
                }
            } else {
                notes.append("Minimum interface distance not computed (no heavy atoms, or too many pairs).")
            }
        }

        // 3. Hydrogen bonds ----------------------------------------------------
        let hbList = params.hbondDistance <= params.contactCutoff
            ? list : context.neighborList(for: frame, cutoff: params.hbondDistance)
        let bondList = hbList.cutoff >= donorBondCutoff
            ? hbList : context.neighborList(for: frame, cutoff: donorBondCutoff)
        if hbList.wasCancelled || bondList.wasCancelled { throw AnalysisError.cancelled }

        let hasHydrogen = elements.contains("H") || elements.contains("D")
        var hbondRows: [SummaryRow] = []
        var hbondPairs: [(donor: Int, acceptor: Int)] = []
        if hasHydrogen {
            hbondPairs = hydrogenBondPairs(frame: frame, donors: groupA, acceptorMask: inB,
                                           elements: elements, isPolar: isPolar,
                                           hbList: hbList, bondList: bondList, params: params)
                       + hydrogenBondPairs(frame: frame, donors: groupB, acceptorMask: inA,
                                           elements: elements, isPolar: isPolar,
                                           hbList: hbList, bondList: bondList, params: params)
            hbondRows.append(SummaryRow("H-bonds", "\(hbondPairs.count)"))
        } else {
            var polar = 0
            for i in groupA where isPolar[i] {
                hbList.forEachNeighbor(of: i) { j, d in
                    guard inB[j], isPolar[j], d < params.hbondDistance else { return }
                    if inB[i] && inA[j] && j < i { return }
                    polar += 1
                }
            }
            hbondRows.append(SummaryRow("H-bonds", "n/a (no hydrogens)"))
            hbondRows.append(SummaryRow("Polar contacts (distance only)", "\(polar)"))
            notes.append("No hydrogens in this frame: N/O–N/O pairs under \(fmt(params.hbondDistance)) Å are reported as polar contacts, not H-bonds.")
        }

        // 4. Separation --------------------------------------------------------
        let comA = Groups.centerOfMass(groupA, in: frame)
        let comB = Groups.centerOfMass(groupB, in: frame)
        var comDelta = comB - comA
        if let box = frame.box { comDelta = box.minimumImage(comDelta) }
        let comDistance = (comDelta.x * comDelta.x + comDelta.y * comDelta.y + comDelta.z * comDelta.z).squareRoot()

        // 5. Interaction fingerprint -------------------------------------------
        // Chemistry needs PDB atom names; `smd_pull.py` writes them into the
        // extended XYZ. Without them the tool stops at contacts and H-bonds.
        var fingerprint: Fingerprint.Result?
        var slots: (slot: [Int], residues: [Fingerprint.Residue])?
        if let names = frame.label("name"), let resnames = frame.label("resname"),
           let s = Fingerprint.residueSlots(frame: frame, inA: inA, inB: inB) {
            slots = s
            var cuts = Fingerprint.Cutoffs()
            cuts.saltBridge = params.saltBridgeCutoff
            let fpList = params.contactCutoff >= cuts.hydrophobic
                ? list : context.neighborList(for: frame, cutoff: cuts.hydrophobic)
            if fpList.wasCancelled { throw AnalysisError.cancelled }
            fingerprint = try Fingerprint.analyze(
                frame: frame, inA: inA, inB: inB, residueSlot: s.slot, residues: s.residues,
                names: names.map { $0.trimmingCharacters(in: .whitespaces) },
                resnames: resnames.map { $0.trimmingCharacters(in: .whitespaces).uppercased() },
                hbondPairs: hbondPairs, list: fpList, cuts: cuts, isCancelled: context.isCancelled)
        } else {
            notes.append("Interaction fingerprint needs `name` (PDB atom name) and `resname` labels; "
                         + "this frame has none, so only contacts and H-bonds are reported.")
        }

        // 6. Side files: MM/GBSA and per-residue interaction energies ----------
        var mmgbsa: MMGBSATable?
        var interactionEnergy: InteractionEnergyTable?
        if let source = context.sourceURL {
            if let url = MMGBSATable.locate(near: source), let t = try? MMGBSATable.load(url), !t.isEmpty {
                mmgbsa = t
                notes.append("MM/GBSA read from \(url.lastPathComponent) (\(t.rows.count) frames) beside the trajectory. "
                             + MMGBSATable.caveat)
            }
            if let url = InteractionEnergyTable.locate(near: source),
               let t = try? InteractionEnergyTable.load(url), !t.isEmpty {
                interactionEnergy = t
                notes.append("Per-residue interaction energies read from \(url.lastPathComponent) "
                             + "(vacuum MM ligand–residue vdW + electrostatics, written by mmgbsa.py).")
            }
        }

        // 7. Result ------------------------------------------------------------
        var summary: [SummaryRow] = [
            SummaryRow("Group A", "\(selA!.describedText) (\(groupA.count) atoms)"),
            SummaryRow("Group B", "\(selB!.describedText) (\(groupB.count) atoms)"),
            SummaryRow("Contacts", "\(contacts)", unit: "< \(fmt(params.contactCutoff)) Å")
        ]
        summary += hbondRows
        if let fp = fingerprint {
            summary.append(SummaryRow("Salt bridges", "\(fp.saltBridges)",
                                      unit: "N–O < \(fmt(params.saltBridgeCutoff)) Å"))
            summary.append(SummaryRow("π-stacking", "\(fp.faceToFace + fp.tShaped)",
                                      unit: "\(fp.faceToFace) face-to-face, \(fp.tShaped) T-shaped"))
            summary.append(SummaryRow("Cation–π", "\(fp.cationPi)"))
            summary.append(SummaryRow("Hydrophobic contacts", "\(fp.hydrophobic)", unit: "residue pairs"))
        }
        summary.append(SummaryRow("COM–COM distance", fmt(comDistance), unit: "Å"))
        summary.append(SummaryRow("Minimum interface distance",
                                  minDistance < .greatestFiniteMagnitude ? fmt(minDistance) : "n/a",
                                  unit: "Å"))
        if let stats = mmgbsa?.statistics, let here = mmgbsa?.row(nearestTo: context.frameIndex) {
            let spread = stats.sd.map { "mean \(fmt(stats.mean)) ± \(fmt($0))" } ?? "mean \(fmt(stats.mean))"
            summary.append(SummaryRow("MM/GBSA ΔG_bind", "\(fmt(here.dG)) · \(spread)",
                                      unit: "kJ/mol, this frame · over \(mmgbsa!.rows.count) frames"))
            summary.append(SummaryRow("MM/GBSA terms",
                                      "vdW \(fmt(here.vdw)) · elec \(fmt(here.elec)) · solv \(fmt(here.solvBind))",
                                      unit: "kJ/mol"))
        }
        for (key, count) in residueContacts.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).prefix(5) {
            summary.append(SummaryRow(key, "\(count)", unit: "contacts"))
        }
        summary += interactionTable(fingerprint: fingerprint, residueContacts: residueContacts)
        summary += energyTable(interactionEnergy, frameIndex: context.frameIndex)

        // 8. Trajectory level: occupancy, lifetimes, contact frequency ----------
        if params.lifetimes, let trajectory = context.trajectory, trajectory.count > 1 {
            var interval = 1.0, unitName = "frames"
            if let source = context.sourceURL, let cfgURL = RunConfig.locate(near: source),
               let cfg = try? RunConfig.load(cfgURL), let dt = cfg.reportInterval_ps, dt > 0 {
                interval = dt
                unitName = "ps"
            }
            let tf = try TrajectoryFingerprint.cached(
                trajectory: trajectory, generation: context.trajectoryGeneration,
                selA: selA!, selB: selB!, params: params,
                interval: interval, unit: unitName, isCancelled: context.isCancelled)
            summary.append(SummaryRow("Trajectory", "\(tf.frameCount) frames",
                                      unit: unitName == "ps" ? "\(fmt(interval)) ps apart" : "interval unknown"))
            for s in tf.hbonds.prefix(10) {
                summary.append(SummaryRow("H-bond \(s.label)",
                                          "occupancy \(String(format: "%.2f", s.occupancy)) · lifetime \(fmt(s.meanLifetime)) \(tf.unit)",
                                          unit: "\(s.events) event\(s.events == 1 ? "" : "s")"))
            }
            for r in tf.residues.prefix(8) {
                summary.append(SummaryRow("\(r.label) (contact frequency)",
                                          String(format: "%.2f", r.frequency), unit: "of frames"))
            }
            if unitName == "frames" {
                notes.append("No report interval known (no config.json beside the trajectory): H-bond lifetimes are in frames.")
            }
        }

        // 9. Per-atom field ----------------------------------------------------
        let field: PerAtomField
        if params.quantity == .interactions, let fp = fingerprint {
            let values = (0..<n).map { i -> Float in
                let c = fp.classes[i]
                if c != .none { return Float(c.rawValue) }
                return Float(contactA[i] ? 1 : (contactB[i] ? 2 : 0))
            }
            field = PerAtomField(name: "interaction", values: values,
                                 palette: .categorical(InteractionClass.legend),
                                 legendTitle: "Interaction")
        } else {
            if params.quantity == .interactions {
                notes.append("Interaction field asked for but unavailable; showing contacts.")
            }
            let values = (0..<n).map { Float(contactA[$0] ? 1 : (contactB[$0] ? 2 : 0)) }
            field = PerAtomField(name: "contact", values: values,
                                 palette: .categorical([("no contact", RGB(0.6, 0.6, 0.6)),
                                                        ("A in contact", RGB(1.0, 0.55, 0.1)),
                                                        ("B in contact", RGB(0.2, 0.8, 1.0))]),
                                 legendTitle: "Contacts")
        }
        _ = slots
        return ToolResult(summary: summary, field: field, scalar: Double(contacts), notes: notes)
    }

    /// Top-8 group-A residues by total interaction count, one row each. The
    /// plain contact rows above stay as they were — this table answers "held by
    /// what", not "how close".
    static func interactionTable(fingerprint: Fingerprint.Result?,
                                 residueContacts: [String: Int]) -> [SummaryRow] {
        guard let fp = fingerprint, fp.any else { return [] }
        var merged = fp.perResidue
        for (key, count) in residueContacts {
            var t = merged[key] ?? ResidueInteractions()
            t.contacts = count
            merged[key] = t
        }
        let ranked = merged.sorted {
            $0.value.total == $1.value.total ? $0.key < $1.key : $0.value.total > $1.value.total
        }
        return ranked.prefix(8).map { key, t in
            SummaryRow("\(key) (interactions)",
                       "contacts \(t.contacts) · H-bonds \(t.hbonds) · salt \(t.saltBridges) · π \(t.pi) · φ \(t.hydrophobic)")
        }
    }

    /// ΔE_vdw / ΔE_elec per residue for the nearest MM/GBSA frame, strongest
    /// |E| first — the energetic version of the contact map.
    static func energyTable(_ table: InteractionEnergyTable?, frameIndex: Int) -> [SummaryRow] {
        guard let table, let (frame, rows) = table.rows(nearestTo: frameIndex), !rows.isEmpty else { return [] }
        let ranked = rows.sorted { abs($0.total) == abs($1.total) ? $0.displayKey < $1.displayKey
                                                                 : abs($0.total) > abs($1.total) }
        return ranked.prefix(8).map { r in
            SummaryRow("\(r.displayKey) (ΔE)",
                       "vdW \(fmt(r.vdw)) · elec \(fmt(r.elec)) · total \(fmt(r.total))",
                       unit: "kJ/mol, frame \(frame)")
        }
    }

    // MARK: - Helpers

    private static func fmt(_ x: Double) -> String { String(format: "%.3f", x) }

    /// "resname resid" per atom, or nil when the frame cannot name residues.
    /// `resid` is a string label in extended XYZ but an integer column in some
    /// dumps, so both are accepted.
    private static func residueLabels(_ frame: Frame, params: Parameters,
                                      notes: inout [String]) -> [String]? {
        guard params.perResidue else { return nil }
        guard let resname = frame.label("resname") else {
            notes.append("Per-residue breakdown needs resname and resid; this frame has no resname label.")
            return nil
        }
        // Chain-qualified ("A:ALA 1") whenever the frame carries a chain label: both chains
        // of a complex can have an ALA 1, and downstream tools (DFT motif clusters) map rows
        // back to atoms by this key.
        let chain = frame.label("chain")
        func key(_ i: Int, _ rid: String) -> String {
            if let chain, !chain[i].isEmpty { return "\(chain[i]):\(resname[i]) \(rid)" }
            return "\(resname[i]) \(rid)"
        }
        if let resid = frame.label("resid") {
            return (0..<frame.count).map { key($0, resid[$0]) }
        }
        if let resid = frame.column("resid") {
            return (0..<frame.count).map { key($0, "\(Int(resid[$0]))") }
        }
        notes.append("Per-residue breakdown needs resname and resid; this frame has no resid.")
        return nil
    }

    /// Baker & Hubbard (1984): a donor N/O carrying a hydrogen, an acceptor N/O
    /// of the other group within `hbondDistance`, and a D–H···A angle (measured
    /// at the hydrogen) above `hbondAngle`. A donor–acceptor pair counts once
    /// however many of the donor's hydrogens satisfy it.
    static func hydrogenBondPairs(frame: Frame, donors: [Int], acceptorMask: [Bool],
                                  elements: [String], isPolar: [Bool],
                                  hbList: NeighborList, bondList: NeighborList,
                                  params: Parameters) -> [(donor: Int, acceptor: Int)] {
        let pos = frame.positions
        let box = frame.box
        let cosLimit = cos(params.hbondAngle * .pi / 180)
        var found: [(donor: Int, acceptor: Int)] = []
        for d in donors where isPolar[d] {
            var hydrogens: [Int] = []
            bondList.forEachNeighbor(of: d) { j, dist in
                if (elements[j] == "H" || elements[j] == "D") && dist <= donorBondCutoff { hydrogens.append(j) }
            }
            guard !hydrogens.isEmpty else { continue }
            var counted = Set<Int>()
            hbList.forEachNeighbor(of: d) { acceptor, dist in
                guard acceptorMask[acceptor], isPolar[acceptor],
                      dist < params.hbondDistance, !counted.contains(acceptor) else { return }
                for h in hydrogens {
                    var toDonor = pos[d] - pos[h]
                    var toAcceptor = pos[acceptor] - pos[h]
                    if let box { toDonor = box.minimumImage(toDonor); toAcceptor = box.minimumImage(toAcceptor) }
                    let n1 = (toDonor.x * toDonor.x + toDonor.y * toDonor.y + toDonor.z * toDonor.z).squareRoot()
                    let n2 = (toAcceptor.x * toAcceptor.x + toAcceptor.y * toAcceptor.y + toAcceptor.z * toAcceptor.z).squareRoot()
                    guard n1 > 0, n2 > 0 else { continue }
                    let dot = toDonor.x * toAcceptor.x + toDonor.y * toAcceptor.y + toDonor.z * toAcceptor.z
                    // angle > limit  ⇔  cos(angle) < cos(limit)
                    if dot / (n1 * n2) < cosLimit {
                        counted.insert(acceptor)
                        found.append((donor: d, acceptor: acceptor))
                        break
                    }
                }
            }
        }
        return found
    }
}
