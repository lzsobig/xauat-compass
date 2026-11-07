import SwiftUI

@main
struct ClassroomApp: App {
    @StateObject private var manager = ClassroomManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(manager)
        }
    }
}
