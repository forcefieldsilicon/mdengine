import XCTest
@testable import LAMMPSCore

final class XYZParserTests: XCTestCase {
    func testMultiFrame() {
        let text = """
        2
        frame 0
        Ar 0.0 0.0 0.0
        Ar 1.0 1.0 1.0
        2
        frame 1
        Ar 0.1 0.0 0.0
        Ar 1.1 1.0 1.0
        """
        let frames = XYZParser.parseFrames(text)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[1][0].x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(XYZParser.parseLastFrame(text)[1].x, 1.1, accuracy: 1e-12)
    }

    func testNonFiniteRowsDropped() {
        let text = """
        3
        one bad row
        Ar 0.0 0.0 0.0
        Ar nan 1.0 1.0
        Ar 2.0 2.0 2.0
        """
        let frame = XYZParser.parseLastFrame(text)
        XCTAssertEqual(frame.count, 2)
        XCTAssertTrue(frame.allSatisfy { $0.x.isFinite })
    }

    func testTruncatedFrameIgnored() {
        let text = """
        2
        complete
        Ar 0.0 0.0 0.0
        Ar 1.0 1.0 1.0
        5
        truncated tail (in-flight write)
        Ar 0.0 0.0 0.0
        """
        XCTAssertEqual(XYZParser.parseFrames(text).count, 1)
    }
}

final class LammpsDumpParserTests: XCTestCase {
    private let customDump = """
    ITEM: TIMESTEP
    100
    ITEM: NUMBER OF ATOMS
    3
    ITEM: BOX BOUNDS pp pp ff
    0.0 10.0
    0.0 10.0
    0.0 20.0
    ITEM: ATOMS id type x y z q
    2 1 1.0 2.0 3.0 -0.5
    1 2 4.0 5.0 6.0 0.25
    3 1 7.0 8.0 9.0 0.0
    """

    func testHeaderMappedColumnsChargesAndIdSort() {
        let frames = LammpsDumpParser.parseFrames(customDump)
        XCTAssertEqual(frames.count, 1)
        let frame = frames[0]
        XCTAssertEqual(frame.count, 3)
        // sorted by id: atom id 1 first (type 2 at 4,5,6 with q 0.25)
        XCTAssertEqual(frame[0].element, "2")
        XCTAssertEqual(frame[0].x, 4.0, accuracy: 1e-12)
        XCTAssertEqual(frame[0].charge ?? .nan, 0.25, accuracy: 1e-12)
        XCTAssertEqual(frame[1].charge ?? .nan, -0.5, accuracy: 1e-12)
    }

    func testScaledCoordinatesMapThroughBox() {
        let scaled = """
        ITEM: TIMESTEP
        0
        ITEM: NUMBER OF ATOMS
        1
        ITEM: BOX BOUNDS pp pp pp
        -5.0 15.0
        0.0 10.0
        0.0 40.0
        ITEM: ATOMS id type xs ys zs
        1 1 0.5 0.25 1.0
        """
        let atom = LammpsDumpParser.parseFrames(scaled)[0][0]
        XCTAssertEqual(atom.x, 5.0, accuracy: 1e-9)   // -5 + 0.5*20
        XCTAssertEqual(atom.y, 2.5, accuracy: 1e-9)
        XCTAssertEqual(atom.z, 40.0, accuracy: 1e-9)
    }

    func testElementColumnPreferredOverType() {
        let dump = """
        ITEM: TIMESTEP
        0
        ITEM: NUMBER OF ATOMS
        1
        ITEM: BOX BOUNDS pp pp pp
        0 1
        0 1
        0 1
        ITEM: ATOMS id type element x y z
        1 2 Fe 0.1 0.2 0.3
        """
        XCTAssertEqual(LammpsDumpParser.parseFrames(dump)[0][0].element, "Fe")
    }

    func testGrowingAtomCountAndTruncatedTail() {
        let dump = """
        ITEM: TIMESTEP
        0
        ITEM: NUMBER OF ATOMS
        1
        ITEM: BOX BOUNDS pp pp pp
        0 1
        0 1
        0 1
        ITEM: ATOMS id type x y z
        1 1 0.1 0.1 0.1
        ITEM: TIMESTEP
        10
        ITEM: NUMBER OF ATOMS
        2
        ITEM: BOX BOUNDS pp pp pp
        0 1
        0 1
        0 1
        ITEM: ATOMS id type x y z
        1 1 0.1 0.1 0.1
        2 1 0.2 0.2 0.2
        ITEM: TIMESTEP
        20
        ITEM: NUMBER OF ATOMS
        9
        ITEM: BOX BOUNDS pp pp pp
        0 1
        """
        let frames = LammpsDumpParser.parseFrames(dump)
        XCTAssertEqual(frames.count, 2)                 // in-flight tail ignored
        XCTAssertEqual(frames.map(\.count), [1, 2])     // growing count preserved
    }

    func testNaNCoordinatesDropped() {
        let dump = """
        ITEM: TIMESTEP
        0
        ITEM: NUMBER OF ATOMS
        2
        ITEM: BOX BOUNDS pp pp pp
        0 1
        0 1
        0 1
        ITEM: ATOMS id type x y z
        1 1 nan 0.1 0.1
        2 1 0.2 0.2 0.2
        """
        let frame = LammpsDumpParser.parseFrames(dump)[0]
        XCTAssertEqual(frame.count, 1)
        XCTAssertEqual(frame[0].x, 0.2, accuracy: 1e-12)
    }
}

final class TrajectoryReaderWriterTests: XCTestCase {
    func testFormatSniffing() {
        XCTAssertTrue(TrajectoryReader.isNativeDump("ITEM: TIMESTEP\n0\n"))
        XCTAssertFalse(TrajectoryReader.isNativeDump("3\ncomment\nAr 0 0 0\n"))
    }

    func testDumpFields() {
        let dump = "ITEM: TIMESTEP\n0\nITEM: NUMBER OF ATOMS\n1\nITEM: BOX BOUNDS pp pp pp\n0 1\n0 1\n0 1\nITEM: ATOMS id type x y z q\n1 1 0 0 0 0\n"
        XCTAssertEqual(TrajectoryReader.dumpFields(dump), ["id", "type", "x", "y", "z", "q"])
        XCTAssertNil(TrajectoryReader.dumpFields("2\nxyz file\n"))
    }

    func testChargeRoundTripThroughExtendedXYZ() {
        let atoms = [Arv(element: "O", x: 1, y: 2, z: 3, charge: -1.05)]
        let text = TrajectoryWriter.xyz([atoms], comment: "t", charges: true)
        XCTAssertTrue(text.contains("Properties=species:S:1:pos:R:3:charge:R:1"))
        XCTAssertTrue(text.contains("O 1.0 2.0 3.0 -1.05"))
        // plain XYZ omits the charge column
        let plain = TrajectoryWriter.xyz([atoms], comment: "t")
        XCTAssertTrue(plain.contains("O 1.0 2.0 3.0\n"))
    }
}
