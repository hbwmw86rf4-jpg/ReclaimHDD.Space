import Foundation

enum VolumeService {
    static func internalDisk() -> (free: Int64, total: Int64) {
        let url = URL(fileURLWithPath: "/")
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeTotalCapacityKey,
        ])
        let free = Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        return (free, total)
    }

    static func listExternal() -> [ExternalVolume] {
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return urls.compactMap { url in
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return nil
            }
            return describe(url)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func describe(_ url: URL) -> ExternalVolume? {
        guard let info = diskutilInfo(path: url.path) else { return nil }
        let internalDisk = bool(info["Internal"])
        if internalDisk { return nil }

        let name = string(info["VolumeName"]).ifEmpty(url.lastPathComponent)
        let uuid = string(info["VolumeUUID"])
        let filesystem = string(info["FilesystemUserVisibleName"]).ifEmpty(string(info["FilesystemName"]))
        let personality = string(info["FilesystemName"])
        let free = int64(info["FreeSpace"]) ?? int64(info["VolumeFreeSpace"]) ?? 0
        let total = int64(info["TotalSize"]) ?? 0

        var reason: String?
        let lowerName = name.lowercased()
        if lowerName.contains("timemachine") || lowerName == "time machine" {
            reason = "Time Machine volumes should not hold Xcode data."
        } else if personality.uppercased() == "APFSX" || filesystem.lowercased().contains("case-sensitive") {
            reason = "Case-sensitive APFS can break Xcode and simulators."
        } else if !isAppleFileSystem(personality, filesystem) {
            reason = "\(filesystem.isEmpty ? personality : filesystem) cannot store Xcode folders. Format a partition as APFS."
        }

        return ExternalVolume(
            url: url,
            name: name,
            uuid: uuid,
            filesystem: filesystem.isEmpty ? personality : filesystem,
            freeBytes: free,
            totalBytes: total,
            isEligible: reason == nil,
            ineligibilityReason: reason
        )
    }

    private static func isAppleFileSystem(_ personality: String, _ visible: String) -> Bool {
        let token = (personality + " " + visible).uppercased()
        if token.contains("EXFAT") || token.contains("FAT32") || token.contains("MS-DOS") || token.contains("NTFS") {
            return false
        }
        return token.contains("APFS") || token.contains("HFS")
    }

    private static func diskutilInfo(path: String) -> [String: Any]? {
        guard let xml = try? Command.run("/usr/sbin/diskutil", ["info", "-plist", path]),
              let data = xml.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return plist
    }

    private static func string(_ value: Any?) -> String {
        value as? String ?? ""
    }

    private static func bool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let n = value as? NSNumber { return n.int64Value }
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        return nil
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
