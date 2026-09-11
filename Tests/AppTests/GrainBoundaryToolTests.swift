import XCTest
@testable import LAMMPSCore

/// The grain tool is validated on synthetic polycrystals: slabs of fcc cut out
/// of the same lattice and turned about z by a known angle, so the grain count
/// and the misorientation both have an exact expected answer.
final class GrainBoundaryToolTests: XCTestCase {

    private let degree = Double.pi / 180
    private let a = 4.05                      // Al

    private func run(_ frame: Frame, _ params: GrainBoundaryTool.Parameters = .init(structure: "fcc"),
                     context: AnalysisContext = AnalysisContext()) throws -> ToolResult {
        try GrainBoundaryTool.analyze(frame: frame, context: context, params: params)
    }

    private func summary(_ result: ToolResult, _ label: String) -> String? {
        result.summary.first { $0.label == label }?.value
    }

    private func number(_ result: ToolResult, _ label: String) throws -> Double {
        try XCTUnwrap(Double(try XCTUnwrap(summary(result, label), "no row “\(label)”")))
    }

    // MARK: - Single crystal

    func testSingleCrystalIsOneGrainWithNoBoundary() throws {
        let r = try run(Fixtures.fcc(a: a, cells: 4))
        XCTAssertEqual(summary(r, "Grains"), "1")
        XCTAssertEqual(r.scalar!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(summary(r, "Grain-boundary atoms"), "0.0")
        XCTAssertEqual(try number(r, "Mean misorientation at GB"), 0, accuracy: 1e-9)
        XCTAssertEqual(summary(r, "Boundary pairs"), "0")

        // Every atom is interior and carries grain id 1.
        let values = try XCTUnwrap(r.field?.values)
        XCTAssertEqual(values.count, 4 * 4 * 4 * 4)
        XCTAssertTrue(values.allSatisfy { $0 == 1 })
        XCTAssertEqual(r.field?.legendTitle, "Grain")

        // Grain size = every atom; the diameter is the box read as one sphere.
        let atoms = Double(values.count)
        XCTAssertEqual(try number(r, "Mean grain size"), atoms, accuracy: 0.5)
        XCTAssertEqual(try number(r, "Median grain size"), atoms, accuracy: 0.5)
        let volume = pow(4 * a, 3.0)
        let expected = 2 * pow(3 * volume / (4 * Double.pi), 1.0 / 3.0)
        XCTAssertEqual(try number(r, "Mean grain diameter"), expected, accuracy: 0.2)
    }

    // MARK: - Bicrystal

    func testBicrystalIsTwoGrainsAcrossA30DegreeBoundary() throws {
        let cells = 6
        let frame = Self.polycrystal(a: a, cells: cells, rotations: [0, 30])
        let r = try run(frame, .init(quantity: "gb", structure: "fcc"))
        XCTAssertEqual(summary(r, "Grains"), "2")
        XCTAssertEqual(r.scalar!, 2.0, accuracy: 1e-9)

        // A 30° twist about z is 30° after the cubic symmetry is folded in.
        XCTAssertEqual(try number(r, "Mean misorientation at GB"), 30.0, accuracy: 2.0)

        // The boundary is a plane, not a volume: a few percent of the atoms.
        let fraction = try number(r, "Grain-boundary atoms")
        XCTAssertGreaterThan(fraction, 0.5)
        XCTAssertLessThan(fraction, 15.0)

        // And those atoms sit at the interface.
        let interface = Double(cells) * a / 2
        let values = try XCTUnwrap(r.field?.values)
        let flagged = (0..<frame.count).filter { values[$0] == 1 }
        XCTAssertGreaterThan(flagged.count, 20, "the interface should light up")
        for i in flagged {
            XCTAssertLessThan(abs(frame.atoms[i].x - interface), 1.5 * a,
                              "grain-boundary atom far from the interface plane")
        }
        XCTAssertEqual(r.field?.legendTitle, "Grain boundaries")

        // Two grains of similar size, each roughly half the crystal.
        let mean = try number(r, "Mean grain size")
        let median = try number(r, "Median grain size")
        XCTAssertEqual(mean, median, accuracy: 0.35 * mean)
        XCTAssertGreaterThan(mean, 100)
    }

    func testBicrystalGrainFieldLabelsBothGrains() throws {
        let frame = Self.polycrystal(a: a, cells: 6, rotations: [0, 30])
        let r = try run(frame)
        let values = try XCTUnwrap(r.field?.values)
        XCTAssertEqual(Set(values), [0, 1, 2], "grain ids are 0 (boundary/unassigned), 1 and 2")
        if case .categorical(let entries)? = r.field?.palette {
            XCTAssertEqual(entries.count, 3)
            XCTAssertEqual(entries[0].label, "Boundary / unassigned")
            XCTAssertEqual(entries[2].label, "Grain 2")
        } else { XCTFail("categorical palette expected") }

        // The two labels are separated by the interface, not interleaved.
        let mid = 3 * a
        let left = (0..<frame.count).filter { values[$0] == 1 && frame.atoms[$0].x < mid }.count
        let right = (0..<frame.count).filter { values[$0] == 1 && frame.atoms[$0].x > mid }.count
        XCTAssertEqual(min(left, right), 0, "grain 1 must lie on one side of the boundary")
    }

    // MARK: - Tricrystal

    func testTricrystalIsThreeGrains() throws {
        let frame = Self.polycrystal(a: a, cells: 9, rotations: [0, 20, 40])
        let r = try run(frame)
        XCTAssertEqual(summary(r, "Grains"), "3")
        let values = try XCTUnwrap(r.field?.values)
        XCTAssertEqual(Set(values), [0, 1, 2, 3])
        XCTAssertGreaterThan(try number(r, "Mean misorientation at GB"), 10.0)
    }

    // MARK: - Thermal noise

    func testSmallThermalNoiseDoesNotChangeTheGrainCount() throws {
        let cold = Self.polycrystal(a: a, cells: 6, rotations: [0, 30])
        // 2 % of the nearest-neighbour distance (a/√2 = 2.86 Å).
        let hot = Self.shaken(cold, sigma: 0.02 * a / 2.0.squareRoot(), seed: 20260911)
        let cr = try run(cold), hr = try run(hot)
        XCTAssertEqual(summary(hr, "Grains"), summary(cr, "Grains"))
        XCTAssertEqual(summary(hr, "Grains"), "2")
        XCTAssertEqual(try number(hr, "Mean misorientation at GB"),
                       try number(cr, "Mean misorientation at GB"), accuracy: 3.0)
        XCTAssertLessThan(try number(hr, "Grain-boundary atoms"), 15.0)
    }

    // MARK: - Fields, profiles, parameters

    func testFieldQuantitiesAndProfiles() throws {
        let frame = Self.polycrystal(a: a, cells: 6, rotations: [0, 30])

        let mis = try run(frame, .init(quantity: "misorientation", structure: "fcc"))
        XCTAssertEqual(mis.field?.legendTitle, "Misorientation (°)")
        let angles = try XCTUnwrap(mis.field?.values)
        XCTAssertEqual(angles.count, frame.count)
        XCTAssertGreaterThan(angles.max()!, 20, "the boundary angle should show on the boundary atoms")
        XCTAssertLessThan(Double(angles.max()!), 62.9)

        // Default profile = the misorientation distribution, fixed 0…62.8° for cubic.
        let distribution = try XCTUnwrap(mis.profile)
        XCTAssertEqual(distribution.axisLabel, "misorientation (°)")
        XCTAssertEqual(distribution.values.count, 18)
        XCTAssertEqual(distribution.edges.last!, 62.8, accuracy: 1e-9)
        XCTAssertEqual(Int(distribution.values.reduce(0, +)),
                       Int(try number(mis, "Boundary pairs")))
        let peak = try XCTUnwrap(distribution.values.indices.max { distribution.values[$0] < distribution.values[$1] })
        XCTAssertEqual(distribution.centers[peak], 30, accuracy: 4.0)

        // An axis instead gives grain-boundary fraction along that axis.
        let along = try run(frame, .init(structure: "fcc", profileAxis: "x", bins: 12))
        XCTAssertEqual(along.profile?.valueLabel, "grain-boundary fraction")
        XCTAssertEqual(along.profile?.axisLabel, "x")

        let unknownAxis = try run(frame, .init(structure: "fcc", profileAxis: "q"))
        XCTAssertEqual(unknownAxis.profile?.axisLabel, "misorientation (°)")
        XCTAssertTrue(unknownAxis.notes.contains { $0.contains("Unknown profileAxis") })

        let unknownQuantity = try run(frame, .init(quantity: "nonsense", structure: "fcc"))
        XCTAssertEqual(unknownQuantity.field?.legendTitle, "Grain")
        XCTAssertTrue(unknownQuantity.notes.contains { $0.contains("Unknown quantity") })
    }

    func testGbAngleAndMinimumGrainSizeAreHonoured() throws {
        let frame = Self.polycrystal(a: a, cells: 6, rotations: [0, 30])
        // A cut above the boundary angle sees one continuous crystal.
        let coarse = try run(frame, .init(gbAngle: 40, structure: "fcc"))
        XCTAssertEqual(coarse.summary.first { $0.label == "Grains" }?.value, "1")
        XCTAssertEqual(coarse.summary.first { $0.label == "Grain-boundary atoms" }?.value, "0.0")
        // A minimum size above the whole crystal counts no grains at all.
        let strict = try run(frame, .init(minimumGrainSize: 100_000, structure: "fcc"))
        XCTAssertEqual(strict.summary.first { $0.label == "Grains" }?.value, "0")
    }

    func testOpenBoundariesReportNoDiameter() throws {
        let r = try run(Fixtures.fccSlabOpenBoundary(a: a, cells: 4))
        XCTAssertNil(summary(r, "Mean grain diameter"))
        XCTAssertTrue(r.notes.contains { $0.contains("No box") })
        XCTAssertEqual(summary(r, "Grains"), "1")
    }

    func testStridedPreviewAndCancellation() throws {
        let frame = Fixtures.fcc(a: a, cells: 4)
        let preview = try run(frame, .init(structure: "fcc"), context: AnalysisContext(stride: 4))
        XCTAssertEqual(preview.field?.values.count, frame.count)
        XCTAssertEqual(preview.scalar!, 1.0, accuracy: 1e-9)
        XCTAssertTrue(preview.notes.contains { $0.contains("Preview") })

        XCTAssertThrowsError(try run(frame, .init(structure: "fcc"),
                                     context: AnalysisContext(isCancelled: { true }))) {
            XCTAssertEqual($0 as? AnalysisError, .cancelled)
        }
        XCTAssertThrowsError(try run(Frame(atoms: []))) {
            guard case AnalysisError.notApplicable = $0 else { return XCTFail("wrong error: \($0)") }
        }
    }

    func testRegisteredInTheToolRegistry() {
        let registry = ToolRegistry(); registry.registerBuiltIns()
        let meta = registry.metadata.first { $0.id == "grains" }
        XCTAssertEqual(meta?.title, "Grain boundaries")
        XCTAssertEqual(meta?.category, .structureOrder)
        XCTAssertEqual(Set(meta?.functions ?? []), [.perAtomField, .profile, .scalar, .timeSeries])
        XCTAssertEqual(meta?.supportsStridedPreview, true)
    }

    // MARK: - Fixtures

    /// `rotations.count` fcc slabs stacked along x inside one cell, each cut out
    /// of the same lattice turned about z by its own angle. Periodic in z only:
    /// a z rotation leaves the lattice periodic along z but not along x or y, so
    /// those faces stay open and no wrap seam can masquerade as a boundary.
    private static func polycrystal(a: Double, cells: Int, rotations: [Double]) -> Frame {
        let length = Double(cells) * a
        let width = length / Double(rotations.count)
        var sites: [SIMD3<Double>] = []
        for (slab, degrees) in rotations.enumerated() {
            let x0 = Double(slab) * width, x1 = x0 + width
            let pivot = SIMD3((x0 + x1) / 2, length / 2, 0)
            let rotation = Quat.axisAngle(axis: SIMD3(0, 0, 1), radians: degrees * Double.pi / 180)
            forEachLatticeSite(a: a, cells: cells) { p in
                let q = rotation.rotate(p - pivot) + pivot
                if q.x >= x0, q.x < x1, q.y >= 0, q.y < length, q.z >= 0, q.z < length {
                    sites.append(q)
                }
            }
        }
        let atoms = sites.map { Arv(element: "Al", x: $0.x, y: $0.y, z: $0.z) }
        let box = SimulationBox(lo: SIMD3(0, 0, 0), hi: SIMD3(length, length, length),
                                periodicX: false, periodicY: false, periodicZ: true)
        return Frame(atoms: atoms, box: box)
    }

    /// Every atom displaced by a Gaussian of width `sigma` — a stand-in for
    /// thermal motion, independent per atom (harsher than the real correlated
    /// displacement field).
    private static func shaken(_ frame: Frame, sigma: Double, seed: UInt64) -> Frame {
        var rng = Fixtures.SplitMix64(seed: seed)
        return Frame(atoms: frame.atoms.map {
            Arv(element: $0.element,
                x: $0.x + rng.normal() * sigma,
                y: $0.y + rng.normal() * sigma,
                z: $0.z + rng.normal() * sigma)
        }, box: frame.box)
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
}
