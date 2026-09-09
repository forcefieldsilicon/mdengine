import XCTest
@testable import LAMMPSCore

/// The inspector's GroupSelectorEditor emits these exact JSON shapes; they must
/// decode to the selectors the Adhesion tool expects.
final class GroupSelectorJSONTests: XCTestCase {
    private func decode(_ obj: [String: Any]) throws -> GroupSelector {
        try JSONDecoder().decode(GroupSelector.self, from: JSONSerialization.data(withJSONObject: obj))
    }

    func testEditorShapesDecode() throws {
        XCTAssertEqual(try decode(["kind": "all"]), .all)
        XCTAssertEqual(try decode(["kind": "elements", "elements": ["Al", "O"]]), .elements(["Al", "O"]))
        XCTAssertEqual(try decode(["kind": "label", "name": "chain", "values": ["A"]]),
                       .label(name: "chain", values: ["A"]))
        XCTAssertEqual(try decode(["kind": "slab", "axis": "z", "min": 0, "max": 10]),
                       .slab(axis: .z, min: 0, max: 10))
    }

    func testAdhesionParametersRoundTripWithEditorJSON() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "groupA": ["kind": "label", "name": "chain", "values": ["A"]],
            "groupB": ["kind": "elements", "elements": ["C", "N", "O"]],
            "contactCutoff": 4.0, "hbondDistance": 3.5, "hbondAngle": 120, "perResidue": true
        ])
        let p = try JSONDecoder().decode(AdhesionTool.Parameters.self, from: json)
        XCTAssertEqual(p.groupA, .label(name: "chain", values: ["A"]))
        XCTAssertEqual(p.groupB, .elements(["C", "N", "O"]))
        XCTAssertEqual(p.contactCutoff, 4.0)
    }
}
