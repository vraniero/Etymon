import SwiftData
import SwiftUI

@main
struct EtymonApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(.etymon())
    }
}
