//
//  Groups.swift — "which atoms are A and which are B".
//
//  Every adhesion/binding study is about two groups: receptor and ligand,
//  substrate and probe. Biomolecular frames name them with `chain`/`resname`
//  labels (extended XYZ from `smd_pull.py`); inorganic interfaces have neither,
//  so an element set or a spatial slab has to do. One selector type covers all
//  three, and `suggestPair` picks a sensible default so a tool can run on a
//  freshly opened trajectory without the user configuring anything first.
//

import Foundation

/// How a group of atoms is chosen. Codable by hand with an explicit `kind` key
/// so the JSON that travels through MCP/CLI parameters stays readable:
/// `{"kind":"label","name":"chain","values":["A"]}`.
public enum GroupSelector: Codable, Equatable {
    case elements([String])
    /// A per-atom string label and the values that belong to the group (chain A).
    case label(name: String, values: [String])
    /// Everything between `min` and `max` (inclusive) along one axis.
    case slab(axis: Axis, min: Double, max: Double)
    case all

    private enum CodingKeys: String, CodingKey { case kind, elements, name, values, axis, min, max }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .elements(let symbols):
            try c.encode("elements", forKey: .kind)
            try c.encode(symbols, forKey: .elements)
        case .label(let name, let values):
            try c.encode("label", forKey: .kind)
            try c.encode(name, forKey: .name)
            try c.encode(values, forKey: .values)
        case .slab(let axis, let lo, let hi):
            try c.encode("slab", forKey: .kind)
            try c.encode(axis, forKey: .axis)
            try c.encode(lo, forKey: .min)
            try c.encode(hi, forKey: .max)
        case .all:
            try c.encode("all", forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "elements":
            self = .elements(try c.decode([String].self, forKey: .elements))
        case "label":
            self = .label(name: try c.decode(String.self, forKey: .name),
                          values: try c.decode([String].self, forKey: .values))
        case "slab":
            self = .slab(axis: try c.decode(Axis.self, forKey: .axis),
                         min: try c.decode(Double.self, forKey: .min),
                         max: try c.decode(Double.self, forKey: .max))
        case "all":
            self = .all
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "Unknown group kind “\(other)”.")
        }
    }

    /// Human-readable form, used in the tool's notes and summary.
    public var describedText: String {
        switch self {
        case .elements(let s): return "elements \(s.joined(separator: ", "))"
        case .label(let name, let values): return "\(name) = \(values.joined(separator: ", "))"
        case .slab(let axis, let lo, let hi):
            return String(format: "slab %@ %.2f…%.2f Å", axis.label, lo, hi)
        case .all: return "all atoms"
        }
    }
}

public enum Groups {
    /// "cl" / "CL" / "Cl" all mean chlorine; numeric type tokens pass through.
    public static func normalizedElement(_ symbol: String) -> String {
        let t = symbol.trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return t }
        return String(first).uppercased() + t.dropFirst().lowercased()
    }

    /// Atom indices selected by `sel`. An unknown label name or an element that
    /// is not present selects nothing (the caller reports the empty group; it
    /// never silently becomes "everything").
    public static func indices(_ sel: GroupSelector, in frame: Frame) -> [Int] {
        switch sel {
        case .all:
            return Array(0..<frame.count)
        case .elements(let symbols):
            let want = Set(symbols.map(normalizedElement))
            return frame.atoms.indices.filter { want.contains(normalizedElement(frame.atoms[$0].element)) }
        case .label(let name, let values):
            guard let column = frame.label(name) else { return [] }
            let want = Set(values.map { $0.trimmingCharacters(in: .whitespaces) })
            return column.indices.filter { want.contains(column[$0].trimmingCharacters(in: .whitespaces)) }
        case .slab(let axis, let lo, let hi):
            let (low, high) = lo <= hi ? (lo, hi) : (hi, lo)
            return frame.atoms.indices.filter { i in
                let a = frame.atoms[i]
                let v = axis == .x ? a.x : (axis == .y ? a.y : a.z)
                return v >= low && v <= high
            }
        }
    }

    /// A default A/B pair for a frame nobody has configured yet: chains first
    /// (what a pull-off run carries), then residue names, then elements.
    /// nil when the frame offers no way to split it in two.
    public static func suggestPair(_ frame: Frame) -> (a: GroupSelector, b: GroupSelector)? {
        for name in ["chain", "resname"] {
            if let column = frame.label(name), let (first, second) = topTwo(column) {
                return (.label(name: name, values: [first]), .label(name: name, values: [second]))
            }
        }
        let elements = frame.atoms.map { normalizedElement($0.element) }
        if let (first, second) = topTwo(elements) {
            return (.elements([first]), .elements([second]))
        }
        return nil
    }

    /// The two most populous values, ties broken alphabetically so the choice is
    /// reproducible run to run. nil when there are fewer than two distinct ones.
    private static func topTwo(_ values: [String]) -> (String, String)? {
        var counts: [String: Int] = [:]
        for v in values {
            let key = v.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            counts[key, default: 0] += 1
        }
        guard counts.count >= 2 else { return nil }
        let ranked = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        return (ranked[0].key, ranked[1].key)
    }

    /// Atomic masses (u) for COM work. Deliberately small: the table covers what
    /// biomolecular and the common inorganic frames contain, and anything
    /// unknown weighs 12 so an exotic element shifts the COM rather than
    /// vanishing from it.
    public static let unknownMass = 12.0
    private static let masses: [String: Double] = [
        "H": 1.008, "D": 2.014, "He": 4.003, "Li": 6.94, "Be": 9.012, "B": 10.81,
        "C": 12.011, "N": 14.007, "O": 15.999, "F": 18.998, "Ne": 20.180,
        "Na": 22.990, "Mg": 24.305, "Al": 26.982, "Si": 28.085, "P": 30.974,
        "S": 32.06, "Cl": 35.45, "Ar": 39.948, "K": 39.098, "Ca": 40.078,
        "Ti": 47.867, "Cr": 51.996, "Mn": 54.938, "Fe": 55.845, "Co": 58.933,
        "Ni": 58.693, "Cu": 63.546, "Zn": 65.38, "Br": 79.904, "Ag": 107.868,
        "Sn": 118.710, "I": 126.904, "Pt": 195.084, "Au": 196.967
    ]

    public static func mass(of element: String) -> Double {
        masses[normalizedElement(element)] ?? unknownMass
    }

    /// Mass-weighted centre of mass of `indices`. Positions are used as stored:
    /// a group split across a periodic boundary is the caller's problem to note,
    /// not something to silently "fix" here.
    public static func centerOfMass(_ indices: [Int], in frame: Frame) -> SIMD3<Double> {
        var sum = SIMD3<Double>(repeating: 0)
        var total = 0.0
        for i in indices where i >= 0 && i < frame.count {
            let a = frame.atoms[i]
            let m = mass(of: a.element)
            sum += SIMD3(a.x, a.y, a.z) * m
            total += m
        }
        return total > 0 ? sum / total : sum
    }
}
