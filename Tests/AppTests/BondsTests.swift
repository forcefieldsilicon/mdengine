//
//  BondsTests.swift — bond perception + backbone trace + line geometry
//  (GJOB-145).
//
//  The criterion is d ≤ tolerance × (r_i + r_j) with Cordero 2008 radii, so
//  every assertion here is arithmetic on published numbers, not a recorded
//  screenshot.
//

import XCTest
import simd
@testable import LAMMPSCore
@testable import MDRender

final class BondsTests: XCTestCase {

    // MARK: - Molecules

    /// Two waters, 5 Å apart. Within a water O–H is 0.96 Å against a
    /// criterion of 1.15 × (0.66 + 0.31) = 1.12 Å → bonded. The two oxygens
    /// are 5 Å apart against 1.15 × (0.66 + 0.66) = 1.52 Å → not bonded, and
    /// neither is any cross-molecule O–H.
    private func water(origin: SIMD3<Double>) -> [Arv] {
        [Arv(element: "O", x: origin.x, y: origin.y, z: origin.z),
         Arv(element: "H", x: origin.x + 0.96, y: origin.y, z: origin.z),
         Arv(element: "H", x: origin.x - 0.24, y: origin.y + 0.93, z: origin.z)]
    }

    func testWaterOHBondedOONot() throws {
        let frame = Frame(atoms: water(origin: SIMD3(0, 0, 0)) + water(origin: SIMD3(5, 0, 0)))
        let set = try XCTUnwrap(BondPerception.perceive(frame: frame))

        XCTAssertEqual(set.bondCount, 4, "two waters = two O–H bonds each")
        XCTAssertEqual(Set(set.neighbors(of: 0)), [1, 2])
        XCTAssertEqual(Set(set.neighbors(of: 3)), [4, 5])
        // No O…O and no H–H anywhere.
        for k in stride(from: 0, to: set.pairs.count, by: 2) {
            let a = frame.atoms[Int(set.pairs[k])].element
            let b = frame.atoms[Int(set.pairs[k + 1])].element
            XCTAssertNotEqual([a, b].sorted(), ["O", "O"])
            XCTAssertNotEqual([a, b].sorted(), ["H", "H"])
        }
    }

    /// H–H is skipped even when the geometry would allow it: two hydrogens
    /// 0.5 Å apart are inside 1.15 × 0.62 = 0.71 Å, and still get no stick.
    func testHydrogenPairIsNeverBonded() throws {
        let frame = Frame(atoms: [Arv(element: "H", x: 0, y: 0, z: 0),
                                  Arv(element: "H", x: 0.5, y: 0, z: 0)])
        let set = try XCTUnwrap(BondPerception.perceive(frame: frame))
        XCTAssertEqual(set.bondCount, 0)
    }

    // MARK: - Crystal coordination

    /// bcc gives 8 nearest neighbours at √3·a/2 and 6 second neighbours at a.
    /// With Fe's radius 1.32 Å the criterion is 1.15 × 2 × 1.32 = 3.036 Å, so
    /// "8 bonds per atom" needs a lattice constant with
    ///
    ///     √3·a/2  ≤  3.036  <  a        →   3.036 < a ≤ 3.505
    ///
    /// a = 3.20 Å sits in that window (first shell 2.77 Å in, second shell
    /// 3.20 Å out). REAL Fe (a = 2.87 Å) does NOT: its second shell at 2.87 Å
    /// is also inside 3.036 Å, so a distance criterion necessarily reports 14
    /// — asserted below, because it is the honest behaviour of the method and
    /// the reason bond sticks on a dense metal look like a cage.
    ///
    /// Counted for an interior atom: perception uses open boundaries (a bond
    /// through a periodic image would draw across the whole box), so surface
    /// atoms legitimately have fewer.
    func testBCCInteriorAtomHasEightBonds() throws {
        let frame = Fixtures.bcc(a: 3.20, cells: 4)
        let set = try XCTUnwrap(BondPerception.perceive(frame: frame))
        let interior = Fixtures.atom(frame)
        XCTAssertEqual(set.neighbors(of: interior).count, 8)

        let dense = Fixtures.bcc(a: 2.87, cells: 4)
        let denseSet = try XCTUnwrap(BondPerception.perceive(frame: dense))
        XCTAssertEqual(denseSet.neighbors(of: Fixtures.atom(dense)).count, 14,
                       "at a = 2.87 Å the bcc second shell is inside the tolerance too")
    }

    // MARK: - Backbone

    /// Three residues in PDB atom order (N, CA, C, O), one chain.
    private func tripeptide(withNames: Bool) -> Frame {
        var atoms: [Arv] = []
        var names: [String] = []
        var chain: [String] = []
        var resid: [Float] = []
        for r in 0..<3 {
            let x = Double(r) * 3.6          // ~one residue rise along a helix
            let offsets: [(String, String, SIMD3<Double>)] = [
                ("N", "N", SIMD3(x, 0, 0)),
                ("C", "CA", SIMD3(x + 1.45, 0, 0)),
                ("C", "C", SIMD3(x + 2.4, 0.6, 0)),
                ("O", "O", SIMD3(x + 2.4, 1.8, 0)),
            ]
            for (element, name, p) in offsets {
                atoms.append(Arv(element: element, x: p.x, y: p.y, z: p.z))
                names.append(name)
                chain.append("A")
                resid.append(Float(r + 1))
            }
        }
        var labels = ["chain": chain]
        if withNames { labels["name"] = names }
        return Frame(atoms: atoms, columns: ["resid": resid], labels: labels)
    }

    func testBackboneIsOnePolylineOfThreeAlphaCarbons() throws {
        let frame = tripeptide(withNames: true)
        let set = try XCTUnwrap(BondPerception.perceive(frame: frame))
        XCTAssertEqual(set.backbone.count, 1)
        XCTAssertEqual(set.backbone.first, [1, 5, 9])       // the CA of each residue
    }

    /// Extended XYZ usually carries species/chain/resname/resid and no atom
    /// names; the first carbon of a residue is Cα in PDB atom order, so the
    /// trace is the same.
    func testBackboneFallsBackToFirstCarbonWithoutNames() throws {
        let set = try XCTUnwrap(BondPerception.perceive(frame: tripeptide(withNames: false)))
        XCTAssertEqual(set.backbone.first, [1, 5, 9])
    }

    func testNoBackboneWithoutResidueLabels() throws {
        let set = try XCTUnwrap(BondPerception.perceive(
            frame: Frame(atoms: water(origin: SIMD3(0, 0, 0)))))
        XCTAssertTrue(set.backbone.isEmpty)
    }

    // MARK: - Guards

    func testAtomCapReturnsNilWithAReason() {
        let frame = Frame(atoms: water(origin: SIMD3(0, 0, 0)) + water(origin: SIMD3(5, 0, 0)))
        XCTAssertNil(BondPerception.perceive(frame: frame, maxAtoms: 3))
        let reason = BondPerception.skipReason(atomCount: frame.count, maxAtoms: 3)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason!.contains("3"))
        XCTAssertNil(BondPerception.skipReason(atomCount: frame.count))
    }

    func testCancellationReturnsNil() {
        let frame = Fixtures.bcc(a: 3.20, cells: 6)
        XCTAssertNil(BondPerception.perceive(frame: frame, isCancelled: { true }))
    }

    func testUnknownElementGetsTheFallbackRadius() {
        XCTAssertEqual(BondPerception.radius(for: "1"), BondPerception.unknownRadius)
        XCTAssertEqual(BondPerception.radius(for: "AL"), 1.21, accuracy: 1e-9)
        XCTAssertEqual(BondPerception.radius(for: "C"), 0.76, accuracy: 1e-9)
    }

    // MARK: - Line geometry (MDRender, no GPU needed)

    func testHalfBondsSplitAtTheMidpointAndKeepEachAtomsColour() {
        let red = SIMD3<Float>(1, 0, 0), blue = SIMD3<Float>(0, 0, 1)
        let vertices = RenderCore.lineVertices(
            bonds: BondSet(pairs: [0, 1]),
            positions: [SIMD3(0, 0, 0), SIMD3(2, 0, 0)],
            colors: [red, blue])

        XCTAssertEqual(vertices.count, 4)
        XCTAssertEqual(vertices[0].position, SIMD3(0, 0, 0))
        XCTAssertEqual(vertices[1].position, SIMD3(1, 0, 0))
        XCTAssertEqual(vertices[2].position, SIMD3(1, 0, 0))
        XCTAssertEqual(vertices[3].position, SIMD3(2, 0, 0))
        XCTAssertEqual(vertices[0].color, red)
        XCTAssertEqual(vertices[1].color, red)
        XCTAssertEqual(vertices[2].color, blue)
        XCTAssertEqual(vertices[3].color, blue)
    }

    func testBackboneSegmentsAreGreyAndOutOfRangeIndicesAreDropped() {
        let positions = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(2, 0, 0)]
        let vertices = RenderCore.lineVertices(
            bonds: BondSet(pairs: [0, 99], backbone: [[0, 1, 2]]),
            positions: positions,
            colors: [])                       // no colours: white fallback

        // The 0–99 bond is dropped; the 3-point trace is 2 segments.
        XCTAssertEqual(vertices.count, 4)
        XCTAssertTrue(vertices.allSatisfy { $0.color == RenderCore.backboneColor })
        XCTAssertEqual(vertices[0].position, positions[0])
        XCTAssertEqual(vertices[3].position, positions[2])
    }
}
