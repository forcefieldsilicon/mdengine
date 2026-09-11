import XCTest

/// Screenshot automation for the App Store listing. Never shipped: a `bundle.ui-testing` target is not
/// embedded in the `.app`, and `xcodebuild archive` builds the app target alone.
///
/// Why it exists: the listing needs 6.9" shots of the signed-in screens, and those only render once a key is
/// in the Keychain. Putting one there needs a tap, and taps cannot be scripted from a shell — `simctl` has
/// no tap verb and driving the Simulator by AppleScript needs an Automation grant this environment does not
/// have. XCUITest is the supported way in, and it is what fastlane's snapshot does under the hood.
///
/// Nothing real is involved. The key below is a throwaway 32-hex string and `MDENGINE_HOSTED_URL` points at
/// `scripts/screenshot_stub.py` on localhost, so no real API key, balance or job ever reaches a screenshot.
/// `HostedClient.resolvedEndpoint` reads that variable before falling back to production.
///
/// Usage:
///     python3 scripts/screenshot_stub.py &
///     xcodebuild test -project ios/MDEngineRuns.xcodeproj -scheme MDEngineRuns \
///         -destination 'name=iPhone 17 Pro Max' -resultBundlePath /tmp/shots.xcresult
///
/// To point at a different stub port, set TEST_RUNNER_STUB_URL — plain STUB_URL does NOT reach the test
/// runner process, which cost an afternoon's confusion once.
///     xcrun xcresulttool export attachments --path /tmp/shots.xcresult --output-path /tmp/shots
final class ScreenshotFlow: XCTestCase {

    /// Obviously fake, and well-formed per `KeyEntry.isWellFormed`: `mde_` + 32 lowercase hex digits.
    private static let stubKey = "mde_0123456789abcdef0123456789abcdef"

    override func setUp() { continueAfterFailure = false }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testCaptureListingScreens() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MDENGINE_HOSTED_URL"] =
            ProcessInfo.processInfo.environment["STUB_URL"] ?? "http://127.0.0.1:8790/v1"
        app.launch()

        // The simulator Keychain persists between runs, so the app may already be signed in. Sign in only
        // when it is not — re-typing over a populated app would land the text nowhere useful.
        let signedIn = app.buttons["Sign out"].waitForExistence(timeout: 8)
        if !signedIn {
            // Wait on BOTH field kinds before choosing: `.exists` on a still-launching app returns false
            // and would silently pick the wrong element type.
            let text = app.textFields.firstMatch
            let secure = app.secureTextFields.firstMatch
            guard text.waitForExistence(timeout: 20) || secure.waitForExistence(timeout: 10) else {
                return XCTFail("neither signed in nor showing key entry. Tree:\n\(app.debugDescription)")
            }
            shot("01-key-entry")
            let field = text.exists ? text : secure
            field.tap()
            field.typeText(Self.stubKey)
            let cont = app.buttons["Continue"]
            XCTAssertTrue(cont.waitForExistence(timeout: 5), "Continue button missing")
            cont.tap()
        }

        // Reaching a job row proves the key verified against the stub.
        // Match on the run STATE, not the id: production ids look like MDJOB-20260909-D95435 and an
        // id-prefix predicate silently fails whenever the sample data's format drifts from the real one.
        let firstJob = app.staticTexts.matching(
            NSPredicate(format: "label IN %@", ["running", "done", "failed", "queued"])).firstMatch
        XCTAssertTrue(firstJob.waitForExistence(timeout: 30),
                      "job list never rendered — is the stub running on STUB_URL?")
        shot("02-runs-list")

        // The run detail screen: the only shot that needs a tap, which is the whole reason for this target.
        firstJob.tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 10),
                      "detail screen did not push")
        shot("03-run-detail")
    }
}
