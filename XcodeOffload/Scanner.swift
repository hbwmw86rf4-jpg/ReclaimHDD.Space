import Foundation

enum Scanner {
    private struct Spec {
        var relative: String
        var name: String
        var kind: ItemKind
        var safety: Safety
        var note: String
        var recommendedDelete: Bool
        var recommendedMove: Bool
        var expandChildren: Bool
    }

    static func scan() async -> [ScanItem] {
        var items: [ScanItem] = []
        let fm = FileManager.default

        let specs: [Spec] = [
            Spec(
                relative: "Xcode/DerivedData",
                name: "DerivedData",
                kind: .derivedData,
                safety: .deleteAnytime,
                note: "Build intermediates. Xcode rebuilds these. First build after delete is slower.",
                recommendedDelete: false,
                recommendedMove: false,
                expandChildren: false
            ),
            Spec(
                relative: "Xcode/Archives",
                name: "Archives",
                kind: .archives,
                safety: .movePreferred,
                note: "Release archives and dSYMs. Do not delete if you still need crash symbolication.",
                recommendedDelete: false,
                recommendedMove: true,
                expandChildren: false
            ),
            Spec(
                relative: "Xcode/iOS DeviceSupport",
                name: "iOS DeviceSupport",
                kind: .deviceSupportRoot,
                safety: .movePreferred,
                note: "Debug symbols copied from each physical device and OS version you have plugged in.",
                recommendedDelete: false,
                recommendedMove: true,
                expandChildren: true
            ),
            Spec(
                relative: "Xcode/watchOS DeviceSupport",
                name: "watchOS DeviceSupport",
                kind: .deviceSupportRoot,
                safety: .movePreferred,
                note: "watchOS debug symbols from paired devices.",
                recommendedDelete: false,
                recommendedMove: true,
                expandChildren: true
            ),
            Spec(
                relative: "Xcode/tvOS DeviceSupport",
                name: "tvOS DeviceSupport",
                kind: .deviceSupportRoot,
                safety: .movePreferred,
                note: "tvOS debug symbols from plugged-in devices.",
                recommendedDelete: false,
                recommendedMove: true,
                expandChildren: true
            ),
            Spec(
                relative: "Xcode/DocumentationCache",
                name: "Documentation cache",
                kind: .documentation,
                safety: .deleteAnytime,
                note: "Downloaded docs. Xcode can fetch them again.",
                recommendedDelete: true,
                recommendedMove: false,
                expandChildren: false
            ),
            Spec(
                relative: "Xcode/UserData/Previews",
                name: "SwiftUI Previews",
                kind: .previews,
                safety: .deleteAnytime,
                note: "Preview canvas cache. Regenerated when you use Previews.",
                recommendedDelete: true,
                recommendedMove: false,
                expandChildren: false
            ),
            Spec(
                relative: "Xcode/UserData/CodingAssistant",
                name: "Coding Assistant data",
                kind: .codingAssistant,
                safety: .deleteAnytime,
                note: "Xcode assistant working files. Safe to delete.",
                recommendedDelete: true,
                recommendedMove: false,
                expandChildren: false
            ),
            Spec(
                relative: "Xcode/iOS Device Logs",
                name: "iOS device logs",
                kind: .deviceLogs,
                safety: .deleteAnytime,
                note: "Copied device logs. Safe to delete.",
                recommendedDelete: true,
                recommendedMove: false,
                expandChildren: false
            ),
            Spec(
                relative: "CoreSimulator",
                name: "Simulators",
                kind: .simulatorRoot,
                safety: .movePreferred,
                note: "Simulator devices and data. Move the whole folder, or delete unused devices.",
                recommendedDelete: false,
                recommendedMove: true,
                expandChildren: true
            ),
            Spec(
                relative: "XCTestDevices",
                name: "XCTest devices",
                kind: .xcTestDevices,
                safety: .deleteAnytime,
                note: "Temporary devices created by test runs.",
                recommendedDelete: true,
                recommendedMove: true,
                expandChildren: false
            ),
        ]

        let extraCaches: [(String, String, ItemKind, String)] = [
            (
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.apple.dt.Xcode").path,
                "Xcode caches",
                .xcodeCache,
                "General Xcode cache files."
            ),
            (
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/org.swift.swiftpm").path,
                "SwiftPM cache",
                .swiftPM,
                "Downloaded Swift packages. Re-resolved on the next build."
            ),
            (
                fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/org.swift.swiftpm").path,
                "SwiftPM data",
                .swiftPM,
                "Swift package manager state."
            ),
        ]

        await withTaskGroup(of: [ScanItem].self) { group in
            for spec in specs {
                group.addTask {
                    makeItems(spec: spec)
                }
            }
            for cache in extraCaches {
                group.addTask {
                    let url = URL(fileURLWithPath: cache.0)
                    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
                    return [describe(
                        url: url,
                        name: cache.1,
                        kind: cache.2,
                        safety: .deleteAnytime,
                        note: cache.3,
                        parentPath: nil,
                        recommendedDelete: true,
                        recommendedMove: false
                    )]
                }
            }
            for await chunk in group {
                items.append(contentsOf: chunk)
            }
        }

        markOldDeviceSupport(in: &items)
        items.removeAll { $0.bytes == 0 && !$0.isSymlink }
        items.sort { lhs, rhs in
            if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return items
    }

    private static func makeItems(spec: Spec) -> [ScanItem] {
        let url = KnownPaths.developer.appendingPathComponent(spec.relative, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        var result: [ScanItem] = [
            describe(
                url: url,
                name: spec.name,
                kind: spec.kind,
                safety: spec.safety,
                note: spec.note,
                parentPath: nil,
                recommendedDelete: spec.recommendedDelete,
                recommendedMove: spec.recommendedMove
            )
        ]

        guard spec.expandChildren, !isSymlink(url) else { return result }

        if spec.kind == .deviceSupportRoot {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children where isDirectory(child) {
                result.append(
                    describe(
                        url: child,
                        name: child.lastPathComponent,
                        kind: .deviceSupportVersion,
                        safety: .deleteOldVersion,
                        note: "Symbols for this device OS. Keep the newest for each device; older betas can go.",
                        parentPath: url.path,
                        recommendedDelete: false,
                        recommendedMove: false
                    )
                )
            }
        } else if spec.kind == .simulatorRoot {
            let devices = url.appendingPathComponent("Devices", isDirectory: true)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: devices,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for child in children where isDirectory(child) {
                let info = simulatorInfo(at: child)
                let bytes = Command.diskUsageKilobytes(at: child.path)
                guard bytes > 100 * 1024 * 1024 else { continue }
                result.append(
                    ScanItem(
                        name: info.name,
                        path: child.path,
                        bytes: bytes,
                        kind: .simulatorDevice,
                        safety: .deleteAnytime,
                        note: "Simulator data for \(info.name). Deleting wipes apps and settings on that simulator.",
                        parentPath: url.path,
                        isSymlink: isSymlink(child),
                        symlinkDestination: symlinkDestination(child),
                        recommendedDelete: bytes > 4 * 1024 * 1024 * 1024,
                        recommendedMove: false,
                        healthIssue: nil
                    )
                )
            }
        }

        return result
    }

    private static func describe(
        url: URL,
        name: String,
        kind: ItemKind,
        safety: Safety,
        note: String,
        parentPath: String?,
        recommendedDelete: Bool,
        recommendedMove: Bool
    ) -> ScanItem {
        let linked = isSymlink(url)
        let dest = symlinkDestination(url)
        let sizeURL = dest.flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil } ?? url.path
        let bytes = Command.diskUsageKilobytes(at: sizeURL)
        var recDelete = recommendedDelete
        if kind == .derivedData, bytes > 2 * 1024 * 1024 * 1024 {
            recDelete = true
        }
        return ScanItem(
            name: name,
            path: url.path,
            bytes: bytes,
            kind: kind,
            safety: linked ? .alreadyOffloaded : safety,
            note: note,
            parentPath: parentPath,
            isSymlink: linked,
            symlinkDestination: dest,
            recommendedDelete: linked ? false : recDelete,
            recommendedMove: linked ? false : recommendedMove,
            healthIssue: linked ? healthForSymlink(original: url.path, destination: dest) : nil
        )
    }

    private static func markOldDeviceSupport(in items: inout [ScanItem]) {
        let versions = items.enumerated().filter { $0.element.kind == .deviceSupportVersion && !$0.element.isSymlink }
        let grouped = Dictionary(grouping: versions) { deviceModel(from: $0.element.name) }
        var deletePaths = Set<String>()
        for (_, group) in grouped where group.count > 1 {
            let sorted = group.sorted { $0.element.name.localizedStandardCompare($1.element.name) == .orderedAscending }
            for old in sorted.dropLast() {
                deletePaths.insert(old.element.path)
            }
        }
        for i in items.indices {
            if deletePaths.contains(items[i].path) {
                items[i].recommendedDelete = true
                items[i].note = "Older OS for this device. Keep the newest; this copy is safe to delete."
            }
        }
    }

    private static func deviceModel(from folderName: String) -> String {
        folderName.split(separator: " ").first.map(String.init) ?? folderName
    }

    private static func simulatorInfo(at url: URL) -> (name: String, runtime: String) {
        let plistURL = url.appendingPathComponent("device.plist")
        guard
            let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            return (url.lastPathComponent, "")
        }
        let name = plist["name"] as? String ?? url.lastPathComponent
        let runtime = plist["runtime"] as? String ?? ""
        return (name, runtime)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private static func isSymlink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        if values?.isSymbolicLink == true { return true }
        var dest = [Int8](repeating: 0, count: Int(PATH_MAX))
        return url.path.withCString { readlink($0, &dest, dest.count) } > 0
    }

    private static func symlinkDestination(_ url: URL) -> String? {
        let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
        return dest
    }

    private static func healthForSymlink(original: String, destination: String?) -> String? {
        guard let destination else { return "Broken pointer at original path." }
        if FileManager.default.fileExists(atPath: destination) { return nil }
        return "Destination is missing. Plug the drive in, or use Repair."
    }
}
