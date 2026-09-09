//
//  TemplateMatching.swift — the geometry half of polyhedral template matching.
//
//  Larsen, Schmidt & Schiøtz 2016 (Modelling Simul. Mater. Sci. Eng. 24 055007).
//  For each atom the N nearest neighbour vectors are scaled to unit mean length
//  and compared against ideal templates (also unit mean length). Following the
//  paper the point set is the N neighbours *and* the central atom, both sides
//  shifted to their own centroid, so the answer is the correspondence (which
//  neighbour sits on which template vertex) and the rotation that minimise
//
//      RMSD = √( 1/(N+1) · [ Σ |bᵢ − b̄ − R a_{π(i)}|² + |b̄|² ] )
//
//  Centring matters more than it looks: the displacement of the *central* atom
//  is common to all N measured vectors, so leaving it in would put it into
//  every residual and inflate the RMSD by √2 on a hot frame.
//
//  This is a deliberately short port: the paper's Weinberg canonical-form graph
//  hashing, which turns the correspondence search into a table lookup, is *not*
//  implemented. Instead the correspondence is seeded geometrically and refined,
//  which costs more per atom but is a page of code you can check by eye.
//
//  The one non-obvious economy is the seed set. Applying a symmetry g of a
//  template to a correspondence π gives another correspondence π∘g with the
//  same RMSD (and the rotation R g⁻¹), so the minimum over *all* correspondences
//  is already reached by those that send the atom's nearest neighbour to one
//  fixed vertex per orbit of the template's proper rotation group. fcc, ico and
//  simple cubic are vertex-transitive (one orbit); bcc splits into its eight
//  ⟨111⟩ and six ⟨100⟩ neighbours; hcp into its six in-plane and six
//  out-of-plane ones. That is 1 or 2 seed vertices instead of 12 or 14.
//

import Foundation

/// An ideal neighbour shell: vertex positions scaled to unit mean length.
public struct PTMTemplate {
    public let name: String
    public let structure: PTMClass
    /// Neighbour vectors of the perfect structure, mean length 1.
    public let points: [SIMD3<Double>]
    /// One vertex per orbit of the template's proper rotation group (see above).
    public let seedVertices: [Int]
    /// Angle (radians) between vertices i and j — the seed prune.
    public let angles: [Double]
    public let symmetry: LatticeSymmetry

    public var count: Int { points.count }

    init(name: String, structure: PTMClass, points raw: [SIMD3<Double>],
         seedVertices: [Int], symmetry: LatticeSymmetry) {
        let mean = raw.reduce(0.0) { $0 + ($1 * $1).sum().squareRoot() } / Double(raw.count)
        let points = raw.map { $0 / mean }
        self.name = name
        self.structure = structure
        self.points = points
        self.seedVertices = seedVertices
        self.symmetry = symmetry
        let n = points.count
        var angles = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0..<n { angles[i * n + j] = PTMTemplate.angle(points[i], points[j]) }
        }
        self.angles = angles
    }

    static func angle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let na = (a * a).sum().squareRoot(), nb = (b * b).sum().squareRoot()
        guard na > 1e-12, nb > 1e-12 else { return 0 }
        return acos(Swift.max(-1, Swift.min(1, (a * b).sum() / (na * nb))))
    }

    // MARK: - The five templates

    /// Twelve ⟨110⟩ neighbours.
    public static let fcc = PTMTemplate(
        name: "fcc", structure: .fcc,
        points: [SIMD3(1, 1, 0), SIMD3(1, -1, 0), SIMD3(-1, 1, 0), SIMD3(-1, -1, 0),
                 SIMD3(1, 0, 1), SIMD3(1, 0, -1), SIMD3(-1, 0, 1), SIMD3(-1, 0, -1),
                 SIMD3(0, 1, 1), SIMD3(0, 1, -1), SIMD3(0, -1, 1), SIMD3(0, -1, -1)],
        seedVertices: [0], symmetry: .cubic)

    /// Six in-plane neighbours (indices 0…5) then three above and three below,
    /// all at the ideal c/a = √(8/3) so every neighbour is the same distance.
    public static let hcp: PTMTemplate = {
        let h = (2.0 / 3.0).squareRoot()                 // c/2 with a = 1
        var pts: [SIMD3<Double>] = []
        for k in 0..<6 {
            let t = Double(k) * Double.pi / 3
            pts.append(SIMD3(cos(t), sin(t), 0))
        }
        for sign in [1.0, -1.0] {
            for k in 0..<3 {
                let t = Double.pi / 6 + Double(k) * 2 * Double.pi / 3
                pts.append(SIMD3(cos(t) / 3.0.squareRoot(), sin(t) / 3.0.squareRoot(), sign * h))
            }
        }
        return PTMTemplate(name: "hcp", structure: .hcp, points: pts,
                           seedVertices: [0, 6], symmetry: .hexagonal)
    }()

    /// Eight ⟨111⟩ first neighbours (indices 0…7) then six ⟨100⟩ seconds.
    public static let bcc: PTMTemplate = {
        var pts: [SIMD3<Double>] = []
        for sx in [1.0, -1.0] { for sy in [1.0, -1.0] { for sz in [1.0, -1.0] {
            pts.append(SIMD3(0.5 * sx, 0.5 * sy, 0.5 * sz))
        } } }
        pts += [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0),
                SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        return PTMTemplate(name: "bcc", structure: .bcc, points: pts,
                           seedVertices: [0, 8], symmetry: .cubic)
    }()

    /// The twelve vertices of a regular icosahedron.
    public static let ico: PTMTemplate = {
        let p = (1 + 5.0.squareRoot()) / 2
        var pts: [SIMD3<Double>] = []
        for s1 in [1.0, -1.0] { for s2 in [1.0, -1.0] {
            pts.append(SIMD3(0, s1, s2 * p))
            pts.append(SIMD3(s1, s2 * p, 0))
            pts.append(SIMD3(s2 * p, 0, s1))
        } }
        return PTMTemplate(name: "ico", structure: .ico, points: pts,
                           seedVertices: [0], symmetry: .none)
    }()

    /// Six ⟨100⟩ neighbours.
    public static let simpleCubic = PTMTemplate(
        name: "sc", structure: .sc,
        points: [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0),
                 SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)],
        seedVertices: [0], symmetry: .cubic)

    public static func named(_ name: String) -> PTMTemplate? {
        switch name.lowercased() {
        case "fcc": return .fcc
        case "hcp": return .hcp
        case "bcc": return .bcc
        case "ico", "icosahedral": return .ico
        case "sc", "simple_cubic", "simplecubic": return .simpleCubic
        default: return nil
        }
    }
}

/// What a template matched with.
public struct PTMMatch {
    /// Dimensionless: both point sets carry unit mean neighbour length.
    public var rmsd: Double
    /// Rotation taking the ideal template onto this atom's neighbourhood.
    public var orientation: Quat
    /// Affine fit F with b ≈ F a over the matched correspondence. Because both
    /// sides are normalised to unit mean length the volumetric part is divided
    /// out and F carries the rotation and the *deviatoric* distortion.
    public var deformation: Mat3
}

/// One matcher per analysis pass: all the per-atom scratch lives here so the
/// inner loop allocates nothing.
public final class TemplateMatcher {
    /// Seed prune: |template angle − measured angle| must be under this.
    public static let seedAngleTolerance = 15.0 * Double.pi / 180

    private static let maxVertices = 14
    /// The seed's second vector must make an angle in this band with the first:
    /// two nearly parallel or nearly antiparallel vectors leave the rotation
    /// about their common axis undetermined, and a random seed rotation wastes
    /// the refinement it feeds.
    private static let seedSpreadBand = (25.0 * Double.pi / 180)...(155.0 * Double.pi / 180)

    private let horn = HornSolver()
    private var centred = [SIMD3<Double>](repeating: .zero, count: maxVertices)
    private var rotated = [SIMD3<Double>](repeating: .zero, count: maxVertices)
    private var seedA = [SIMD3<Double>](repeating: .zero, count: 2)
    private var seedB = [SIMD3<Double>](repeating: .zero, count: 2)
    private var cost = [Double](repeating: 0, count: maxVertices * maxVertices)
    private var assignment = [Int](repeating: 0, count: maxVertices)
    private var bestAssignment = [Int](repeating: 0, count: maxVertices)
    private var rowUsed = [Bool](repeating: false, count: maxVertices)
    private var colUsed = [Bool](repeating: false, count: maxVertices)
    private var centroidSquared = 0.0

    public init() {}

    /// `observed` must be the atom's `template.count` nearest neighbour
    /// vectors, nearest first, already scaled to unit mean length.
    /// Returns nil when no seed correspondence survived the angle prune.
    public func match(observed: [SIMD3<Double>], template: PTMTemplate) -> PTMMatch? {
        let n = template.count
        guard observed.count >= n, n >= 2 else { return nil }

        // Centre on the centroid of the N neighbours *and* the central atom.
        // Every template here is centrosymmetric about its own centre, so the
        // template centroid is exactly zero and only this side moves.
        var sum = SIMD3<Double>.zero
        for i in 0..<n { sum += observed[i] }
        let centroid = sum / Double(n + 1)
        for i in 0..<n { centred[i] = observed[i] - centroid }
        centroidSquared = (centroid * centroid).sum()

        // Seed on the nearest neighbour and the first other neighbour that is
        // not (anti)parallel to it.
        var second = 1
        for k in 1..<n where Self.seedSpreadBand.contains(PTMTemplate.angle(centred[0], centred[k])) {
            second = k
            break
        }
        let measured = PTMTemplate.angle(centred[0], centred[second])

        // Pass 1 — score every surviving seed by the RMSD of its raw two-vector
        // rotation. Cheap, and enough to rank them.
        var first = (rmsd: Double.infinity, orientation: Quat.identity)
        var runnerUp = first
        for t0 in template.seedVertices {
            for t1 in 0..<n where t1 != t0 {
                guard abs(template.angles[t0 * n + t1] - measured) < Self.seedAngleTolerance
                else { continue }
                seedA[0] = template.points[t0]; seedA[1] = template.points[t1]
                seedB[0] = centred[0]; seedB[1] = centred[second]
                let q = horn.rotation(from: seedA, to: seedB, count: 2)
                assign(template: template, orientation: q)
                let r = rmsd(template: template, orientation: q)
                if r < first.rmsd { runnerUp = first; first = (r, q) }
                else if r < runnerUp.rmsd { runnerUp = (r, q) }
            }
        }
        guard first.rmsd.isFinite else { return nil }

        // Pass 2 — two assign → Kabsch rounds on the two best seeds. A rotation
        // fitted to two vectors is a good guess, not the answer; keeping the
        // runner-up costs one refinement and covers the case where noise put the
        // right correspondence second.
        var bestRMSD = Double.infinity
        var bestQuat = Quat.identity
        for seed in [first, runnerUp] where seed.rmsd.isFinite {
            var q = seed.orientation
            for _ in 0..<2 {
                assign(template: template, orientation: q)
                q = kabsch(template: template)
            }
            let r = rmsd(template: template, orientation: q)
            if r < bestRMSD {
                bestRMSD = r; bestQuat = q
                for i in 0..<n { bestAssignment[i] = assignment[i] }
            }
        }
        for i in 0..<n { assignment[i] = bestAssignment[i] }

        return PTMMatch(rmsd: bestRMSD, orientation: bestQuat,
                        deformation: affineFit(template: template))
    }

    // MARK: - Steps

    /// Correspondence under a trial rotation: each neighbour takes its nearest
    /// template vertex. That is a permutation almost every time — a lattice is
    /// far from degenerate — so the collision-free case is tried first at
    /// O(N²), and only when two neighbours want the same vertex does the
    /// globally greedy fallback (repeatedly take the cheapest unused pair) run.
    private func assign(template: PTMTemplate, orientation q: Quat) {
        let n = template.count
        for j in 0..<n { rotated[j] = q.rotate(template.points[j]); colUsed[j] = false }
        var collided = false
        for i in 0..<n {
            var best = Double.infinity, bj = 0
            for j in 0..<n {
                let d = centred[i] - rotated[j]
                let d2 = (d * d).sum()
                cost[i * n + j] = d2
                if d2 < best { best = d2; bj = j }
            }
            if colUsed[bj] { collided = true } else { colUsed[bj] = true }
            assignment[i] = bj
        }
        guard collided else { return }

        for i in 0..<n { rowUsed[i] = false; colUsed[i] = false }
        for _ in 0..<n {
            var best = Double.infinity, bi = -1, bj = -1
            for i in 0..<n where !rowUsed[i] {
                for j in 0..<n where !colUsed[j] {
                    if cost[i * n + j] < best { best = cost[i * n + j]; bi = i; bj = j }
                }
            }
            guard bi >= 0 else { break }
            assignment[bi] = bj
            rowUsed[bi] = true; colUsed[bj] = true
        }
    }

    /// Horn's rotation for the current correspondence. The central atom sits at
    /// the template's own centroid (the origin) and so adds nothing to S.
    private func kabsch(template: PTMTemplate) -> Quat {
        var s = Mat3.zero
        for i in 0..<template.count { s += Mat3.outer(template.points[assignment[i]], centred[i]) }
        return horn.rotation(correlation: s)
    }

    private func rmsd(template: PTMTemplate, orientation q: Quat) -> Double {
        let n = template.count
        var sum = centroidSquared                      // the central atom's own residual
        for i in 0..<n {
            let d = centred[i] - q.rotate(template.points[assignment[i]])
            sum += (d * d).sum()
        }
        return (sum / Double(n + 1)).squareRoot()
    }

    /// F = (Σ bᵢ aᵀ)(Σ a aᵀ)⁻¹ over the matched correspondence, so b ≈ F a.
    private func affineFit(template: PTMTemplate) -> Mat3 {
        var w = Mat3.zero, v = Mat3.zero
        for i in 0..<template.count {
            let a = template.points[assignment[i]]
            w += Mat3.outer(centred[i], a)
            v += Mat3.outer(a, a)
        }
        guard let inv = v.inverse else { return .identity }
        return w * inv
    }
}
