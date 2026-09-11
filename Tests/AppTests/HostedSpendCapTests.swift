import XCTest
@testable import LAMMPSCore

/// The spend-cap line (pricing study §3.1) shown by the CLI and the app before a hosted job is submitted.
final class HostedSpendCapTests: XCTestCase {
    func testLineMatchesPricingStudyExample() {
        XCTAssertEqual(HostedSpendCap.line(wallHours: 4, ratePerHour: 2.0, balanceUSD: 25.0),
                       "cap 4 h × $2.00/h = $8.00 max · balance $25.00")
    }

    func testCapAboveBalanceIsFlagged() {
        XCTAssertEqual(HostedSpendCap.line(wallHours: 4, ratePerHour: 2.0, balanceUSD: 5.0),
                       "cap 4 h × $2.00/h = $8.00 max · balance $5.00 (cap exceeds balance)")
    }

    func testFractionalHoursAndNoBalance() {
        XCTAssertEqual(HostedSpendCap.line(wallHours: 1.5, ratePerHour: 2.0, balanceUSD: nil),
                       "cap 1.5 h × $2.00/h = $3.00 max")
    }

    func testUnknownRateGivesNoLine() {
        XCTAssertNil(HostedSpendCap.line(wallHours: 4, ratePerHour: nil, balanceUSD: 25.0))
    }

    func testJobModeLineListsClassPricesAndKeepsTheCap() {
        let p = HostedPricing(mode: "job", usd_per_gatom_step: ["default": 0.05, "reaxff": 2.0, "lj/cut": 0.008], base_usd_per_job: 0.05)
        XCTAssertEqual(HostedSpendCap.line(wallHours: 4, ratePerHour: 2.0, balanceUSD: 25.0, pricing: p),
                       "priced by work: lj/cut $0.008/G · reaxff $2/G · other $0.05/G per billion atom-steps + $0.05 per job · never more than 4 h × $2.00/h = $8.00 · balance $25.00")
        let two = HostedPricing(mode: "job", usd_per_gatom_step: ["default": 0.2, "reaxff": 1.5], usd_per_mstep: ["default": 2, "reaxff": 8], base_usd_per_job: 0.05)
        XCTAssertEqual(HostedSpendCap.line(wallHours: 4, ratePerHour: 2.0, balanceUSD: nil, pricing: two),
                       "priced by work: reaxff $8/Mstep + $1.5/G · other $2/Mstep + $0.2/G (Mstep = million steps, G = billion atom-steps) + $0.05 per job · never more than 4 h × $2.00/h = $8.00")
    }

    func testMeteredOrMissingPricingFallsBackToTheCapLine() {
        XCTAssertEqual(HostedSpendCap.line(wallHours: 4, ratePerHour: 2.0, balanceUSD: 25.0, pricing: nil),
                       "cap 4 h × $2.00/h = $8.00 max · balance $25.00")
        XCTAssertEqual(HostedSpendCap.line(wallHours: 4, ratePerHour: 2.0, balanceUSD: 25.0, pricing: HostedPricing(mode: "metered")),
                       "cap 4 h × $2.00/h = $8.00 max · balance $25.00")
    }

    func testAccountDecodesWithAndWithoutPricing() throws {
        let old = try JSONDecoder().decode(HostedAccount.self, from: Data(#"{"balance_usd": 1.5, "rate_table": {"any": 2}}"#.utf8))
        XCTAssertNil(old.pricing)
        let new = try JSONDecoder().decode(HostedAccount.self, from: Data(
            #"{"balance_usd": 1.5, "rate_table": {"any": 2}, "pricing": {"mode": "job", "usd_per_gatom_step": {"default": 0.05}, "base_usd_per_job": 0.05, "metered_rate_table": {"any": 2}, "rule": "x"}}"#.utf8))
        XCTAssertEqual(new.pricing?.isJob, true); XCTAssertEqual(new.pricing?.usd_per_gatom_step?["default"], 0.05)
    }

    func testRateResolution() {
        let caps = HostedCapabilities(runners: [:], rates: ["any": 2.0, "rtx4090": 2.5])
        XCTAssertEqual(HostedSpendCap.rate(gpu: "rtx4090", caps: caps, account: nil), 2.5)
        XCTAssertEqual(HostedSpendCap.rate(gpu: "h100", caps: caps, account: nil), 2.0)
        XCTAssertNil(HostedSpendCap.rate(gpu: "any", caps: nil, account: nil))
    }
}
