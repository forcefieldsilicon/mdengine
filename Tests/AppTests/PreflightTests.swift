import XCTest
@testable import LAMMPSCore

/// Swift mirror of hosted/endpoint/test_caps.py: same manifest semantics, same wording.
final class PreflightTests: XCTestCase {
    static let caps: HostedRunnerCapabilities = {
        func s(_ gpu: Bool, _ v: [String] = []) -> HostedStyleInfo { HostedStyleInfo(gpu: gpu, variants: v) }
        return HostedRunnerCapabilities(engine: "lammps", lammps_version: "29 Aug 2024", image: "img:test", accelerator: "kokkos/cuda",
            packages: ["KOKKOS", "REAXFF"],
            styles: ["pair": ["lj/cut": s(true, ["kk", "omp"]), "reaxff": s(true, ["kk", "omp"]), "table": s(true, ["kk"]), "zero": s(false),
                              "hybrid/overlay": s(true, ["kk"]), "eam/alloy": s(true, ["kk", "omp"])],
                     "fix": ["nve": s(true, ["kk"]), "nvt": s(true, ["kk"]), "ave/time": s(false), "qeq/reaxff": s(true, ["kk", "omp"])],
                     "compute": ["pe": s(false), "temp": s(true, ["kk"])],
                     "kspace": ["pppm": s(true, ["kk"]), "ewald": s(false)],
                     "atom": ["charge": s(true, ["kk"]), "atomic": s(true, ["kk"]), "full": s(true, ["kk"]),
                              "sphere": s(true, ["kk"]), "hybrid": s(true, ["kk"]), "body": s(false), "peri": s(false)],
                     "bond": ["harmonic": s(true, ["kk"])]])
    }()

    func deck(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mde-pf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (n, t) in files { try t.write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        return dir.appendingPathComponent("in.lmp")
    }

    func testAllGPUDeckIsSilent() throws {
        let r = DeckPreflight.check(input: try deck(["in.lmp": "units metal\natom_style charge\npair_style reaxff NULL\nfix 1 all qeq/reaxff 1 0 10 1e-6 reaxff\nfix 2 all nvt temp 300 300 0.1\nkspace_style pppm 1e-4\nrun 100\n"]), caps: Self.caps)
        XCTAssertTrue(r.ok); XCTAssertEqual(r.usesGPU, true); XCTAssertTrue(r.cpuOnly.isEmpty); XCTAssertEqual(r.lines(), []); XCTAssertFalse(r.needsAttention)
    }
    func testMissingPairStyleBlocks() throws {
        let r = DeckPreflight.check(input: try deck(["in.lmp": "pair_style meam\npair_coeff * * lib.meam Al NULL Al\nrun 10\n"]), caps: Self.caps)
        XCTAssertFalse(r.ok); XCTAssertEqual(r.missing.first?.style, "meam"); XCTAssertEqual(r.missing.first?.line, 1)
        XCTAssertTrue(r.lines()[0].contains("not built into the hosted LAMMPS image")); XCTAssertTrue(r.lines()[0].contains("in.lmp:1")); XCTAssertTrue(r.needsAttention)
    }
    func testCPUOnlyPairWarns() throws {
        let r = DeckPreflight.check(input: try deck(["in.lmp": "pair_style zero 5.0\nfix 1 all nve\nrun 10\n"]), caps: Self.caps)
        XCTAssertTrue(r.ok); XCTAssertEqual(r.usesGPU, false); XCTAssertTrue(r.needsAttention)
        let l = r.lines(rateHint: "$2/h"); XCTAssertTrue(l[0].contains("will NOT use the GPU")); XCTAssertTrue(l[0].contains("pair_style zero")); XCTAssertTrue(l[0].contains("$2/h"))
    }
    func testCPUSideFixIsInformational() throws {
        let r = DeckPreflight.check(input: try deck(["in.lmp": "pair_style lj/cut 2.5\nfix 1 all nve\nfix 2 all ave/time 10 1 10 c_pe\ncompute pe all pe\nrun 10\n"]), caps: Self.caps)
        XCTAssertEqual(r.usesGPU, true); XCTAssertEqual(r.cpuOnly.map(\.style), ["ave/time", "pe"]); XCTAssertTrue(r.lines()[0].hasPrefix("CPU-side styles")); XCTAssertFalse(r.needsAttention)
    }
    func testCommentsContinuationsVariablesNone() throws {
        let r = DeckPreflight.check(input: try deck(["in.lmp": "pair_style ${ps} 2.5   # variable\nbond_style none\nfix 1 all &\n   nvt temp 300 300 0.1\n# fix 9 all bogus\n"]), caps: Self.caps)
        XCTAssertTrue(r.missing.isEmpty); XCTAssertEqual(r.gpu.map(\.style), ["nvt"]); XCTAssertEqual(r.gpu[0].line, 3)
    }
    func testHybridSubstylesCheckedArgsNeverRefuse() throws {
        let r = DeckPreflight.check(input: try deck(["in.lmp": "pair_style hybrid/overlay lj/cut 2.5 table linear 1000 zero 3.0\nrun 1\n"]), caps: Self.caps)
        XCTAssertTrue(r.ok); XCTAssertEqual(r.usesGPU, false); XCTAssertTrue(r.cpuOnly.map(\.style).contains("zero")); XCTAssertFalse(r.missing.map(\.style).contains("linear"))
    }
    func testExplicitAcceleratorSuffix() throws {
        let r = DeckPreflight.check(input: try deck(["in.lmp": "pair_style lj/cut/omp 2.5\npair_style table/omp linear 100\n"]), caps: Self.caps)
        XCTAssertEqual(r.missing.map(\.style), ["table/omp"]); XCTAssertEqual(r.missing[0].why, "no /omp variant")
    }
    func testIncludeFollowedAndMissingIncludeNoted() throws {
        let r = DeckPreflight.check(input: try deck(["in.lmp": "include settings.in\ninclude gone.in\nrun 1\n", "settings.in": "pair_style meam\n"]), caps: Self.caps)
        XCTAssertEqual(r.missing.first?.file, "settings.in"); XCTAssertTrue(r.notes.contains { $0.contains("gone.in") })
    }
    func testNoManifestIsANote() throws {
        let r = DeckPreflight.check(input: try deck(["in.lmp": "pair_style meam\n"]), caps: nil)
        XCTAssertTrue(r.ok); XCTAssertTrue(r.notes[0].contains("nothing checked"))
    }
    func testManifestDecodesEndpointShape() throws {
        let json = """
        {"runners": {"lammps": {"engine": "lammps", "lammps_version": "29 Aug 2024", "packages": ["KOKKOS"], "styles": {"pair": {"lj/cut": {"gpu": true, "variants": ["kk"]}}}},
                     "openmm": {"engine": "openmm", "platforms": ["CUDA"]}}, "default_runner": "lammps", "rates": {"any": 2.0}}
        """
        let caps = try JSONDecoder().decode(HostedCapabilities.self, from: Data(json.utf8))
        XCTAssertEqual(caps.lammps?.styles?["pair"]?["lj/cut"]?.gpu, true); XCTAssertEqual(caps.runners["openmm"]?.engine, "openmm")
        XCTAssertNil(caps.routing)                                     // pre-0.5.0 endpoint: no routing block, still decodes
    }

    // -- routing (GJOB-116): mirror of test_caps.Routing -------------------------------------------------------------
    /// Slim default + a fuller image that adds MEAM, wired the way GET /v1/capabilities reports it since endpoint 0.5.0.
    static let routedCaps: HostedCapabilities = {
        var full = PreflightTests.caps.styles!
        full["pair"]!["meam"] = HostedStyleInfo(gpu: true, variants: ["kk"])
        let fullMan = HostedRunnerCapabilities(engine: "lammps", lammps_version: "29 Aug 2024", image: "full:test", accelerator: "kokkos/cuda",
                                               packages: ["KOKKOS", "MEAM", "REAXFF"], styles: full)
        return HostedCapabilities(runners: ["lammps": PreflightTests.caps, "lammps-full": fullMan, "openmm": HostedRunnerCapabilities(engine: "openmm")],
                                  default_runner: "lammps", rates: ["any": 2.0],
                                  routing: HostedRouting(defaultRunner: "lammps", fallbacks: ["lammps-full"]),
                                  excluded_packages: ["KIM": "OpenKIM potentials (pair_style kim) need kim-api downloaded at build time and are on no hosted image yet — ask and we add it"])
    }()
    func testRouteKeepsDefaultWhenItSuffices() throws {
        let (r, pf) = DeckPreflight.route(input: try deck(["in.lmp": "pair_style lj/cut 2.5\nfix 1 all nve\nrun 1\n"]), caps: Self.routedCaps)
        XCTAssertNil(r); XCTAssertNil(pf.routedTo); XCTAssertTrue(pf.ok); XCTAssertEqual(pf.lines(), [])
    }
    func testRouteSendsMissingStyleToFullImage() throws {
        let (r, pf) = DeckPreflight.route(input: try deck(["in.lmp": "pair_style meam\npair_coeff * * lib.meam Al NULL Al\nfix 1 all nve\nrun 1\n"]), caps: Self.routedCaps)
        XCTAssertEqual(r, "lammps-full"); XCTAssertEqual(pf.routedTo, "lammps-full"); XCTAssertEqual(pf.routedBecause, ["meam"])
        XCTAssertTrue(pf.ok); XCTAssertFalse(pf.needsAttention); XCTAssertEqual(pf.usesGPU, true)
        XCTAssertTrue(pf.lines()[0].hasPrefix("Routed to the full LAMMPS image (lammps-full): meam")); XCTAssertTrue(pf.lines()[0].contains("~40 s"))
    }
    func testRouteNamesEveryImageWhenNothingSatisfies() throws {
        let (r, pf) = DeckPreflight.route(input: try deck(["in.lmp": "pair_style bogus/style 1.0\nrun 1\n"]), caps: Self.routedCaps)
        XCTAssertNil(r); XCTAssertFalse(pf.ok); XCTAssertEqual(pf.tried, ["lammps", "lammps-full"])
        XCTAssertTrue(pf.lines()[0].contains("not built into any hosted LAMMPS image (checked: lammps, lammps-full)"))
    }
    func testRouteNamesKIMAsTheDecidedExclusion() throws {
        let (_, pf) = DeckPreflight.route(input: try deck(["in.lmp": "pair_style kim SW_StillingerWeber_1985_Si__MO_405512056662_006\nrun 1\n"]), caps: Self.routedCaps)
        XCTAssertFalse(pf.ok); XCTAssertTrue(pf.lines()[0].contains("kim-api")); XCTAssertTrue(pf.lines()[0].contains("OpenKIM"))
    }
    func testRouteWithoutRoutingBlockIsTheOldBehaviour() throws {
        let plain = HostedCapabilities(runners: ["lammps": Self.caps], default_runner: "lammps", rates: ["any": 2.0])
        let (r, pf) = DeckPreflight.route(input: try deck(["in.lmp": "pair_style meam\nrun 1\n"]), caps: plain)
        XCTAssertNil(r); XCTAssertFalse(pf.ok); XCTAssertEqual(pf.tried, ["lammps"]); XCTAssertTrue(pf.lines()[0].contains("not built into the hosted LAMMPS image"))
    }
    func testRoutingBlockDecodes() throws {
        let json = """
        {"runners": {"lammps": {"engine": "lammps"}, "lammps-full": {"engine": "lammps"}}, "default_runner": "lammps",
         "routing": {"default": "lammps", "fallbacks": ["lammps-full"], "note": "x"}, "excluded_packages": {"KIM": "why"}}
        """
        let caps = try JSONDecoder().decode(HostedCapabilities.self, from: Data(json.utf8))
        XCTAssertEqual(caps.routing?.fallbacks, ["lammps-full"]); XCTAssertEqual(caps.routing?.defaultRunner, "lammps"); XCTAssertEqual(caps.excluded_packages?["KIM"], "why")
    }

    // ---- launch line (GJOB-126): mirror of test_caps.py LaunchRules --------------------------------
    func mode(_ files: [String: String]) throws -> DeckPreflight {
        DeckPreflight.check(input: try deck(files), caps: Self.caps)
    }
    func testDefaultDeckKeepsTheGPULine() throws {
        let r = try mode(["in.lmp": "atom_style atomic\npair_style lj/cut 2.5\nfix 1 all nve\nrun 100\n"])
        XCTAssertEqual(r.launchMode, .kokkos); XCTAssertTrue(r.launchBecause.isEmpty); XCTAssertEqual(r.usesGPU, true)
    }
    func testAtomStyleWithoutAKKVariantDropsToPlain() throws {
        let r = try mode(["in.lmp": "atom_style body nparticle 2 4\npair_style lj/cut 2.5\nrun 1\n"])
        XCTAssertEqual(r.launchMode, .plain); XCTAssertEqual(r.launchBecause.first?.what, "atom_style body")
        XCTAssertEqual(r.launchBecause.first?.line, 1); XCTAssertEqual(r.usesGPU, false)
        let said = r.lines(rateHint: "$2.00/h").joined(separator: " ")
        XCTAssertTrue(said.contains("WITHOUT the GPU accelerator")); XCTAssertTrue(said.contains("$2.00/h"))
        XCTAssertFalse(said.contains("has no KOKKOS (/kk) version"))          // one explanation, not two
    }
    func testAtomStyleHybridAndBondStyleHybrid() throws {
        XCTAssertEqual(try mode(["in.lmp": "atom_style hybrid sphere dipole\nrun 1\n"]).launchBecause.first?.what, "atom_style hybrid")
        XCTAssertEqual(try mode(["in.lmp": "atom_style full\nbond_style hybrid harmonic morse\nrun 1\n"]).launchBecause.first?.what, "bond_style hybrid")
    }
    func testBlockedFixesAndComputeTally() throws {
        for (line, what) in [("fix ins all pour 3000 1 300719 vol 0.13 50 region slab", "fix pour"),
                             ("fix 1 all shardlow", "fix shardlow"),
                             ("fix m g gcmc 1 100 100 1 29494 300 -8 0.1", "fix gcmc"),
                             ("fix 2 small srd 20 big 1.0 0.25 49894", "fix srd"),
                             ("compute c1 one force/tally all", "compute force/tally")] {
            let r = try mode(["in.lmp": "atom_style atomic\n\(line)\nrun 1\n"])
            XCTAssertEqual(r.launchMode, .plain, line); XCTAssertEqual(r.launchBecause.first?.what, what)
        }
    }
    func testBareNonBinNeighborIsNotABlocker() throws {                        // COLLOID / PHONON pass under -sf kk
        for n in ["multi", "nsq"] {
            XCTAssertEqual(try mode(["in.lmp": "atom_style atomic\nneighbor 1 \(n)\ncomm_modify mode multi\nfix 1 all nve\nrun 1\n"]).launchMode, .kokkos, n)
        }
    }
    func testLabelMapsByCommandAndByDataFile() throws {
        XCTAssertEqual(try mode(["in.lmp": "atom_style full\nlabelmap atom 1 C\nrun 1\n"]).launchBecause.first?.what, "labelmap")
        let r = try mode(["in.lmp": "atom_style full\nread_data trimer.data\nrun 1\n",
                          "trimer.data": "LAMMPS data\n\n2 atoms\n\nAtom Type Labels\n\n1 C\n"])
        XCTAssertEqual(r.launchMode, .plain); XCTAssertTrue(r.launchBecause.first!.why.contains("type labels"))
        XCTAssertEqual(try mode(["in.lmp": "atom_style full\nread_data plain.data\nrun 1\n",
                                 "plain.data": "LAMMPS data\n\n2 atoms\n\nMasses\n\n1 1.0\n"]).launchMode, .kokkos)
    }
    func testFixModifyEnergyOnlyWhenTheFixHasAKKVariant() throws {
        let r = try mode(["in.lmp": "atom_style full\nfix 1 all nvt temp 300 300 100\nfix_modify 1 energy yes\nrun 1\n"])
        XCTAssertEqual(r.launchMode, .plain); XCTAssertEqual(r.launchBecause.first?.what, "fix_modify 1 energy")
        XCTAssertEqual(try mode(["in.lmp": "atom_style full\nfix 1 all ave/time 1 1 1 c_pe\nfix_modify 1 energy yes\nrun 1\n"]).launchMode, .kokkos)
    }
    func testLaunchRulesFollowIncludeAndNameTheIncludedFile() throws {
        let r = try mode(["in.lmp": "include sub.lmp\nrun 1\n", "sub.lmp": "atom_style peri\n"])
        XCTAssertEqual(r.launchMode, .plain); XCTAssertEqual(r.launchBecause.first?.file, "sub.lmp")
    }
    func testAVariableAtomStyleIsNeverGuessed() throws {
        XCTAssertEqual(try mode(["in.lmp": "atom_style ${style}\nrun 1\n"]).launchMode, .kokkos)
    }
}
