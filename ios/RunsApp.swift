import SwiftUI
import MDEngineRunsUI

/// The iOS app shell: an entry point and nothing else (GJOB-121).
///
/// Everything the app does lives in the MDEngineRunsUI library target, which `swift test` covers on macOS
/// and `xcodebuild -destination 'generic/platform=iOS Simulator'` builds for the phone. Keeping the shell
/// this thin is what let the tracker be written and tested before any app bundle existed.
///
/// Not compiled by SwiftPM — `scripts/make_ios_app.sh` compiles it together with the library sources, the
/// same way scripts/make_app.sh hand-assembles the macOS .app from a SwiftPM build. No Xcode project.
@main
struct RunsApp: App {
    @StateObject private var model = {
        let picked = CredentialStoreFactory.best()
        return RunsViewModel(store: picked.store, storeIsDowngraded: picked.downgraded)
    }()

    var body: some Scene {
        WindowGroup {
            RunsRootView(model: model)
        }
    }
}
