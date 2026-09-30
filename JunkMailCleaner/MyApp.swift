import SwiftUI

@main struct MyApp: App {
    init() {
        #if DEBUG
        let buildConfiguration = "Debug"
        #else
        let buildConfiguration = "Release"
        #endif
        let environment = ProcessInfo.processInfo.environment
            .filter { $0.key.hasPrefix("JMC_") }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        let executablePath = Bundle.main.executablePath ?? "nil"
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "nil"
        let jmcEnvironment = environment.isEmpty ? "none" : environment
        print("[JunkMailCleaner][Startup] JMC BUILD MARKER = NORMAL-INSPECTOR-2026-09-29")
        print("[JunkMailCleaner][Startup] BundlePath=\(Bundle.main.bundlePath)")
        print("[JunkMailCleaner][Startup] ExecutablePath=\(executablePath)")
        print("[JunkMailCleaner][Startup] BundleIdentifier=\(bundleIdentifier)")
        print("[JunkMailCleaner][Startup] BuildConfiguration=\(buildConfiguration)")
        print("[JunkMailCleaner][Startup] Arguments=\(CommandLine.arguments)")
        print("[JunkMailCleaner][Startup] JMCEnvironment=\(jmcEnvironment)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
