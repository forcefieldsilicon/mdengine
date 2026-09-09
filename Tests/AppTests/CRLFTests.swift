import XCTest
@testable import LAMMPSCore

/// Windows-authored trajectories, decks and logs use CRLF line endings, and
/// `\r\n` is ONE Swift Character — so `split(separator: "\n")` does not split
/// such a file at all. Before the 2026-09-07 fix a CRLF XYZ parsed to ZERO
/// frames, a CRLF native dump lost every frame (the `ITEM: ATOMS` header's last
/// column read as `"z\r"`, so the column lookup missed and each frame was
/// discarded as malformed), and a CRLF deck preflighted as one giant line.
/// These fixtures pin LF == CRLF == CR for every text a *user* hands us.
final class CRLFTests: XCTestCase {
    private func crlf(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\r\n") }
    private func cr(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "\r") }

    // MARK: - XYZ

    private static let xyz = """
    2
    frame 0
    Ar 0.0 0.0 0.0
    Ar 1.0 1.0 1.0
    2
    frame 1
    Fe 0.1 0.0 0.0
    O 1.1 1.0 2.5

    """

    func testXYZCRLFMatchesLF() {
        let lf = XYZParser.parseFrames(Self.xyz)
        let win = XYZParser.parseFrames(crlf(Self.xyz))
        XCTAssertEqual(lf.count, 2)
        XCTAssertEqual(win.count, lf.count)
        guard win.count == 2, win[1].count == 2 else { return XCTFail("CRLF XYZ parsed to \(win.count) frames") }
        XCTAssertEqual(win.map { $0.map(\.element) }, lf.map { $0.map(\.element) })
        XCTAssertEqual(win[1].map(\.element), ["Fe", "O"])   // no "\r" glued on
        XCTAssertEqual(win[1][1].z, 2.5, accuracy: 1e-12)    // last column parses
        XCTAssertEqual(win[0][1].x, 1.0, accuracy: 1e-12)
    }

    func testXYZClassicMacCR() {
        let frames = XYZParser.parseFrames(cr(Self.xyz))
        XCTAssertEqual(frames.count, 2)
        guard frames.count == 2, frames[1].count == 2 else { return XCTFail("CR XYZ parsed to \(frames.count) frames") }
        XCTAssertEqual(frames[1].map(\.element), ["Fe", "O"])
        XCTAssertEqual(frames[1][1].z, 2.5, accuracy: 1e-12)
    }

    // MARK: - Native dump

    /// `element` is the LAST column: CRLF puts `\r` inside the element token.
    private static let dumpElementLast = """
    ITEM: TIMESTEP
    0
    ITEM: NUMBER OF ATOMS
    2
    ITEM: BOX BOUNDS pp pp pp
    0.0 10.0
    0.0 10.0
    0.0 10.0
    ITEM: ATOMS id type x y z element
    1 1 1.0 2.0 3.0 Fe
    2 2 4.0 5.0 6.0 O

    """

    /// `z` is the LAST column: CRLF used to break the column lookup itself and
    /// the whole frame was dropped.
    private static let dumpCoordLast = """
    ITEM: TIMESTEP
    10
    ITEM: NUMBER OF ATOMS
    2
    ITEM: BOX BOUNDS pp pp pp
    0.0 10.0
    0.0 10.0
    0.0 10.0
    ITEM: ATOMS id element x y z
    1 Fe 1.0 2.0 3.0
    2 O 4.0 5.0 6.5

    """

    func testDumpCRLFElementColumnLast() {
        let lf = LammpsDumpParser.parseFrames(Self.dumpElementLast)
        let win = LammpsDumpParser.parseFrames(crlf(Self.dumpElementLast))
        XCTAssertEqual(lf.count, 1)
        XCTAssertEqual(win.count, 1, "CRLF dump lost its frames")
        guard win.count == 1, win[0].count == 2 else { return XCTFail("CRLF dump parsed to \(win.count) frames") }
        XCTAssertEqual(win[0].map(\.element), ["Fe", "O"])
        XCTAssertEqual(win[0].map(\.element), lf[0].map(\.element))
        XCTAssertEqual(win[0][1].z, 6.0, accuracy: 1e-12)
    }

    func testDumpCRLFCoordinateColumnLast() {
        let win = LammpsDumpParser.parseFrames(crlf(Self.dumpCoordLast))
        XCTAssertEqual(win.count, 1, "CRLF broke the ITEM: ATOMS column lookup")
        guard win.count == 1, win[0].count == 2 else { return XCTFail("CRLF dump parsed to \(win.count) frames") }
        XCTAssertEqual(win[0].map(\.element), ["Fe", "O"])
        XCTAssertEqual(win[0][1].z, 6.5, accuracy: 1e-12)
    }

    func testDumpCRLFThroughTrajectoryReaderAndFields() {
        let win = crlf(Self.dumpElementLast)
        XCTAssertTrue(TrajectoryReader.isNativeDump(win))
        XCTAssertEqual(TrajectoryReader.parseFrames(win).count, 1)
        XCTAssertEqual(TrajectoryReader.dumpFields(win),
                       ["id", "type", "x", "y", "z", "element"])
    }

    // MARK: - Deck preflight (Windows-authored input script)

    private static let caps: HostedRunnerCapabilities = {
        func s(_ gpu: Bool, _ v: [String] = []) -> HostedStyleInfo { HostedStyleInfo(gpu: gpu, variants: v) }
        return HostedRunnerCapabilities(engine: "lammps", lammps_version: "29 Aug 2024",
            image: "img:test", accelerator: "kokkos/cuda", packages: ["KOKKOS"],
            styles: ["pair": ["lj/cut": s(true, ["kk"])], "fix": ["nve": s(true, ["kk"])]])
    }()

    private func deckURL(_ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mde-crlf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("in.lmp")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testCRLFDeckPreflightsLikeLF() throws {
        let deck = "pair_style meam\npair_coeff * * lib.meam Al NULL Al\nrun 10\n"
        let lf = DeckPreflight.check(input: try deckURL(deck), caps: Self.caps)
        let win = DeckPreflight.check(input: try deckURL(crlf(deck)), caps: Self.caps)
        XCTAssertFalse(lf.ok)
        XCTAssertEqual(win.ok, lf.ok, "CRLF deck read as one line — preflight blind")
        XCTAssertEqual(win.lines(), lf.lines())
    }

    func testCRLFDeckAllGPUStaysSilent() throws {
        let deck = "pair_style lj/cut 2.5\nfix 1 all nve\nrun 100\n"
        let win = DeckPreflight.check(input: try deckURL(crlf(deck)), caps: Self.caps)
        XCTAssertTrue(win.ok)
        XCTAssertEqual(win.usesGPU, true)
        XCTAssertEqual(win.lines(), [])
    }
}
