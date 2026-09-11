import Foundation

/// The line every surface shows BEFORE a hosted job is submitted (pricing study §3.1, the "spend cap"):
/// billing is metered to the second and the runner is stopped at the wall limit, so the most a job can
/// cost is wall hours × rate. Shown next to the balance so the buyer can see both numbers at once.
/// Returns nil when the rate is unknown — no number beats a wrong one.
public enum HostedSpendCap {
    /// Rate for `gpu`, from the capabilities rate table first, then the account's; "any" is the fallback.
    public static func rate(gpu: String, caps: HostedCapabilities?, account: HostedAccount?) -> Double? {
        caps?.rates?[gpu] ?? caps?.rates?["any"] ?? account?.rate_table[gpu] ?? account?.rate_table["any"]
    }

    public static func maxUSD(wallHours: Double, ratePerHour: Double) -> Double { wallHours * ratePerHour }

    /// `cap 4 h × $2.00/h = $8.00 max · balance $25.00`
    public static func line(wallHours: Double, ratePerHour: Double?, balanceUSD: Double?) -> String? {
        guard let r = ratePerHour, r >= 0, wallHours > 0 else { return nil }
        let cap = maxUSD(wallHours: wallHours, ratePerHour: r)
        var s = String(format: "cap %@ h × $%.2f/h = $%.2f max", hours(wallHours), r, cap)
        if let b = balanceUSD {
            s += String(format: " · balance $%.2f", b)
            if cap > b { s += " (cap exceeds balance)" }
        }
        return s
    }

    /// The pre-submit line when the server prices by work (GJOB-129 flip). The cap is still the promise —
    /// the endpoint bills min(work price, wall × rate) — so the same numbers stay on the line, after the prices.
    /// `priced by work: lj/cut $0.6/Mstep + $0.002/G · reaxff $8/Mstep + $1.5/G · other $2/Mstep + $0.2/G (Mstep = million steps, G = billion atom-steps) + $0.05 per job · never more than 4 h × $2.00/h = $8.00 · balance $25.00`
    /// Falls back to the metered line when `pricing` is nil or not job mode.
    public static func line(wallHours: Double, ratePerHour: Double?, balanceUSD: Double?, pricing: HostedPricing?) -> String? {
        guard let p = pricing, p.isJob else { return line(wallHours: wallHours, ratePerHour: ratePerHour, balanceUSD: balanceUSD) }
        var parts: [String] = []
        let prices = p.usd_per_gatom_step ?? [:], steps = p.usd_per_mstep ?? [:]
        func term(_ k: String) -> String {
            var t: [String] = []
            if let m = steps[k] { t.append("$\(g(m))/Mstep") }
            if let a = prices[k] { t.append("$\(g(a))/G") }
            return t.joined(separator: " + ")
        }
        let classes = Set(prices.keys).union(steps.keys)
        for k in classes.sorted() where k != "default" { parts.append("\(k) \(term(k))") }
        if classes.contains("default") { parts.append("other \(term("default"))") }
        var s = "priced by work: " + (parts.isEmpty ? "per-class prices from the endpoint" : parts.joined(separator: " · "))
        s += steps.isEmpty ? " per billion atom-steps" : " (Mstep = million steps, G = billion atom-steps)"
        if let b = p.base_usd_per_job, b > 0 { s += String(format: " + $%.2f per job", b) }
        if let r = ratePerHour, r >= 0, wallHours > 0 {
            s += String(format: " · never more than %@ h × $%.2f/h = $%.2f", hours(wallHours), r, maxUSD(wallHours: wallHours, ratePerHour: r))
        }
        if let b = balanceUSD { s += String(format: " · balance $%.2f", b) }
        return s
    }

    static func g(_ v: Double) -> String { String(format: "%g", v) }

    /// Public form of `hours` for UI fields (GJOB-118 submit options).
    public static func hoursText(_ h: Double) -> String { hours(h) }

    static func hours(_ h: Double) -> String {
        h == h.rounded() ? String(Int(h)) : String(format: "%g", h)
    }
}
