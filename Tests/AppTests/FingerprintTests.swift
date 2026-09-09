import XCTest
@testable import LAMMPSCore

/// Interaction fingerprints (GJOB-146): every geometry here is hand-placed so
/// the criterion under test is the only thing that can decide the answer.
final class FingerprintTests: XCTestCase {

    // MARK: - Frame building

    struct At {
        let element: String, name: String, resname: String, resid: String, chain: String
        let x: Double, y: Double, z: Double
        init(_ element: String, _ name: String, _ resname: String, _ resid: String, _ chain: String,
             _ x: Double, _ y: Double, _ z: Double) {
            self.element = element; self.name = name; self.resname = resname
            self.resid = resid; self.chain = chain; self.x = x; self.y = y; self.z = z
        }
    }

    private func frame(_ rows: [At]) -> Frame {
        Frame(atoms: rows.map { Arv(element: $0.element, x: $0.x, y: $0.y, z: $0.z) },
              labels: ["chain": rows.map(\.chain), "resname": rows.map(\.resname),
                       "resid": rows.map(\.resid), "name": rows.map(\.name)])
    }

    /// A planar six-ring of radius 1.39 Å, in ring-bond order, in the plane
    /// spanned by `u` and `v` around `center`.
    private func ring(_ resname: String, _ resid: String, _ chain: String,
                      center: SIMD3<Double>, u: SIMD3<Double>, v: SIMD3<Double>) -> [At] {
        let names = ["CG", "CD1", "CE1", "CZ", "CE2", "CD2"]
        return names.enumerated().map { k, name in
            let a = Double(k) * .pi / 3
            let p = center + u * (1.39 * cos(a)) + v * (1.39 * sin(a))
            return At("C", name, resname, resid, chain, p.x, p.y, p.z)
        }
    }

    private static let chains = AdhesionTool.Parameters(groupA: .label(name: "chain", values: ["A"]),
                                                        groupB: .label(name: "chain", values: ["B"]))
    private func run(_ rows: [At], _ params: AdhesionTool.Parameters = chains,
                     context: AnalysisContext = AnalysisContext()) throws -> ToolResult {
        try AdhesionTool.analyze(frame: frame(rows), context: context, params: params)
    }
    private func value(_ r: ToolResult, _ label: String) -> String? {
        r.summary.first { $0.label == label }?.value
    }
    private func unit(_ r: ToolResult, _ label: String) -> String? {
        r.summary.first { $0.label == label }?.unit
    }

    // MARK: - Salt bridges

    func testSaltBridgeLysineGlutamate() throws {
        // LYS NZ (A) 3.5 Å from GLU OE1 (B): inside the 4.0 Å criterion.
        let rows = [At("N", "NZ", "LYS", "1", "A", 0, 0, 0),
                    At("C", "CE", "LYS", "1", "A", -1.5, 0, 0),
                    At("O", "OE1", "GLU", "10", "B", 3.5, 0, 0),
                    At("C", "CD", "GLU", "10", "B", 4.6, 0, 0)]
        let r = try run(rows)
        XCTAssertEqual(value(r, "Salt bridges"), "1")
        XCTAssertEqual(unit(r, "Salt bridges"), "N–O < 4.000 Å")
        XCTAssertEqual(value(r, "A:LYS 1 (interactions)"),
                       "contacts 1 · H-bonds 0 · salt 1 · π 0 · φ 0")

        // Pull them apart past the cutoff: the bridge, and only the bridge, goes.
        var far = rows
        far[2] = At("O", "OE1", "GLU", "10", "B", 4.2, 0, 0)
        XCTAssertEqual(value(try run(far), "Salt bridges"), "0")

        // Same pair, one cutoff wider — the parameter is live.
        var wide = Self.chains
        wide.saltBridgeCutoff = 4.5
        XCTAssertEqual(value(try run(far, wide), "Salt bridges"), "1")
    }

    func testInteractionFieldIsCategorical() throws {
        let rows = [At("N", "NZ", "LYS", "1", "A", 0, 0, 0),
                    At("C", "CE", "LYS", "1", "A", -1.5, 0, 0),
                    At("O", "OE1", "GLU", "10", "B", 3.5, 0, 0),
                    At("C", "CD", "GLU", "10", "B", 4.6, 0, 0)]
        var params = Self.chains
        params.quantity = .interactions
        let r = try run(rows, params)
        XCTAssertEqual(r.field?.name, "interaction")
        XCTAssertEqual(r.field?.legendTitle, "Interaction")
        // NZ and OE1 are the salt bridge (4); CE is a plain A contact only if it
        // is inside 4.5 Å of B — it is not; CD is 4.6 Å from NZ, so nothing.
        XCTAssertEqual(r.field?.values, [4, 0, 4, 0])
        if case .categorical(let entries)? = r.field?.palette {
            XCTAssertEqual(entries.count, 7)
            XCTAssertEqual(entries[4].label, "salt bridge")
            XCTAssertEqual(entries[6].label, "hydrophobic")
        } else { XCTFail("categorical palette expected") }

        // The default is still the contacts field, byte for byte.
        let plain = try run(rows)
        XCTAssertEqual(plain.field?.name, "contact")
        XCTAssertEqual(plain.field?.values, [1, 0, 2, 0])
    }

    // MARK: - π-stacking and cation–π

    func testFaceToFaceStack() throws {
        // Two parallel rings, centroids 3.8 Å apart, no lateral offset.
        let x = SIMD3<Double>(1, 0, 0), y = SIMD3<Double>(0, 1, 0), z = SIMD3<Double>(0, 0, 1)
        let rows = ring("PHE", "1", "A", center: .init(0, 0, 0), u: x, v: y)
                 + ring("TYR", "10", "B", center: .init(0, 0, 3.8), u: x, v: y)
        let r = try run(rows)
        XCTAssertEqual(value(r, "π-stacking"), "1")
        XCTAssertEqual(unit(r, "π-stacking"), "1 face-to-face, 0 T-shaped")

        // Slide one ring 3 Å sideways: still parallel and within 5.5 Å of
        // centroid, but the offset criterion (2 Å) rejects it, and 90° it is not.
        let slid = ring("PHE", "1", "A", center: .init(0, 0, 0), u: x, v: y)
                 + ring("TYR", "10", "B", center: .init(3.0, 0, 3.8), u: x, v: y)
        XCTAssertEqual(value(try run(slid), "π-stacking"), "0")

        // Push them past 5.5 Å apart: nothing at all.
        let far = ring("PHE", "1", "A", center: .init(0, 0, 0), u: x, v: y)
                + ring("TYR", "10", "B", center: .init(0, 0, 6.0), u: x, v: y)
        XCTAssertEqual(value(try run(far), "π-stacking"), "0")
        _ = z
    }

    func testTShapedStack() throws {
        // Ring A in the xy-plane, ring B in the xz-plane 5.0 Å above it:
        // normals are 90° apart, so this is the edge-to-face geometry.
        let x = SIMD3<Double>(1, 0, 0), y = SIMD3<Double>(0, 1, 0), z = SIMD3<Double>(0, 0, 1)
        let rows = ring("PHE", "1", "A", center: .init(0, 0, 0), u: x, v: y)
                 + ring("PHE", "10", "B", center: .init(0, 0, 5.0), u: x, v: z)
        let r = try run(rows)
        XCTAssertEqual(value(r, "π-stacking"), "1")
        XCTAssertEqual(unit(r, "π-stacking"), "0 face-to-face, 1 T-shaped")
    }

    func testCationPi() throws {
        // LYS NZ 4.0 Å above a PHE ring centroid: inside the 6.0 Å criterion.
        let x = SIMD3<Double>(1, 0, 0), y = SIMD3<Double>(0, 1, 0)
        let rows = ring("PHE", "1", "A", center: .init(0, 0, 0), u: x, v: y)
                 + [At("N", "NZ", "LYS", "10", "B", 0, 0, 4.0),
                    At("C", "CE", "LYS", "10", "B", 0, 0, 5.5)]
        let r = try run(rows)
        XCTAssertEqual(value(r, "Cation–π"), "1")
        XCTAssertEqual(value(r, "π-stacking"), "0")           // one ring, no stack
        XCTAssertTrue(value(r, "A:PHE 1 (interactions)")!.contains("π 1"))

        // 7 Å up is out of range.
        var far = rows
        far[6] = At("N", "NZ", "LYS", "10", "B", 0, 0, 7.0)
        XCTAssertEqual(value(try run(far), "Cation–π"), "0")
    }

    // MARK: - Hydrophobic packing

    func testHydrophobicContactCountedPerResiduePair() throws {
        // LEU (A) and VAL (B) side-chain carbons at 3.8 Å — one residue pair,
        // however many atom pairs qualify.
        let rows = [At("C", "CD1", "LEU", "1", "A", 0, 0, 0),
                    At("C", "CD2", "LEU", "1", "A", 0, 1.5, 0),
                    At("C", "CG1", "VAL", "10", "B", 3.8, 0, 0),
                    At("C", "CG2", "VAL", "10", "B", 3.8, 1.5, 0)]
        let r = try run(rows)
        XCTAssertEqual(value(r, "Hydrophobic contacts"), "1")
        XCTAssertEqual(unit(r, "Hydrophobic contacts"), "residue pairs")
        XCTAssertTrue(value(r, "A:LEU 1 (interactions)")!.hasSuffix("φ 1"))

        // Backbone carbons of the same residues do not count as packing.
        let backbone = [At("C", "CA", "LEU", "1", "A", 0, 0, 0),
                        At("C", "C", "LEU", "1", "A", 0, 1.5, 0),
                        At("C", "CA", "VAL", "10", "B", 3.8, 0, 0),
                        At("C", "C", "VAL", "10", "B", 3.8, 1.5, 0)]
        XCTAssertEqual(value(try run(backbone), "Hydrophobic contacts"), "0")

        // Polar residues are not hydrophobic however close their carbons get.
        let polar = [At("C", "CB", "SER", "1", "A", 0, 0, 0),
                     At("C", "CB", "THR", "10", "B", 3.8, 0, 0)]
        XCTAssertEqual(value(try run(polar), "Hydrophobic contacts"), "0")
    }

    func testFingerprintNeedsAtomNames() throws {
        // The same LEU/VAL pair without a `name` column: contacts survive, the
        // fingerprint is withheld and says why rather than guessing.
        let rows = [At("C", "CD1", "LEU", "1", "A", 0, 0, 0),
                    At("C", "CG1", "VAL", "10", "B", 3.8, 0, 0)]
        var f = frame(rows)
        f.labels["name"] = nil
        let r = try AdhesionTool.analyze(frame: f, context: AnalysisContext(), params: Self.chains)
        XCTAssertEqual(value(r, "Contacts"), "1")
        XCTAssertNil(value(r, "Hydrophobic contacts"))
        XCTAssertTrue(r.notes.contains { $0.contains("PDB atom name") })
    }

    // MARK: - Trajectory: occupancy and lifetimes

    /// N–H (chain A) donating to O (chain B). The H-bond is on in frames
    /// 0, 1, 2 and 4 and off in frame 3 → occupancy 0.8, runs of 3 and 1,
    /// mean lifetime (3 + 1) / 2 = 2 frames.
    func testHBondOccupancyAndLifetime() throws {
        let distances = [3.0, 3.0, 3.0, 4.2, 3.0]
        let trajectory: Trajectory = distances.map { d in
            frame([At("N", "N", "ALA", "1", "A", 0, 0, 0),
                   At("H", "H", "ALA", "1", "A", 0, 0, 1.0),
                   At("O", "O", "GLY", "10", "B", 0, 0, d)])
        }
        let context = AnalysisContext(frameIndex: 0, trajectory: trajectory, trajectoryGeneration: 0)
        let r = try AdhesionTool.analyze(frame: trajectory[0], context: context, params: Self.chains)

        XCTAssertEqual(value(r, "H-bonds"), "1")                       // this frame
        XCTAssertEqual(value(r, "Trajectory"), "5 frames")
        XCTAssertEqual(value(r, "H-bond A:ALA 1 N → B:GLY 10 O"),
                       "occupancy 0.80 · lifetime 2.000 frames")
        XCTAssertEqual(unit(r, "H-bond A:ALA 1 N → B:GLY 10 O"), "2 events")
        // N···O stays inside the 4.5 Å contact cutoff even in frame 3.
        XCTAssertEqual(value(r, "A:ALA 1 (contact frequency)"), "1.00")
        XCTAssertTrue(r.notes.contains { $0.contains("lifetimes are in frames") })

        // Turned off, the trajectory is never walked.
        var noLifetimes = Self.chains
        noLifetimes.lifetimes = false
        let quiet = try AdhesionTool.analyze(frame: trajectory[0], context: context, params: noLifetimes)
        XCTAssertNil(value(quiet, "Trajectory"))
    }

    func testTrajectoryFingerprintIsCancellable() {
        let trajectory: Trajectory = (0..<5).map { _ in
            frame([At("N", "N", "ALA", "1", "A", 0, 0, 0),
                   At("O", "O", "GLY", "10", "B", 0, 0, 3.0)])
        }
        XCTAssertThrowsError(try TrajectoryFingerprint.compute(
            trajectory: trajectory, selA: .label(name: "chain", values: ["A"]),
            selB: .label(name: "chain", values: ["B"]), params: .init(),
            interval: 1, unit: "frames", isCancelled: { true })) { error in
            XCTAssertEqual(error as? AnalysisError, .cancelled)
        }
    }

    // MARK: - MM/GBSA side files

    private func writeSideFiles(_ dir: URL, newline: String = "\n") throws {
        let energies = ["frame,resname,resid,chain,e_vdw_kJ_mol,e_elec_kJ_mol",
                        "0,ASP,3,A,-2.0,-20.0",
                        "0,TRP,6,A,-8.0,-1.0",
                        "1,ASP,3,A,-2.5,-18.0",
                        "1,TRP,6,A,-9.0,-1.5"].joined(separator: newline) + newline
        let mmgbsa = ["frame,time_ps,dG_bind_kJ_mol,e_vdw,e_elec,g_solv_complex,g_solv_receptor,g_solv_ligand",
                      "0,0.0,-40.0,-30.0,-50.0,-100.0,-60.0,-80.0",
                      "1,5.0,-50.0,-35.0,-55.0,-110.0,-60.0,-80.0"].joined(separator: newline) + newline
        try energies.write(to: dir.appendingPathComponent("interaction_energy.csv"), atomically: true, encoding: .utf8)
        try mmgbsa.write(to: dir.appendingPathComponent("mmgbsa.csv"), atomically: true, encoding: .utf8)
    }

    func testMMGBSASideFilesReachTheSummary() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fingerprint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSideFiles(dir)

        let rows = [At("O", "OD1", "ASP", "3", "A", 0, 0, 0),
                    At("C", "CG", "ASP", "3", "A", -1.5, 0, 0),
                    At("N", "NZ", "LYS", "10", "B", 3.0, 0, 0)]
        let context = AnalysisContext(frameIndex: 0,
                                      sourceURL: dir.appendingPathComponent("trajectory_seed1.xyz"))
        let r = try AdhesionTool.analyze(frame: frame(rows), context: context, params: Self.chains)

        // ΔG for the frame the viewer is on, plus the spread over the file.
        XCTAssertEqual(value(r, "MM/GBSA ΔG_bind"), "-40.000 · mean -45.000 ± 7.071")
        XCTAssertEqual(unit(r, "MM/GBSA ΔG_bind"), "kJ/mol, this frame · over 2 frames")
        XCTAssertEqual(value(r, "MM/GBSA terms"), "vdW -30.000 · elec -50.000 · solv 40.000")
        // Per-residue ΔE, strongest |E| first: ASP (−22) before TRP (−9).
        XCTAssertEqual(value(r, "A:ASP 3 (ΔE)"), "vdW -2.000 · elec -20.000 · total -22.000")
        XCTAssertEqual(unit(r, "A:ASP 3 (ΔE)"), "kJ/mol, frame 0")
        let order = r.summary.compactMap { $0.label.hasSuffix("(ΔE)") ? $0.label : nil }
        XCTAssertEqual(order, ["A:ASP 3 (ΔE)", "A:TRP 6 (ΔE)"])
        XCTAssertTrue(r.notes.contains { $0.contains("rank-order estimate") })
        XCTAssertTrue(r.notes.contains { $0.contains("mmgbsa.py") })

        // Frame 1 picks up the other row of both files.
        let later = try AdhesionTool.analyze(
            frame: frame(rows),
            context: AnalysisContext(frameIndex: 1, sourceURL: dir.appendingPathComponent("t.xyz")),
            params: Self.chains)
        XCTAssertEqual(value(later, "MM/GBSA ΔG_bind"), "-50.000 · mean -45.000 ± 7.071")
        XCTAssertEqual(value(later, "A:ASP 3 (ΔE)"), "vdW -2.500 · elec -18.000 · total -20.500")
    }

    func testSideFileParsersAreCRLFSafe() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fingerprint-crlf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeSideFiles(dir, newline: "\r\n")            // what Python's csv module writes

        let energies = try InteractionEnergyTable.load(dir.appendingPathComponent("interaction_energy.csv"))
        XCTAssertEqual(energies.rows.count, 4)
        XCTAssertEqual(energies.frames, [0, 1])
        XCTAssertEqual(energies.rows[0].displayKey, "A:ASP 3")
        XCTAssertEqual(energies.rows[0].chain, "A")
        XCTAssertEqual(energies.rows[0].total, -22.0, accuracy: 1e-9)
        // A frame with no row of its own falls to the nearest one that has.
        XCTAssertEqual(energies.rows(nearestTo: 9)?.frame, 1)

        let mmgbsa = try MMGBSATable.load(dir.appendingPathComponent("mmgbsa.csv"))
        XCTAssertEqual(mmgbsa.rows.count, 2)
        XCTAssertEqual(mmgbsa.rows[0].solvBind, 40.0, accuracy: 1e-9)
        XCTAssertEqual(mmgbsa.statistics?.mean ?? 0, -45.0, accuracy: 1e-9)
        XCTAssertEqual(mmgbsa.statistics?.sd ?? 0, 7.0710678, accuracy: 1e-6)
        XCTAssertEqual(mmgbsa.row(nearestTo: 7)?.dG, -50.0)

        // A file that is not ours parses to nothing rather than to garbage.
        XCTAssertTrue(MMGBSATable.parse("a,b\n1,2\n").isEmpty)
        XCTAssertTrue(InteractionEnergyTable.parse("").isEmpty)
    }

    func testSideFileSearchLooksWhereTheProtocolWrites() {
        let run = URL(fileURLWithPath: "/tmp/run-42/results-1/trajectory.xyz")
        let paths = SideFile.searchLocations("mmgbsa.csv", near: run).map(\.path)
        XCTAssertEqual(paths.first, "/tmp/run-42/results-1/mmgbsa.csv")
        XCTAssertTrue(paths.contains("/tmp/run-42/mmgbsa.csv"))
    }

    // MARK: - Parameters

    func testParametersDecodeFromPreFingerprintJSON() throws {
        let old = #"{"contactCutoff":5.0,"hbondDistance":3.2,"hbondAngle":140,"perResidue":false}"#
        let p = try JSONDecoder().decode(AdhesionTool.Parameters.self, from: Data(old.utf8))
        XCTAssertEqual(p.contactCutoff, 5.0)
        XCTAssertEqual(p.perResidue, false)
        XCTAssertEqual(p.saltBridgeCutoff, 4.0)          // new fields take their defaults
        XCTAssertEqual(p.quantity, .contacts)
        XCTAssertEqual(p.lifetimes, true)
        XCTAssertEqual(try JSONDecoder().decode(AdhesionTool.Parameters.self,
                                                from: JSONEncoder().encode(p)), p)
    }
}
