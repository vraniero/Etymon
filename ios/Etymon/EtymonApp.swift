import SwiftData
import SwiftUI

@main
struct EtymonApp: App {
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                if showSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .task {
                // Hold the icon while the camera / AR session and first layout settle
                // behind it, then fade into the app.
                try? await Task.sleep(for: .milliseconds(900))
                withAnimation(.easeOut(duration: 0.35)) { showSplash = false }
            }
        }
        .modelContainer(.etymon())
    }
}

/// Full-screen Etymon icon. Matches the system launch screen (`UILaunchScreen` in
/// project.yml: `LaunchLogo` on `LaunchBackground`) so the hand-off is invisible.
struct SplashView: View {
    var body: some View {
        ZStack {
            Color("LaunchBackground")
            // LaunchLogo is 1024 px at @3x, the size the launch screen draws it at.
            Image("LaunchLogo")
                .resizable()
                .frame(width: 1024 / 3, height: 1024 / 3)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
