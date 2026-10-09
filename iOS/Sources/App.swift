import SwiftUI

@main
struct IntroducerApp: App {
    // ponytail: clears the offer line earlier builds kept; drop this once none of those is installed.
    init() { UserDefaults.standard.removeObject(forKey: "introducer.offerLine") }
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
