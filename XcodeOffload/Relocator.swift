import Foundation

enum Relocator {
    static func move(
        item: ScanItem,
        to volume: ExternalVolume,
        progress: (String) -> Void
    ) throws -> RelocationRecord {
        guard volume.isEligible else {
            throw OffloadError.volumeIneligible(volume.ineligibilityReason ?? "Volume is not eligible.")
        }
        if item.bytes > 0, volume.freeBytes > 0, item.bytes + (500 * 1024 * 1024) > volume.freeBytes {
            throw OffloadError.notEnoughSpace
        }

        let original = URL(fileURLWithPath: item.path)
        let destRoot = volume.url.appendingPathComponent(KnownPaths.offloadRootName, isDirectory: true)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)

        let dest = uniqueDestination(in: destRoot, named: original.lastPathComponent)
        progress("Copying \(item.name) to \(volume.name)…")
        try Command.run("/usr/bin/ditto", [original.path, dest.path])

        progress("Verifying copy…")
        let srcSize = Command.diskUsageKilobytes(at: original.path)
        let destSize = Command.diskUsageKilobytes(at: dest.path)
        if srcSize > 0 {
            let delta = abs(srcSize - destSize)
            let allowed = max(srcSize / 100, 8 * 1024 * 1024)
            if delta > allowed {
                try? FileManager.default.removeItem(at: dest)
                throw OffloadError.copyVerificationFailed("\(ByteFormat.string(srcSize)) vs \(ByteFormat.string(destSize))")
            }
        }

        let backup = original.appendingPathExtension("offload-backup")
        progress("Pointing macOS at the new location…")
        if FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.removeItem(at: backup)
        }
        try FileManager.default.moveItem(at: original, to: backup)
        do {
            try FileManager.default.createSymbolicLink(atPath: original.path, withDestinationPath: dest.path)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: original)
            try? FileManager.default.removeItem(at: dest)
            throw error
        }

        if !FileManager.default.fileExists(atPath: original.path) {
            try? FileManager.default.removeItem(at: original)
            try FileManager.default.moveItem(at: backup, to: original)
            throw OffloadError.copyVerificationFailed("Symlink was not created.")
        }

        try FileManager.default.removeItem(at: backup)
        applyXcodeLocationIfNeeded(kind: item.kind, destination: dest)

        let bookmark = try dest.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return RelocationRecord(
            id: original.path,
            originalPath: original.path,
            destinationPath: dest.path,
            bookmark: bookmark,
            movedAt: Date(),
            bytes: destSize
        )
    }

    static func delete(_ item: ScanItem) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
    }

    static func repair(_ record: RelocationRecord) throws -> RelocationRecord {
        var stale = false
        let dest = try URL(
            resolvingBookmarkData: record.bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw OffloadError.volumeIneligible("The offload destination is not mounted.")
        }

        let original = URL(fileURLWithPath: record.originalPath)
        let fm = FileManager.default

        if fm.fileExists(atPath: original.path) {
            let values = try original.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            if values.isSymbolicLink == true {
                let current = try fm.destinationOfSymbolicLink(atPath: original.path)
                if current == dest.path {
                    return updated(record, dest: dest, stale: stale)
                }
                try fm.removeItem(at: original)
            } else {
                try Command.run("/usr/bin/ditto", [original.path, dest.path])
                try fm.trashItem(at: original, resultingItemURL: nil)
            }
        }

        try fm.createSymbolicLink(atPath: original.path, withDestinationPath: dest.path)
        return updated(record, dest: dest, stale: stale)
    }

    private static func updated(_ record: RelocationRecord, dest: URL, stale: Bool) -> RelocationRecord {
        var next = record
        next.destinationPath = dest.path
        if stale, let bookmark = try? dest.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
            next.bookmark = bookmark
        }
        return next
    }

    private static func uniqueDestination(in root: URL, named name: String) -> URL {
        var dest = root.appendingPathComponent(name, isDirectory: true)
        var i = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = root.appendingPathComponent("\(name)-\(i)", isDirectory: true)
            i += 1
        }
        return dest
    }

    private static func applyXcodeLocationIfNeeded(kind: ItemKind, destination: URL) {
        let key: String?
        switch kind {
        case .derivedData: key = "IDECustomDerivedDataLocation"
        case .archives: key = "IDECustomArchiveLocation"
        default: key = nil
        }
        guard let key else { return }
        _ = try? Command.run("/usr/bin/defaults", ["write", "com.apple.dt.Xcode", key, destination.path])
    }
}
