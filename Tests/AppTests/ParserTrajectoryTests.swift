import XCTest
@testable import LAMMPSCore

final class ParserTrajectoryTests: XCTestCase {

    // MARK: - LAMMPS dump

    /// ids deliberately out of order: rows sort by id and the extra columns
    /// must follow the same permutation.
    private let dump = """
    ITEM: TIMESTEP
    5000
    ITEM: NUMBER OF ATOMS
    3
    ITEM: BOX BOUNDS pp pp ff
    0.0 10.0
    -2.0 8.0
    0.0 30.0
    ITEM: ATOMS id type x y z q c_pe
    3 2 3.0 3.1 3.2 -1.5 -4.5
    1 1 1.0 1.1 1.2 0.5 -1.5
    2 1 2.0 2.1 2.2 0.5 -2.5

    """

    func testDumpTrajectoryFillsBoxTimestepAndColumns() throws {
        let frames = LammpsDumpParser.parseTrajectory(dump)
        XCTAssertEqual(frames.count, 1)
        let f = frames[0]

        XCTAssertEqual(f.timestep, 5000)
        let box = try XCTUnwrap(f.box)
        XCTAssertEqual(box.lo.y, -2.0, accuracy: 1e-12)
        XCTAssertEqual(box.hi.z, 30.0, accuracy: 1e-12)
        XCTAssertEqual(box.lengths.x, 10.0, accuracy: 1e-12)
        XCTAssertTrue(box.periodicX)
        XCTAssertFalse(box.periodicZ)           // "ff"
        XCTAssertFalse(box.isTriclinic)

        XCTAssertEqual(f.atoms.map(\.id), [1, 2, 3])
        XCTAssertEqual(f.atoms.map(\.element), ["1", "1", "2"])
        XCTAssertEqual(f.column("q"), [0.5, 0.5, -1.5])
        XCTAssertEqual(f.column("c_pe"), [-1.5, -2.5, -4.5])
        XCTAssertNil(f.column("type"))          // consumed as the element token
        XCTAssertEqual(f.atoms[0].charge!, 0.5, accuracy: 1e-12)
    }

    func testParseFramesIsUnchangedByTheTrajectoryWrapper() {
        let atoms = LammpsDumpParser.parseFrames(dump)
        XCTAssertEqual(atoms.count, 1)
        XCTAssertEqual(atoms[0].count, 3)
        XCTAssertEqual(atoms[0].map(\.x), [1.0, 2.0, 3.0])
        XCTAssertEqual(TrajectoryReader.parseFrames(dump)[0].count, 3)
    }

    func testTriclinicTiltIsKept() throws {
        let text = dump
            .replacingOccurrences(of: "ITEM: BOX BOUNDS pp pp ff",
                                  with: "ITEM: BOX BOUNDS xy xz yz pp pp pp")
            .replacingOccurrences(of: "0.0 10.0\n", with: "0.0 10.0 1.5\n")
        let box = try XCTUnwrap(LammpsDumpParser.parseTrajectory(text).first?.box)
        XCTAssertTrue(box.isTriclinic)
        XCTAssertEqual(box.tilt!.x, 1.5, accuracy: 1e-12)
        XCTAssertTrue(box.periodicZ)
    }

    /// The in-flight-dump guarantee: a truncated final frame is dropped.
    func testTruncatedDumpTailStillDropped() {
        let truncated = dump + """
        ITEM: TIMESTEP
        6000
        ITEM: NUMBER OF ATOMS
        3
        ITEM: BOX BOUNDS pp pp pp
        0.0 10.0
        0.0 10.0
        0.0 10.0
        ITEM: ATOMS id type x y z q c_pe
        1 1 1.0 1.1 1.2 0.5 -1.5
        """
        XCTAssertEqual(LammpsDumpParser.parseTrajectory(truncated).count, 1)
    }

    // MARK: - Extended XYZ

    private let extxyz = """
    2
    Lattice="12.0 0.0 0.0 0.0 13.0 0.0 0.0 0.0 14.0" Properties=species:S:1:pos:R:3:charge:R:1:resname:S:1 pbc="T T F"
    O 1.0 2.0 3.0 -0.8 TYR
    H 1.5 2.5 3.5 0.4 GLY
    """

    func testExtendedXYZLatticeAndProperties() throws {
        let frames = XYZParser.parseTrajectory(extxyz)
        XCTAssertEqual(frames.count, 1)
        let f = frames[0]
        let box = try XCTUnwrap(f.box)
        XCTAssertEqual(box.hi.x, 12.0, accuracy: 1e-12)
        XCTAssertEqual(box.hi.z, 14.0, accuracy: 1e-12)
        XCTAssertTrue(box.periodicY)
        XCTAssertFalse(box.periodicZ)
        XCTAssertNil(box.tilt)

        XCTAssertEqual(f.column("charge"), [-0.8, 0.4])
        XCTAssertEqual(f.label("resname"), ["TYR", "GLY"])
        XCTAssertEqual(f.atoms.map(\.element), ["O", "H"])
        // Extra columns stay off Arv so the render path is untouched.
        XCTAssertNil(f.atoms[0].charge)
    }

    func testPlainXYZUnchanged() {
        let plain = "2\ncomment\nFe 0.0 0.0 0.0\nFe 1.0 1.0 1.0\n"
        let frames = XYZParser.parseTrajectory(plain)
        XCTAssertEqual(frames[0].atoms.count, 2)
        XCTAssertNil(frames[0].box)
        XCTAssertTrue(frames[0].columns.isEmpty)
        XCTAssertEqual(XYZParser.parseLastFrame(plain).count, 2)
        XCTAssertEqual(XYZParser.parseFrames(plain)[0].map(\.element), ["Fe", "Fe"])
    }

    func testMultiComponentPropertySuffixes() {
        let text = """
        1
        Properties=species:S:1:pos:R:3:vel:R:3
        Fe 0.0 0.0 0.0 0.1 0.2 0.3
        """
        let f = XYZParser.parseTrajectory(text)[0]
        XCTAssertEqual(f.column("vel_x"), [0.1])
        XCTAssertEqual(f.column("vel_z"), [0.3])
    }
}
