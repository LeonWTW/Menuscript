import SwiftData
import SwiftUI

@main
struct MenuTranslateApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: MenuSession.self)
    }
}
