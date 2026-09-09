import XCTest
@testable import LAMMPSCore

final class AnalysisFoundationTests: XCTestCase {

    // MARK: - Box

    private let cube = SimulationBox(lo: SIMD3(0, 0, 0), hi: SIMD3(10, 10, 10))

    func testMinimumImage() {
        let d = cube.minimumImage(SIMD3(9, -6, 1))
        XCTAssertEqual(d.x, -1, accuracy: 1e-12)
        XCTAssertEqual(d.y, 4, accuracy: 1e-12)
        XCTAssertEqual(d.z, 1, accuracy: 1e-12)
    }

    func testMinimumImageSkipsNonPeriodicAxes() {
        let slab = SimulationBox(lo: SIMD3(0, 0, 0), hi: SIMD3(10, 10, 10), periodicZ: false)
        let d = slab.minimumImage(SIMD3(9, 0, 9))
        XCTAssertEqual(d.x, -1, accuracy: 1e-12)
        XCTAssertEqual(d.z, 9, accuracy: 1e-12)   // fixed axis: no wrapping
    }

    func testWrap() {
        XCTAssertEqual(cube.wrap(SIMD3(12, -1, 5)).x, 2, accuracy: 1e-12)
        XCTAssertEqual(cube.wrap(SIMD3(12, -1, 5)).y, 9, accuracy: 1e-12)
        XCTAssertEqual(cube.lengths.z, 10, accuracy: 1e-12)
    }

    // MARK: - Binning vs the existing z-profile histogram

    private func slabPlusProbes(_ probeZ: [Double]) -> [Arv] {
        var atoms = (0..<100).map { Arv(element: "Al", x: 0, y: 0, z: Double($0) * 0.1) }
        atoms += probeZ.map { Arv(element: "O", x: 0, y: 0, z: $0, charge: -1.5) }
        return atoms
    }

    func testBinningReproducesZProfileHistogramExactly() throws {
        let probes = [7.7, 8.9, 10.0, 10.4, 11.0, 13.2, 18.0, 30.0]
        let atoms = slabPlusProbes(probes)
        let zp = try XCTUnwrap(ZProfileAnalysis(frame: atoms, substrate: "Al", probe: "O"))
        let rel = probes.map { $0 - zp.surfaceZ }

        let mine = Binning.histogram(rel, bins: 12)
        XCTAssertEqual(mine.count, zp.histogram.count)
        for (a, b) in zip(mine, zp.histogram) {
            XCTAssertEqual(a.range.lowerBound, b.range.lowerBound)   // exact, not approximate
            XCTAssertEqual(a.range.upperBound, b.range.upperBound)
            XCTAssertEqual(a.count, b.count)
        }
        XCTAssertEqual(mine.reduce(0) { $0 + $1.count }, probes.count)
    }

    // MARK: - Z-profile as a tool

    func testZProfileToolDefaultMatchesZProfileAnalysis() throws {
        let probes = [7.7, 8.9, 10.0, 11.0, 13.2, 30.0]
        let frame = Frame(atoms: slabPlusProbes(probes))
        let zp = try XCTUnwrap(ZProfileAnalysis(frame: frame.atoms, substrate: "Al", probe: "O"))
        let result = try ZProfileTool.analyze(frame: frame, context: AnalysisContext(),
                                              params: ZProfileTool.defaultParameters)

        let profile = try XCTUnwrap(result.profile)
        XCTAssertEqual(profile.counts, zp.histogram.map(\.count))
        XCTAssertEqual(profile.values, zp.histogram.map { Double($0.count) })
        XCTAssertEqual(profile.edges.first!, zp.histogram.first!.range.lowerBound)
        XCTAssertEqual(profile.edges.last!, zp.histogram.last!.range.upperBound)
        XCTAssertEqual(result.scalar!, zp.maxPenetration!, accuracy: 1e-12)
        XCTAssertTrue(result.summary.contains { $0.label == "Surface plane z"
                                             && $0.value == String(format: "%.3f", zp.surfaceZ) })
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testZProfileToolProfilesChargeAndFields() throws {
        var atoms = slabPlusProbes([8.0, 10.0, 12.0])
        atoms[100] = Arv(element: "O", x: 0, y: 0, z: 8.0, charge: -2.0)
        var frame = Frame(atoms: atoms)
        // A per-atom field published by another tool, parallel to atoms.
        frame.columns["q6"] = (0..<atoms.count).map { $0 >= 100 ? Float($0 - 99) : 0 }

        let charged = try ZProfileTool.analyze(frame: frame, context: AnalysisContext(),
                                               params: .init(profileOf: .charge))
        XCTAssertEqual(charged.profile!.valueLabel, "mean charge (e)")
        XCTAssertEqual(charged.profile!.values.reduce(0, +) / 3, -1.6666, accuracy: 1e-3)

        let field = try ZProfileTool.analyze(frame: frame, context: AnalysisContext(),
                                             params: .init(profileOf: .field("q6")))
        XCTAssertEqual(field.profile!.valueLabel, "mean q6")
        XCTAssertEqual(field.profile!.values.max()!, 3.0, accuracy: 1e-9)

        let missing = try ZProfileTool.analyze(frame: frame, context: AnalysisContext(),
                                               params: .init(profileOf: .field("nope")))
        XCTAssertEqual(missing.profile!.counts, charged.profile!.counts)   // falls back to counts
        XCTAssertEqual(missing.notes.count, 1)
    }

    func testZProfileToolRoundTripsParametersAndRegisters() throws {
        let registry = ToolRegistry()
        registry.registerBuiltIns()
        XCTAssertTrue(registry.metadata.map(\.id).contains("z_profile"))
        XCTAssertEqual(registry.metadata.first { $0.id == "z_profile" }?.category, .surfacesDeposition)

        let erased = try XCTUnwrap(registry.tool("z_profile"))
        let params = ZProfileTool.Parameters(substrate: "Al", probe: "O", bins: 6,
                                             profileOf: .field("q6"))
        registry.setParameters(params, for: ZProfileTool.self)
        let stored = try JSONDecoder().decode(ZProfileTool.Parameters.self,
                                              from: registry.parameters(for: "z_profile")!)
        XCTAssertEqual(stored, params)

        let frame = Frame(atoms: slabPlusProbes([8.0, 10.0, 12.0]))
        let result = try erased.analyze(frame: frame, context: AnalysisContext(),
                                        parametersJSON: registry.parameters(for: "z_profile"))
        // Honoured the stored bin count: 6 requested bins over the same span
        // gives wider bins — hence strictly fewer than the 8 the default yields.
        XCTAssertLessThan(result.profile!.counts.count, 8)
        XCTAssertEqual(result.profile!.counts.reduce(0, +), 3)
    }

    func testRegistryEnabledSetAndMeasuredCost() {
        let registry = ToolRegistry()
        registry.registerBuiltIns()
        XCTAssertTrue(registry.enabled.isEmpty)
        registry.setEnabled(true, for: "z_profile")
        XCTAssertTrue(registry.isEnabled("z_profile"))
        registry.setEnabled(false, for: "z_profile")
        XCTAssertFalse(registry.isEnabled("z_profile"))

        // Declared cost until a run is measured, then the rolling median wins.
        XCTAssertEqual(registry.estimatedCost(toolId: "z_profile", atoms: 1000), 50, accuracy: 1e-9)
        for us in [1000.0, 3000.0, 2000.0] {   // 1, 3, 2 µs/atom over 1000 atoms
            registry.recordMeasurement(toolId: "z_profile", atoms: 1000, microseconds: us)
        }
        XCTAssertEqual(registry.measuredMicrosecondsPerAtom(toolId: "z_profile")!, 2.0, accuracy: 1e-9)
        XCTAssertEqual(registry.estimatedCost(toolId: "z_profile", atoms: 1000), 2000, accuracy: 1e-9)
    }

    // MARK: - Field cache

    private func result(atoms: Int) -> ToolResult {
        ToolResult(field: PerAtomField(name: "f", values: [Float](repeating: 1, count: atoms),
                                       palette: .continuous(min: 0, max: 1, colormapName: "viridis"),
                                       legendTitle: "f"))
    }

    func testFieldCacheEvictsByBytes() {
        let one = result(atoms: 10_000).estimatedBytes          // ~40 kB
        let cache = FieldCache(byteLimit: one * 3 + 10)
        for frame in 0..<5 {
            cache.insert(result(atoms: 10_000),
                         for: FieldCacheKey(toolId: "t", paramsHash: 0, frameIndex: frame))
        }
        XCTAssertLessThanOrEqual(cache.currentBytes, one * 3 + 10)
        XCTAssertEqual(cache.count, 3)
        XCTAssertNil(cache.value(for: FieldCacheKey(toolId: "t", paramsHash: 0, frameIndex: 0)))
        XCTAssertNotNil(cache.value(for: FieldCacheKey(toolId: "t", paramsHash: 0, frameIndex: 4)))

        // A result bigger than the whole budget is never admitted.
        cache.insert(result(atoms: 10_000_000),
                     for: FieldCacheKey(toolId: "t", paramsHash: 0, frameIndex: 9))
        XCTAssertNil(cache.value(for: FieldCacheKey(toolId: "t", paramsHash: 0, frameIndex: 9)))
        XCTAssertLessThanOrEqual(cache.currentBytes, one * 3 + 10)

        cache.evict(toBytes: 0)
        XCTAssertEqual(cache.currentBytes, 0)
    }

    func testToolResultCodableRoundTrip() throws {
        var r = result(atoms: 4)
        r.summary = [SummaryRow("Max penetration", "1.250", unit: "Å")]
        r.profile = Binning.profile(coordinates: [0, 1, 2, 3], values: nil, bins: 2,
                                    axisLabel: "z", valueLabel: "atoms")
        r.scalar = 1.25
        r.field = PerAtomField(name: "class", values: [0, 1, 1, 2],
                               palette: .categorical([("below", RGB(1, 0, 0)), ("above", RGB(0, 0, 1))]),
                               legendTitle: "Class")
        let decoded = try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded, r)
    }
}
