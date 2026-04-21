import SwiftUI

@main
struct RXDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup("RXDownloader") {
            ContentView()
                .onAppear {
                    configureWindow()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
    
    private func configureWindow() {
        if let window = NSApplication.shared.windows.first {
            window.level = .floating // Always on Top
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(red: 0.027, green: 0.031, blue: 0.039, alpha: 1.0) // Matching #07080a
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        BinaryManager.shared.prepareBinaries()
        
        print("RXDownloader Started - Environment Ready")
    }
}
