import XCTest
@testable import LAMMPSCore

final class AdhesionToolTests: XCTestCase {

    // Two chains, hand-placed so every number below is checkable by hand:
    //   A: N0(0,0,0) H1(0.1,0,1) C2(1,0,0)  [ALA 1] · O3(0,3,0) H4(…) [GLY 2]
    //   B: O5(0,0,3) N6(0,3,3) [LEU 10] · C7(20,20,20) [LEU 11]
    // H1 makes N0–H1···O5 nearly linear (171°); H4 sits so O3–H4···N6 is exactly
    // 90° (distance passes, angle fails). C7 is far outside every cutoff.
    private static let h4x = (1.0 - 1.0 / 9.0).squareRoot()      // |O3H4| = 1 Å, angle at H4 = 90°
    private func twoChainFrame(withHydrogens: Bool = true) -> Frame {
        var rows: [(String, Double, Double, Double, String, String, String)] = [
            ("N", 0, 0, 0, "A", "ALA", "1"),
            ("H", 0.1, 0, 1.0, "A", "ALA", "1"),
            ("C", 1.0, 0, 0, "A", "ALA", "1"),
            ("O", 0, 3.0, 0, "A", "GLY", "2"),
            ("H", Self.h4x, 3.0, 1.0 / 3.0, "A", "GLY", "2"),
            ("O", 0, 0, 3.0, "B", "LEU", "10"),
            ("N", 0, 3.0, 3.0, "B", "LEU", "10"),
            ("C", 20, 20, 20, "B", "LEU", "11")
        ]
        if !withHydrogens { rows.removeAll { $0.0 == "H" } }
        return Frame(atoms: rows.map { Arv(element: $0.0, x: $0.1, y: $0.2, z: $0.3) },
                     labels: ["chain": rows.map { $0.4 },
                              "resname": rows.map { $0.5 },
                              "resid": rows.map { $0.6 }])
    }

    private func value(_ r: ToolResult, _ label: String) -> String? {
        r.summary.first { $0.label == label }?.value
    }

    // MARK: - Contacts, H-bonds, separation

    func testContactsHBondsAndPerResidue() throws {
        let f = twoChainFrame()
        let r = try AdhesionTool.analyze(frame: f, context: AnalysisContext(), params: .init())

        // 6 A–B heavy pairs under 4.5 Å: {N0,C2,O3} × {O5,N6}. C7 is 20 Å away.
        XCTAssertEqual(value(r, "Contacts"), "6")
        XCTAssertEqual(r.scalar, 6)
        XCTAssertEqual(value(r, "H-bonds"), "1")                       // the 171° one only
        XCTAssertEqual(value(r, "Minimum interface distance"), "3.000")
        XCTAssertEqual(value(r, "A:ALA 1"), "4")                         // N0 and C2, 2 contacts each
        XCTAssertEqual(value(r, "A:GLY 2"), "2")
        XCTAssertNil(value(r, "B:LEU 10"))                               // group A residues only

        // Per-atom field: 1 = A in contact, 2 = B in contact, 0 = neither.
        XCTAssertEqual(r.field?.values, [1, 0, 1, 1, 0, 2, 2, 0])
        XCTAssertEqual(r.field?.legendTitle, "Contacts")
        if case .categorical(let entries)? = r.field?.palette {
            XCTAssertEqual(entries.map(\.label), ["no contact", "A in contact", "B in contact"])
            XCTAssertEqual(entries[1].color, RGB(1.0, 0.55, 0.1))
        } else { XCTFail("categorical palette expected") }
        XCTAssertTrue(r.notes.contains { $0.contains("automatically") && $0.contains("chain") })
    }

    func testNoHydrogensFallsBackToPolarContacts() throws {
        let r = try AdhesionTool.analyze(frame: twoChainFrame(withHydrogens: false),
                                         context: AnalysisContext(), params: .init())
        XCTAssertEqual(value(r, "Contacts"), "6")
        XCTAssertEqual(value(r, "H-bonds"), "n/a (no hydrogens)")
        XCTAssertEqual(value(r, "Polar contacts (distance only)"), "2")   // N0–O5 and O3–N6, both 3.0 Å
        XCTAssertTrue(r.notes.contains { $0.contains("No hydrogens") })
    }

    func testCenterOfMassSeparationIsMassWeighted() throws {
        let f = twoChainFrame()
        // Masses restated here so the tool's table is checked, not reused.
        let m: [String: Double] = ["H": 1.008, "C": 12.011, "N": 14.007, "O": 15.999]
        func com(_ idx: [Int]) -> SIMD3<Double> {
            var s = SIMD3<Double>(repeating: 0), total = 0.0
            for i in idx {
                let a = f.atoms[i], w = m[a.element]!
                s += SIMD3(a.x, a.y, a.z) * w
                total += w
            }
            return s / total
        }
        let d = com([5, 6, 7]) - com([0, 1, 2, 3, 4])
        let expected = (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
        XCTAssertEqual(Double(value(try AdhesionTool.analyze(frame: f, context: AnalysisContext(),
                                                             params: .init()), "COM–COM distance")!)!,
                       expected, accuracy: 5e-4)
        XCTAssertEqual(Groups.centerOfMass([0, 1, 2, 3, 4], in: f).y, com([0, 1, 2, 3, 4]).y, accuracy: 1e-12)
    }

    // MARK: - Groups

    func testSuggestPairPrefersChainsThenElements() throws {
        guard case (.label(let n1, let v1), .label(let n2, let v2))? = Groups.suggestPair(twoChainFrame()) else {
            return XCTFail("chain pair expected")
        }
        XCTAssertEqual([n1, n2], ["chain", "chain"])
        XCTAssertEqual([v1, v2], [["A"], ["B"]])                       // A has 5 atoms, B has 3

        let unlabelled = Frame(atoms: ["C", "C", "C", "O", "O", "N"].enumerated()
            .map { Arv(element: $0.element, x: Double($0.offset), y: 0, z: 0) })
        XCTAssertEqual(Groups.suggestPair(unlabelled)?.a, .elements(["C"]))
        XCTAssertEqual(Groups.suggestPair(unlabelled)?.b, .elements(["O"]))

        let oneElement = Frame(atoms: (0..<4).map { Arv(element: "C", x: Double($0), y: 0, z: 0) })
        XCTAssertNil(Groups.suggestPair(oneElement))
        XCTAssertThrowsError(try AdhesionTool.analyze(frame: oneElement, context: AnalysisContext(),
                                                      params: .init())) { error in
            XCTAssertEqual(error as? AnalysisError, .missingRequirement(.groups))
        }
    }

    func testSelectorsAndJSONShape() throws {
        let ladder = Frame(atoms: (0..<10).map { Arv(element: $0 < 5 ? "Al" : "O", x: 0, y: 0, z: Double($0)) })
        XCTAssertEqual(Groups.indices(.slab(axis: .z, min: 0, max: 4.5), in: ladder), [0, 1, 2, 3, 4])
        XCTAssertEqual(Groups.indices(.slab(axis: .z, min: 8, max: 100), in: ladder), [8, 9])
        XCTAssertEqual(Groups.indices(.elements(["o"]), in: ladder), [5, 6, 7, 8, 9])   // case-insensitive
        XCTAssertEqual(Groups.indices(.all, in: ladder).count, 10)
        XCTAssertEqual(Groups.indices(.label(name: "chain", values: ["A"]), in: ladder), [])  // no such label

        let sel = GroupSelector.slab(axis: .z, min: 0, max: 4.5)
        let json = String(data: try JSONEncoder().encode(sel), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"kind\":\"slab\"") || json.contains("\"kind\": \"slab\""))
        XCTAssertEqual(try JSONDecoder().decode(GroupSelector.self, from: JSONEncoder().encode(sel)), sel)
        let labelSel = GroupSelector.label(name: "chain", values: ["A", "C"])
        XCTAssertEqual(try JSONDecoder().decode(GroupSelector.self, from: JSONEncoder().encode(labelSel)), labelSel)

        // Explicit slab groups on the ladder: Al slab vs O slab, contacts at the seam.
        let p = AdhesionTool.Parameters(groupA: .slab(axis: .z, min: 0, max: 4.5),
                                        groupB: .slab(axis: .z, min: 4.5, max: 100))
        let r = try AdhesionTool.analyze(frame: ladder, context: AnalysisContext(), params: p)
        XCTAssertEqual(value(r, "Minimum interface distance"), "1.000")
        XCTAssertTrue(r.notes.contains { $0.contains("explicitly") })
        XCTAssertTrue(r.notes.contains { $0.contains("resname") })     // per-residue asked for, no labels
    }

    // MARK: - Rupture frame

    func testRuptureFrame() {
        func counts(_ xs: [Int]) -> [Int: Int] {
            Dictionary(uniqueKeysWithValues: xs.enumerated().map { ($0.offset, $0.element) })
        }
        XCTAssertEqual(AdhesionTool.ruptureFrame(contactCounts: counts([5, 4, 2, 0, 0, 0])), 3)
        XCTAssertEqual(AdhesionTool.ruptureFrame(contactCounts: counts([3, 0, 2, 0])), 3)  // re-binding is not rupture
        XCTAssertNil(AdhesionTool.ruptureFrame(contactCounts: counts([5, 4, 3, 1])))
        XCTAssertEqual(AdhesionTool.ruptureFrame(contactCounts: counts([0, 0])), 0)
        XCTAssertNil(AdhesionTool.ruptureFrame(contactCounts: [:]))
    }

    // MARK: - Cell list vs brute force

    func testContactCountMatchesBruteForce() throws {
        var seed: UInt64 = 0x5DEECE66D
        func rnd() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }
        let elements = ["C", "N", "O", "H"]
        let atoms = (0..<200).map { i in
            Arv(element: elements[i % 4], x: rnd() * 15, y: rnd() * 15, z: rnd() * 15)
        }
        let f = Frame(atoms: atoms, labels: ["chain": (0..<200).map { $0 < 100 ? "A" : "B" }])
        let cutoff = 4.5
        var expected = 0
        for i in 0..<100 where atoms[i].element != "H" {
            for j in 100..<200 where atoms[j].element != "H" {
                let d = SIMD3(atoms[j].x - atoms[i].x, atoms[j].y - atoms[i].y, atoms[j].z - atoms[i].z)
                if (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot() <= cutoff { expected += 1 }
            }
        }
        XCTAssertGreaterThan(expected, 20)                             // a real interface, not an empty one
        let r = try AdhesionTool.analyze(frame: f, context: AnalysisContext(), params: .init())
        XCTAssertEqual(r.scalar, Double(expected))
    }
}
