//
//  Frame.swift — one trajectory snapshot: atoms + cell + per-atom extra columns.
//
//  Extra per-atom data (charge from a dump's `q`, `c_pe`, velocities, chain /
//  resname labels from an extended XYZ) lives HERE, per frame, as Float32
//  columns — deliberately NOT on `Arv`, so the renderer's per-atom hot path and
//  its memory footprint are untouched by analysis features.
//

import Foundation

public struct Frame {
    public var atoms: [Arv]
    /// nil when the source file carried no cell (plain XYZ); tools that need
    /// PBC declare `.box` and stay idle.
    public var box: SimulationBox?
    public var timestep: Int?
    /// Numeric per-atom columns by name ("q", "c_pe", "vx"…). Each array is
    /// parallel to `atoms`; Float32 keeps big trajectories affordable.
    public var columns: [String: [Float]]
    /// String per-atom columns by name ("resname", "chain"…), parallel to `atoms`.
    public var labels: [String: [String]]

    public init(atoms: [Arv],
                box: SimulationBox? = nil,
                timestep: Int? = nil,
                columns: [String: [Float]] = [:],
                labels: [String: [String]] = [:]) {
        self.atoms = atoms
        self.box = box
        self.timestep = timestep
        self.columns = columns
        self.labels = labels
    }

    public var count: Int { atoms.count }

    /// Positions as SIMD, for the neighbour list and geometry tools.
    public var positions: [SIMD3<Double>] {
        atoms.map { SIMD3($0.x, $0.y, $0.z) }
    }

    /// A numeric column, only when it is actually parallel to `atoms`
    /// (a short/stale column would silently misattribute values).
    public func column(_ name: String) -> [Float]? {
        guard let c = columns[name], c.count == atoms.count else { return nil }
        return c
    }

    public func label(_ name: String) -> [String]? {
        guard let l = labels[name], l.count == atoms.count else { return nil }
        return l
    }
}

public typealias Trajectory = [Frame]
