import AppKit

enum ProcessGuard {
    static let bundleIDs = [
        "com.apple.dt.Xcode",
        "com.apple.iphonesimulator",
        "com.apple.dt.Instruments",
    ]

    static func runningNames() -> [String] {
        bundleIDs.flatMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
        }
        .compactMap { $0.localizedName }
    }

    @discardableResult
    static func quitAll() -> Bool {
        let apps = bundleIDs.flatMap { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
        }
        for app in apps {
            app.terminate()
        }
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if runningNames().isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        for app in apps where !app.isTerminated {
            app.forceTerminate()
        }
        return runningNames().isEmpty
    }
}
