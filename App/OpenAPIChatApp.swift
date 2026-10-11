import OpenAPIChatKit
import SwiftUI

@main
struct OpenAPIChatApp: App {
    @State private var library = APILibrary()

    init() {
        #if PRIVATE_CLOUD_COMPUTE
        ModelChoice.isPrivateCloudEnabled = true
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                // openapichat:// links go to the open window instead of creating a new one each time.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}
