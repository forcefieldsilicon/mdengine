import XCTest
@testable import LAMMPSCore

/// Validation for the Falk–Langer strain tool: analytic deformations of a small
/// fcc block, where every per-atom answer is known in closed form.
final class DeformationToolTests: XCTestCase {

    // MARK: - Fixtures (local on purpose — Fixtures.swift belongs to another tool)

    private let a = 4.05                                   // Al lattice constant, nn = a/√2 = 2.86 Å
    private var boxLength: Double { a * 5 }                // 5×5×5 conventional cells = 500 atoms

    /// An fcc block filling a cube of `cells`×`a`, optionally with atom ids.
    private func fccBlock(cells: Int = 5, periodicY: Bool = true,
                          boxed: Bool = true, ids: Bool = false) -> Frame {
        let basis: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(0.5, 0.5, 0),
                                      SIMD3(0.5, 0, 0.5), SIMD3(0, 0.5, 0.5)]
        var atoms: [Arv] = []
        for i in 0..<cells { for j in 0..<cells { for k in 0..<cells { for b in basis {
            let p = (SIMD3(Double(i), Double(j), Double(k)) + b) * a
            atoms.append(Arv(element: "Al", x: p.x, y: p.y, z: p.z,
                             id: ids ? atoms.count + 1 : nil))
        } } } }
        let l = Double(cells) * a
        let box = boxed ? SimulationBox(lo: SIMD3(0, 0, 0), hi: SIMD3(l, l, l),
                                        periodicY: periodicY) : nil
        return Frame(atoms: atoms, box: box)
    }

    /// Map every position, optionally wrapping into the new box.
    private func mapped(_ frame: Frame, box: SimulationBox?, wrap: Bool = false,
                        _ transform: (SIMD3<Double>) -> SIMD3<Double>) -> Frame {
        let atoms = frame.atoms.map { atom -> Arv in
            var p = transform(SIMD3(atom.x, atom.y, atom.z))
            if wrap, let box { p = box.wrap(p) }
            return Arv(element: atom.element, x: p.x, y: p.y, z: p.z, id: atom.id)
        }
        return Frame(atoms: atoms, box: box)
    }

    private func run(_ current: Frame, reference: Frame, quantity: String = "shear",
                     threshold: Double = 0.5) throws -> ToolResult {
        try DeformationTool.analyze(
            frame: current,
            context: AnalysisContext(referenceFrame: reference),
            params: .init(quantity: quantity, d2minThreshold: threshold))
    }

    private func value(_ result: ToolResult, _ label: String) -> String? {
        result.summary.first { $0.label == label }?.value
    }

    // MARK: - (a) uniform affine stretch

    func testUniformAffineStrainMatchesAnalytic() throws {
        let reference = fccBlock()
        let f = SIMD3(1.02, 1.0, 0.99)
        let l = boxLength
        let box = SimulationBox(lo: SIMD3(0, 0, 0), hi: SIMD3(l * f.x, l * f.y, l * f.z))
        let current = mapped(reference, box: box) { $0 * f }

        // E = ½(FᵀF − I) for a diagonal F.
        let exx = (f.x * f.x - 1) / 2, eyy = (f.y * f.y - 1) / 2, ezz = (f.z * f.z - 1) / 2
        let volumetric = (exx + eyy + ezz) / 3
        let shear = (((exx - eyy) * (exx - eyy) + (exx - ezz) * (exx - ezz)
                    + (eyy - ezz) * (eyy - ezz)) / 6).squareRoot()

        let vol = try run(current, reference: reference, quantity: "volumetric")
        XCTAssertEqual(vol.field?.values.count, 500)
        for v in vol.field!.values { XCTAssertEqual(Double(v), volumetric, accuracy: 1e-6) }
        XCTAssertEqual(value(vol, "Valid fits"), "500")

        let shr = try run(current, reference: reference)
        for v in shr.field!.values { XCTAssertEqual(Double(v), shear, accuracy: 1e-6) }
        XCTAssertEqual(shr.scalar!, shear, accuracy: 1e-6)

        let d2 = try run(current, reference: reference, quantity: "d2min")
        XCTAssertLessThan(d2.field!.values.map { abs($0) }.max()!, 1e-9)
        // det F − 1 for this stretch:
        XCTAssertEqual(Double(value(vol, "Mean volume change")!)!,
                       f.x * f.y * f.z - 1, accuracy: 1e-4)
        XCTAssertEqual(value(vol, "Box strain"), "0.02, 0, -0.01")
    }

    // MARK: - (b) simple shear

    func testSimpleShearMatchesAnalytic() throws {
        // x' = x + γy: exact under x/z periodicity, so only y is left open.
        let gamma = 0.03
        let reference = fccBlock(periodicY: false)
        let current = mapped(reference, box: reference.box) {
            SIMD3($0.x + gamma * $0.y, $0.y, $0.z)
        }
        // E_xy = γ/2, one diagonal term = γ²/2, the rest zero.
        let exy = gamma / 2, ed = gamma * gamma / 2
        let shear = (exy * exy + (ed * ed + ed * ed) / 6).squareRoot()

        let shr = try run(current, reference: reference)
        for v in shr.field!.values { XCTAssertEqual(Double(v), shear, accuracy: 1e-6) }

        let d2 = try run(current, reference: reference, quantity: "d2min")
        XCTAssertLessThan(d2.field!.values.max()!, 1e-9)
    }

    // MARK: - (c) rigid translation across the periodic boundary

    func testRigidTranslationIsStrainFree() throws {
        let reference = fccBlock(ids: true)
        let t = SIMD3(1.3, -0.7, 2.1)
        var current = mapped(reference, box: reference.box, wrap: true) { $0 + t }
        current.atoms.reverse()                 // ids, not order, are the identity

        let shr = try run(current, reference: reference)
        XCTAssertLessThan(shr.field!.values.max()!, 1e-9)
        let d2 = try run(current, reference: reference, quantity: "d2min")
        XCTAssertLessThan(d2.field!.values.max()!, 1e-9)

        let disp = try run(current, reference: reference, quantity: "displacement")
        let expected = (t * t).sum().squareRoot()          // 2.567 Å, minimum image
        XCTAssertEqual(expected, 2.567, accuracy: 0.01)
        for v in disp.field!.values { XCTAssertEqual(Double(v), expected, accuracy: 1e-6) }
        XCTAssertEqual(Double(value(disp, "MSD")!)!, expected * expected, accuracy: 1e-3)

        // Without ids the reversed order would be a different (wrong) matching.
        var idless = current
        idless.atoms = idless.atoms.map { Arv(element: $0.element, x: $0.x, y: $0.y, z: $0.z) }
        var ref2 = reference
        ref2.atoms = ref2.atoms.map { Arv(element: $0.element, x: $0.x, y: $0.y, z: $0.z) }
        let wrong = try run(idless, reference: ref2, quantity: "displacement")
        XCTAssertGreaterThan(wrong.field!.values.max()!, 1)
    }

    // MARK: - (d) rigid rotation

    func testRigidRotationIsStrainFree() throws {
        let reference = fccBlock(boxed: false)             // a rotated cell is not this cell
        let angle = 10.0 * .pi / 180, c = cos(angle), s = sin(angle)
        let center = SIMD3(repeating: boxLength / 2)
        let current = mapped(reference, box: nil) { p -> SIMD3<Double> in
            let d = p - center
            return center + SIMD3(c * d.x - s * d.y, s * d.x + c * d.y, d.z)
        }
        let shr = try run(current, reference: reference)
        XCTAssertLessThan(shr.field!.values.max()!, 1e-9)
        let vol = try run(current, reference: reference, quantity: "volumetric")
        XCTAssertLessThan(vol.field!.values.map { abs($0) }.max()!, 1e-9)
        let d2 = try run(current, reference: reference, quantity: "d2min")
        XCTAssertLessThan(d2.field!.values.max()!, 1e-9)
        XCTAssertEqual(value(shr, "Valid fits"), "500")    // corner atoms still fit
    }

    // MARK: - (e) one displaced atom

    func testSingleDisplacedAtomIsLocalisedAndRearranged() throws {
        let reference = fccBlock()
        let target = 250                                   // an interior atom
        var atoms = reference.atoms
        let moved = atoms[target]
        atoms[target] = Arv(element: moved.element, x: moved.x + 1.0, y: moved.y, z: moved.z)
        let current = Frame(atoms: atoms, box: reference.box)

        let d2 = try run(current, reference: reference, quantity: "d2min", threshold: 1e-9)
        let values = d2.field!.values
        // The atom itself: its 12 neighbours all shift by −1 Å, Σd0 = 0 ⇒ F = I, D²min = |c|².
        XCTAssertEqual(Double(values[target]), 1.0, accuracy: 1e-6)
        // Exactly the atom + its 12 nearest neighbours are affected.
        XCTAssertEqual(values.filter { $0 > 1e-9 }.count, 13)
        XCTAssertLessThan(values.enumerated().filter { $0.offset != target && $0.element <= 1e-9 }
                                .map { $0.element }.max()!, 1e-9)
        XCTAssertEqual(Double(value(d2, "Fraction rearranged")!)!, 13.0 / 500.0, accuracy: 1e-6)

        let flags = try run(current, reference: reference, quantity: "rearranged", threshold: 1e-9)
        XCTAssertEqual(flags.field!.values.filter { $0 == 1 }.count, 13)
        if case .categorical(let cats)? = flags.field?.palette {
            XCTAssertEqual(cats.map(\.label), ["affine", "rearranged"])
            XCTAssertEqual(cats[1].color, RGB(1.0, 0.55, 0.1))
        } else { XCTFail("categorical palette expected for “rearranged”") }
        // A high threshold rearranges nobody.
        let quiet = try run(current, reference: reference, quantity: "d2min", threshold: 5)
        XCTAssertEqual(Double(value(quiet, "Fraction rearranged")!)!, 0, accuracy: 1e-12)
    }

    // MARK: - (f) requirements

    func testMismatchedCountsAndMissingReference() throws {
        let reference = fccBlock(cells: 2)
        var short = reference
        short.atoms.removeLast()
        XCTAssertThrowsError(try run(short, reference: reference)) { error in
            guard case AnalysisError.notApplicable(let why) = error else { return XCTFail("notApplicable expected") }
            XCTAssertTrue(why.contains("cannot be matched"))
        }
        XCTAssertThrowsError(try DeformationTool.analyze(frame: reference, context: AnalysisContext(),
                                                         params: .init())) { error in
            XCTAssertEqual(error as? AnalysisError, .missingRequirement(.referenceFrame))
        }
        XCTAssertThrowsError(try run(reference, reference: reference, quantity: "nope"))
        // No stress columns → the stress quantity says so instead of lying.
        XCTAssertThrowsError(try run(reference, reference: reference, quantity: "vonmises_stress")) { error in
            guard case AnalysisError.notApplicable(let why) = error else { return XCTFail("notApplicable expected") }
            XCTAssertTrue(why.contains("stress"))
        }
    }

    // MARK: - (g) stress columns

    func testVonMisesStressFromStressColumns() throws {
        let reference = fccBlock(cells: 2)
        var current = reference
        let n = current.count
        // Uniaxial σxx = 100 ⇒ von Mises = 100.
        current.columns = ["c_stress[1]": [Float](repeating: 100, count: n),
                           "c_stress[2]": [Float](repeating: 0, count: n),
                           "c_stress[3]": [Float](repeating: 0, count: n),
                           "c_stress[4]": [Float](repeating: 0, count: n),
                           "c_stress[5]": [Float](repeating: 0, count: n),
                           "c_stress[6]": [Float](repeating: 0, count: n)]
        let r = try run(current, reference: reference, quantity: "vonmises_stress")
        XCTAssertEqual(Double(value(r, "Mean von Mises stress")!)!, 100, accuracy: 1e-3)
        for v in r.field!.values { XCTAssertEqual(Double(v), 100, accuracy: 1e-3) }

        // Named columns, pure shear σxy = 50 ⇒ von Mises = √3·50.
        current.columns = ["v_sxx": [Float](repeating: 0, count: n),
                           "v_syy": [Float](repeating: 0, count: n),
                           "v_szz": [Float](repeating: 0, count: n),
                           "v_sxy": [Float](repeating: 50, count: n),
                           "v_sxz": [Float](repeating: 0, count: n),
                           "v_syz": [Float](repeating: 0, count: n)]
        let shearStress = try run(current, reference: reference, quantity: "vonmises_stress")
        XCTAssertEqual(Double(shearStress.field!.values[0]), 50 * 3.0.squareRoot(), accuracy: 1e-3)

        // Opted out → no stress row at all.
        let off = try DeformationTool.analyze(
            frame: current, context: AnalysisContext(referenceFrame: reference),
            params: .init(stressColumns: false))
        XCTAssertNil(value(off, "Mean von Mises stress"))
    }

    // MARK: - Metadata, profile, cancellation

    func testMetadataProfileAndCancellation() throws {
        XCTAssertEqual(DeformationTool.id, "deformation")
        XCTAssertEqual(DeformationTool.category, .mechanicsDeformation)
        XCTAssertEqual(DeformationTool.requirements, [.referenceFrame])
        XCTAssertFalse(DeformationTool.supportsStridedPreview)

        let reference = fccBlock(cells: 3)
        let current = mapped(reference, box: reference.box) { $0 }
        let r = try run(current, reference: reference)
        XCTAssertEqual(r.profile?.valueLabel, "mean shear strain")
        XCTAssertGreaterThan(r.profile?.values.count ?? 0, 1)
        if case .continuous(let lo, let hi, let map)? = r.field?.palette {
            XCTAssertEqual(map, "inferno")
            XCTAssertLessThanOrEqual(lo, hi)
        } else { XCTFail("continuous palette expected") }

        let cancelling = AnalysisContext(referenceFrame: reference, isCancelled: { true })
        XCTAssertThrowsError(try DeformationTool.analyze(frame: current, context: cancelling,
                                                         params: .init())) { error in
            XCTAssertEqual(error as? AnalysisError, .cancelled)
        }
    }
}
