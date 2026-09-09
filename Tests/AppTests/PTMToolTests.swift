import XCTest
@testable import LAMMPSCore

final class PTMToolTests: XCTestCase {

    private let degree = Double.pi / 180

    private func run(_ frame: Frame, _ params: PTMTool.Parameters = .init(),
                     context: AnalysisContext = AnalysisContext()) throws -> ToolResult {
        try PTMTool.analyze(frame: frame, context: context, params: params)
    }

    private func fraction(_ result: ToolResult, _ c: PTMClass) -> Double {
        guard let values = result.field?.values, !values.isEmpty else { return 0 }
        return Double(values.filter { $0 == Float(c.rawValue) }.count) / Double(values.count)
    }

    private func summary(_ result: ToolResult, _ label: String) -> String? {
        result.summary.first { $0.label == label }?.value
    }

    // MARK: - Quaternions and Horn's method

    func testQuaternionRotationMatchesItsMatrix() {
        let q = Quat.axisAngle(axis: SIMD3(1, 2, 3), radians: 37 * degree)
        let v = SIMD3(0.3, -1.7, 2.2)
        let byQuat = q.rotate(v), byMatrix = q.matrix * v
        XCTAssertEqual(byQuat.x, byMatrix.x, accuracy: 1e-12)
        XCTAssertEqual(byQuat.y, byMatrix.y, accuracy: 1e-12)
        XCTAssertEqual(byQuat.z, byMatrix.z, accuracy: 1e-12)
        XCTAssertEqual((byQuat * byQuat).sum().squareRoot(), (v * v).sum().squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(q.angle, 37 * degree, accuracy: 1e-12)
    }

    func testHornRecoversAKnownRotation() {
        let solver = HornSolver()
        let a: [SIMD3<Double>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1),
                                  SIMD3(1, 1, 0), SIMD3(-1, 0.5, 2)]
        for (axis, degrees) in [(SIMD3(0.0, 0, 1), 20.0), (SIMD3(1.0, 1, 0), 95.0),
                                (SIMD3(1.0, 2, 3), 179.0), (SIMD3(0.0, 1, 0), 0.4)] {
            let truth = Quat.axisAngle(axis: axis, radians: degrees * degree)
            let b = a.map { truth.rotate($0) }
            let found = solver.rotation(from: a, to: b, count: a.count)
            XCTAssertEqual(LatticeSymmetry.disorientation(truth, found, symmetry: .none), 0,
                           accuracy: 1e-9, "\(degrees)° about \(axis)")
        }
    }

    func testHornFromTwoVectorsIsAlreadyExact() {
        let solver = HornSolver()
        let truth = Quat.axisAngle(axis: SIMD3(2, -1, 3), radians: 44 * degree)
        let a: [SIMD3<Double>] = [SIMD3(1, 1, 0), SIMD3(0, 1, 1)]
        let b = a.map { truth.rotate($0) }
        let found = solver.rotation(from: a, to: b, count: 2)
        XCTAssertEqual(LatticeSymmetry.disorientation(truth, found, symmetry: .none), 0, accuracy: 1e-9)
    }

    func testDisorientationIsReducedByTheLatticeSymmetry() {
        let z90 = Quat.axisAngle(axis: SIMD3(0, 0, 1), radians: 90 * degree)
        XCTAssertEqual(LatticeSymmetry.disorientation(.identity, z90, symmetry: .none),
                       90 * degree, accuracy: 1e-9)
        XCTAssertEqual(LatticeSymmetry.disorientation(.identity, z90, symmetry: .cubic),
                       0, accuracy: 1e-9)
        let triad = Quat.axisAngle(axis: SIMD3(1, 1, 1), radians: 120 * degree)
        XCTAssertEqual(LatticeSymmetry.disorientation(.identity, triad, symmetry: .cubic),
                       0, accuracy: 1e-9)
        let small = Quat.axisAngle(axis: SIMD3(0, 0, 1), radians: 3 * degree)
        XCTAssertEqual(LatticeSymmetry.disorientation(.identity, small, symmetry: .cubic),
                       3 * degree, accuracy: 1e-9)
        let z60 = Quat.axisAngle(axis: SIMD3(0, 0, 1), radians: 60 * degree)
        XCTAssertEqual(LatticeSymmetry.disorientation(.identity, z60, symmetry: .hexagonal),
                       0, accuracy: 1e-9)
        XCTAssertEqual(LatticeSymmetry.disorientation(.identity, z90, symmetry: .hexagonal),
                       30 * degree, accuracy: 1e-9)
    }

    // MARK: - Perfect lattices

    func testPerfectFCCIsOneGrainOfFCC() throws {
        let r = try run(Fixtures.fcc(cells: 4), .init(templates: ["fcc", "hcp", "bcc", "ico"]))
        XCTAssertEqual(fraction(r, .fcc), 1.0, accuracy: 1e-9)
        XCTAssertEqual(r.scalar!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(Double(summary(r, "Mean RMSD (matched)")!)!, 0, accuracy: 1e-6)
        XCTAssertEqual(summary(r, "Grain-boundary fraction"), "0.0")
        XCTAssertEqual(summary(r, "Grains"), "1")
        XCTAssertEqual(r.field?.legendTitle, "Structure (PTM)")
        if case .categorical(let entries)? = r.field?.palette {
            XCTAssertEqual(entries.count, 6)
            XCTAssertEqual(entries[1].label, "FCC")
            XCTAssertEqual(entries[1].color, RGB(0.4, 1.0, 0.4))
            XCTAssertEqual(entries[5].label, "Simple cubic")
        } else { XCTFail("categorical palette expected") }
    }

    func testPerfectBCCIsOneGrainOfBCC() throws {
        let r = try run(Fixtures.bcc(cells: 4), .init(templates: ["fcc", "bcc"]))
        XCTAssertEqual(fraction(r, .bcc), 1.0, accuracy: 1e-9)
        XCTAssertEqual(Double(summary(r, "Mean RMSD (matched)")!)!, 0, accuracy: 1e-6)
        XCTAssertEqual(summary(r, "Grains"), "1")
        XCTAssertEqual(summary(r, "Grain-boundary fraction"), "0.0")
    }

    func testPerfectHCPIsOneGrainOfHCP() throws {
        let r = try run(Fixtures.hcp(cells: 3), .init(templates: ["fcc", "hcp"]))
        XCTAssertEqual(fraction(r, .hcp), 1.0, accuracy: 1e-9)
        XCTAssertEqual(Double(summary(r, "Mean RMSD (matched)")!)!, 0, accuracy: 1e-6)
        XCTAssertEqual(summary(r, "Grains"), "1")
        XCTAssertEqual(summary(r, "Grain-boundary fraction"), "0.0")
    }

    // MARK: - Orientation

    func testRotatedFCCRecoversTheRotation() throws {
        let truth = Quat.axisAngle(axis: SIMD3(1, 1, 0), radians: 20 * degree)
        let frame = Self.rotatedFCC(rotation: truth, cells: 4)
        let params = PTMTool.Parameters(quantity: "orientation", templates: ["fcc"])
        let context = AnalysisContext()
        let r = try run(frame, params, context: context)
        XCTAssertNotNil(r.field)

        // Re-run the matcher on the most interior atom and compare orientations.
        let interior = Fixtures.atom(frame)
        let found = try Self.orientation(of: interior, in: frame, context: context)
        XCTAssertEqual(LatticeSymmetry.disorientation(truth, found, symmetry: .cubic) / degree, 0,
                       accuracy: 0.5)

        // The unrotated block must come back at the identity, modulo symmetry.
        let plain = Fixtures.fcc(cells: 4)
        let identityFound = try Self.orientation(of: Fixtures.atom(plain), in: plain,
                                                 context: AnalysisContext())
        XCTAssertEqual(LatticeSymmetry.disorientation(.identity, identityFound, symmetry: .cubic) / degree,
                       0, accuracy: 0.5)
    }

    // MARK: - Grain boundary

    func testBicrystalHasTwoGrainsWithALocalisedBoundary() throws {
        let a = 4.05, cells = 6
        let interface = Double(cells) * a / 2
        let frame = Self.bicrystal(a: a, cells: cells, degrees: 15)
        let r = try run(frame, .init(quantity: "gb", templates: ["fcc"]))
        XCTAssertEqual(summary(r, "Grains"), "2")

        let values = try XCTUnwrap(r.field?.values)
        let flagged = (0..<frame.count).filter { values[$0] == 1 }
        XCTAssertGreaterThan(flagged.count, 5, "the interface should light up")
        for i in flagged {
            XCTAssertLessThan(abs(frame.atoms[i].x - interface), a,
                              "grain-boundary atom more than a lattice spacing from the interface")
        }
        XCTAssertGreaterThan(Double(summary(r, "Grain-boundary fraction")!)!, 0.5)
        // Not exactly 15°: the last matched atoms on each side sit in the strain
        // field of the boundary, so their fitted orientations are pulled towards
        // each other. It must still read as a high-angle boundary.
        let meanAngle = Double(summary(r, "Mean disorientation at GB")!)!
        XCTAssertGreaterThan(meanAngle, 10.0)
        XCTAssertLessThan(meanAngle, 16.0)
    }

    // MARK: - Hot and molten frames

    /// The design's phase-5 gate: on a hot frame PTM must classify at least as
    /// much as a-CNA does. σ = 0.15 Å is ~5 % of the 2.86 Å nearest-neighbour
    /// distance; because the fixture's displacements are independent per atom,
    /// rather than the correlated long-wavelength motion of a real hot crystal,
    /// this is already a harsher test of relative geometry than the temperature
    /// suggests.
    func testHotFCCBeatsAdaptiveCNA() throws {
        let hot = Fixtures.liquid(cells: 4, sigma: 0.15, seed: 12345)
        let ptm = try run(hot, .init(templates: ["fcc", "hcp", "bcc", "ico"]))
        let cna = try CrystallinityTool.analyze(frame: hot, context: AnalysisContext(),
                                                params: .init())
        XCTAssertGreaterThanOrEqual(fraction(ptm, .fcc), 0.95, "PTM should still see the lattice")
        XCTAssertGreaterThanOrEqual(ptm.scalar!, cna.scalar!,
                                    "PTM must not do worse than a-CNA on a hot frame")
        XCTAssertGreaterThan(ptm.scalar!, cna.scalar!, "and it is supposed to beat it, not tie")
    }

    func testLiquidIsMostlyUnmatched() throws {
        let r = try run(Fixtures.liquid(cells: 3, sigma: 0.6), .init(templates: ["fcc", "hcp", "bcc", "ico"]))
        XCTAssertLessThan(r.scalar!, 0.10)
        XCTAssertLessThan(Double(summary(r, "Crystalline fraction")!)!, 10.0)
    }

    // MARK: - Field options, profile, preview, cancellation

    func testFieldQuantities() throws {
        let frame = Fixtures.fcc(cells: 3)
        let templates = ["fcc"]
        for (quantity, legend) in [("rmsd", "PTM RMSD"), ("gb", "Grain boundaries"),
                                   ("shear", "Von Mises shear"),
                                   ("orientation", "Lattice orientation (IPF hue)")] {
            let r = try run(frame, .init(quantity: quantity, templates: templates))
            XCTAssertEqual(r.field?.legendTitle, legend)
            XCTAssertEqual(r.field?.values.count, frame.count)
        }
        let shear = try run(frame, .init(quantity: "shear", templates: templates))
        for v in shear.field!.values { XCTAssertEqual(v, 0, accuracy: 1e-5) }

        // ⟨001⟩ ∥ z on an unrotated cube is the red corner of the triangle.
        XCTAssertEqual(PTMTool.cubicIPFHue(.identity), 0, accuracy: 1e-6)
        let toward101 = Quat.axisAngle(axis: SIMD3(1, 0, 0), radians: 45 * degree)
        XCTAssertEqual(PTMTool.cubicIPFHue(toward101), 1.0 / 3.0, accuracy: 1e-4)
        let toward111 = Self.rotationTaking(SIMD3(1, 1, 1), onto: SIMD3(0, 0, 1))
        XCTAssertEqual(PTMTool.cubicIPFHue(toward111), 2.0 / 3.0, accuracy: 1e-4)

        let unknown = try run(frame, .init(quantity: "nonsense", templates: templates))
        XCTAssertEqual(unknown.field?.legendTitle, "Structure (PTM)")
        XCTAssertTrue(unknown.notes.contains { $0.contains("Unknown quantity") })
    }

    func testProfileAndStridedPreview() throws {
        let frame = Fixtures.fcc(cells: 3)
        let full = try run(frame, .init(templates: ["fcc"]))
        XCTAssertEqual(full.profile?.valueLabel, "crystalline fraction")
        XCTAssertFalse(full.profile!.values.isEmpty)

        let preview = try run(frame, .init(templates: ["fcc"]),
                              context: AnalysisContext(stride: 4))
        XCTAssertEqual(preview.scalar!, 1.0, accuracy: 1e-9)
        XCTAssertTrue(preview.notes.contains { $0.contains("Preview") })
        XCTAssertEqual(preview.field?.values.count, frame.count)
    }

    func testUnknownTemplateListIsNotApplicable() {
        XCTAssertThrowsError(try run(Fixtures.fcc(cells: 3), .init(templates: ["diamond"]))) {
            guard case AnalysisError.notApplicable = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }

    func testCancellationStops() {
        let context = AnalysisContext(isCancelled: { true })
        XCTAssertThrowsError(try run(Fixtures.fcc(cells: 3), .init(templates: ["fcc"]),
                                     context: context)) {
            XCTAssertEqual($0 as? AnalysisError, .cancelled)
        }
    }

    // MARK: - Fixtures built on top of Fixtures.swift

    /// A rotated fcc block with open boundaries: the lattice is generated over a
    /// padded range, turned about the block centre and clipped back to the cube,
    /// so the interior is a perfect rotated crystal.
    private static func rotatedFCC(rotation: Quat, a: Double = 4.05, cells: Int) -> Frame {
        let length = Double(cells) * a
        let centre = SIMD3(length / 2, length / 2, length / 2)
        var atoms: [Arv] = []
        forEachLatticeSite(a: a, cells: cells) { p in
            let q = rotation.rotate(p - centre) + centre
            if inside(q, 0, length) { atoms.append(Arv(element: "Al", x: q.x, y: q.y, z: q.z)) }
        }
        return Frame(atoms: atoms, box: nil)
    }

    /// Two fcc grains meeting on the plane x = L/2, the right one turned about
    /// z. Periodic in z only — a z rotation keeps the lattice periodic along z
    /// but not along x or y, so those boundaries stay open and no wrap seam can
    /// masquerade as a grain boundary.
    private static func bicrystal(a: Double, cells: Int, degrees: Double) -> Frame {
        let length = Double(cells) * a, mid = length / 2
        let rotation = Quat.axisAngle(axis: SIMD3(0, 0, 1), radians: degrees * Double.pi / 180)
        let pivot = SIMD3(mid, length / 2, 0)
        var sites: [SIMD3<Double>] = []
        forEachLatticeSite(a: a, cells: cells) { p in
            if p.x >= 0, p.x < mid, p.y >= 0, p.y < length, p.z >= 0, p.z < length { sites.append(p) }
            let q = rotation.rotate(p - pivot) + pivot
            if q.x >= mid, q.x < length, q.y >= 0, q.y < length, q.z >= 0, q.z < length { sites.append(q) }
        }
        let atoms = sites.map { Arv(element: "Al", x: $0.x, y: $0.y, z: $0.z) }
        let box = SimulationBox(lo: SIMD3(0, 0, 0), hi: SIMD3(length, length, length),
                                periodicX: false, periodicY: false, periodicZ: true)
        return Frame(atoms: atoms, box: box)
    }

    /// Every fcc site of a padded `cells³` block, so a rotation cannot leave holes.
    private static func forEachLatticeSite(a: Double, cells: Int, _ body: (SIMD3<Double>) -> Void) {
        let basis = [SIMD3(0.0, 0, 0), SIMD3(0, 0.5, 0.5), SIMD3(0.5, 0, 0.5), SIMD3(0.5, 0.5, 0)]
        let pad = cells + 4
        for i in -pad...pad {
            for j in -pad...pad {
                for k in -pad...pad {
                    for b in basis {
                        body(SIMD3((Double(i) + b.x) * a, (Double(j) + b.y) * a, (Double(k) + b.z) * a))
                    }
                }
            }
        }
    }

    private static func inside(_ p: SIMD3<Double>, _ lo: Double, _ hi: Double) -> Bool {
        p.x >= lo && p.x < hi && p.y >= lo && p.y < hi && p.z >= lo && p.z < hi
    }

    /// The orientation PTM assigns to one atom, matched directly rather than
    /// through the tool (the tool publishes a hue, not a quaternion).
    private static func orientation(of atom: Int, in frame: Frame,
                                    context: AnalysisContext) throws -> Quat {
        let positions = frame.positions
        let cutoff = CrystallinityTool.estimateBuildCutoff(frame: frame, positions: positions,
                                                           context: context)
        let list = NeighborList(frame: frame, cutoff: cutoff)
        let nearest = list.kNearest(of: atom, k: PTMTemplate.fcc.count)
        var observed: [SIMD3<Double>] = []
        var mean = 0.0
        for (index, distance) in nearest {
            var d = positions[index] - positions[atom]
            if let box = frame.box { d = box.minimumImage(d) }
            observed.append(d)
            mean += distance
        }
        mean /= Double(max(1, nearest.count))
        observed = observed.map { $0 / mean }
        let match = try XCTUnwrap(TemplateMatcher().match(observed: observed, template: .fcc))
        XCTAssertLessThan(match.rmsd, 1e-6)
        return match.orientation
    }

    /// A rotation carrying `from` onto `to` — used to aim a crystal axis at z.
    private static func rotationTaking(_ from: SIMD3<Double>, onto to: SIMD3<Double>) -> Quat {
        let u = from / (from * from).sum().squareRoot()
        let v = to / (to * to).sum().squareRoot()
        let axis = SIMD3(u.y * v.z - u.z * v.y, u.z * v.x - u.x * v.z, u.x * v.y - u.y * v.x)
        let angle = acos(max(-1, min(1, (u * v).sum())))
        // The tool asks which crystal direction is parallel to lab z, i.e. it
        // applies q⁻¹ to ẑ; so the orientation that puts `from` along z is the
        // inverse of the rotation carrying `from` to `to`.
        return Quat.axisAngle(axis: axis, radians: angle).conjugate
    }
}
