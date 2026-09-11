import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AppModel {
    var items: [ScanItem] = []
    var volumes: [ExternalVolume] = []
    var selectedVolumeID: String?
    var selectedIDs: Set<String> = []
    var isScanning = false
    var isBusy = false
    var status = "Scan to see what Xcode is storing on this Mac."
    var errorMessage: String?
    var progressText: String?
    var internalFreeBytes: Int64 = 0
    var internalTotalBytes: Int64 = 0
    var catalog: [RelocationRecord] = CatalogStore.load()
    var confirmDelete = false
    var confirmMove = false
    var confirmQuitXcode = false
    var pendingAction: PendingAction?
    var xcodeRunning: [String] = []

    enum PendingAction {
        case delete
        case move
    }

    var selectedVolume: ExternalVolume? {
        volumes.first { $0.id == selectedVolumeID }
    }

    var selectedItems: [ScanItem] {
        let selected = items.filter { selectedIDs.contains($0.id) }
        let selectedParents = Set(selected.filter { $0.parentPath == nil }.map(\.path))
        return selected.filter { item in
            guard let parent = item.parentPath else { return true }
            return !selectedParents.contains(parent)
        }
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.bytes }
    }

    var recommendedDeleteBytes: Int64 {
        uniqueLeafBytes(where: \.recommendedDelete)
    }

    var recommendedMoveBytes: Int64 {
        uniqueLeafBytes(where: \.recommendedMove)
    }

    func refreshVolumes() {
        let disk = VolumeService.internalDisk()
        internalFreeBytes = disk.free
        internalTotalBytes = disk.total
        volumes = VolumeService.listExternal()
        if selectedVolumeID == nil {
            selectedVolumeID = volumes.first(where: \.isEligible)?.id
        } else if !volumes.contains(where: { $0.id == selectedVolumeID }) {
            selectedVolumeID = volumes.first(where: \.isEligible)?.id
        }
        xcodeRunning = ProcessGuard.runningNames()
    }

    func scan() async {
        isScanning = true
        status = "Scanning Xcode folders…"
        errorMessage = nil
        refreshVolumes()
        let found = await Scanner.scan()
        items = found
        selectedIDs = Set(found.filter { $0.recommendedDelete }.map(\.id))
        let deleteCount = found.filter(\.recommendedDelete).count
        status = "Found \(found.count) items. \(deleteCount) recommended to delete (\(ByteFormat.string(recommendedDeleteBytes)))."
        isScanning = false
        refreshHealth()
    }

    func applyRecommendedDeletes() {
        selectedIDs = Set(items.filter(\.recommendedDelete).map(\.id))
    }

    func applyRecommendedMoves() {
        selectedIDs = Set(items.filter(\.recommendedMove).map(\.id))
    }

    func requestDelete() {
        guard !selectedItems.isEmpty else { return }
        beginMutation(.delete)
    }

    func requestMove() {
        guard !selectedItems.isEmpty else { return }
        guard selectedVolume?.isEligible == true else {
            errorMessage = selectedVolume?.ineligibilityReason ?? "Pick an APFS external volume first."
            return
        }
        beginMutation(.move)
    }

    func confirmPending() {
        let action = pendingAction
        pendingAction = nil
        confirmDelete = false
        confirmMove = false
        confirmQuitXcode = false
        Task {
            switch action {
            case .delete:
                await performDelete()
            case .move:
                await performMove()
            case nil:
                break
            }
        }
    }

    func quitThenConfirm() async {
        let names = xcodeRunning
        let ok = await Task.detached { ProcessGuard.quitAll() }.value
        if ok {
            switch pendingAction {
            case .delete: confirmDelete = true
            case .move: confirmMove = true
            case nil: break
            }
        } else {
            errorMessage = "Could not quit \(names.joined(separator: ", ")). Quit them yourself and try again."
            pendingAction = nil
        }
    }

    func repair(_ item: ScanItem) async {
        guard let record = catalog.first(where: { $0.originalPath == item.path }) else {
            errorMessage = "No saved pointer for this item."
            return
        }
        isBusy = true
        progressText = "Repairing \(item.name)…"
        defer {
            isBusy = false
            progressText = nil
        }
        do {
            let updated = try await Task.detached {
                try Relocator.repair(record)
            }.value
            CatalogStore.upsert(updated, into: &catalog)
            status = "Repaired pointer for \(item.name)."
            await scan()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reveal(_ item: ScanItem) {
        let url = URL(fileURLWithPath: item.symlinkDestination ?? item.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func beginMutation(_ action: PendingAction) {
        pendingAction = action
        xcodeRunning = ProcessGuard.runningNames()
        if !xcodeRunning.isEmpty {
            confirmQuitXcode = true
            return
        }
        switch action {
        case .delete: confirmDelete = true
        case .move: confirmMove = true
        }
    }

    private func performDelete() async {
        isBusy = true
        errorMessage = nil
        defer {
            isBusy = false
            progressText = nil
        }
        let targets = selectedItems
        var done = 0
        for item in targets {
            progressText = "Moving \(item.name) to Trash…"
            do {
                try await Task.detached {
                    try Relocator.delete(item)
                }.value
                done += 1
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        status = "Moved \(done) item(s) to Trash."
        await scan()
    }

    private func performMove() async {
        guard let volume = selectedVolume else { return }
        isBusy = true
        errorMessage = nil
        defer {
            isBusy = false
            progressText = nil
        }
        let targets = selectedItems.filter { !$0.isSymlink }
        var done = 0
        for item in targets {
            progressText = "Copying \(item.name) to \(volume.name)…"
            do {
                let record = try await moveOffMain(item: item, volume: volume)
                CatalogStore.upsert(record, into: &catalog)
                done += 1
            } catch {
                errorMessage = error.localizedDescription
                break
            }
        }
        status = "Moved \(done) item(s) to \(volume.name). Original paths now point at the drive."
        await scan()
    }

    private func refreshHealth() {
        for i in items.indices {
            guard items[i].isSymlink else { continue }
            if let dest = items[i].symlinkDestination, !FileManager.default.fileExists(atPath: dest) {
                items[i].healthIssue = "Destination missing. Plug in the drive or Repair."
            }
        }
    }

    private func uniqueLeafBytes(where predicate: (ScanItem) -> Bool) -> Int64 {
        let matched = items.filter(predicate)
        let parents = Set(matched.filter { $0.parentPath == nil }.map(\.path))
        return matched
            .filter { item in
                guard let parent = item.parentPath else { return true }
                return !parents.contains(parent)
            }
            .reduce(0) { $0 + $1.bytes }
    }

    private func moveOffMain(item: ScanItem, volume: ExternalVolume) async throws -> RelocationRecord {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let record = try Relocator.move(item: item, to: volume) { text in
                        DispatchQueue.main.async {
                            self.progressText = text
                        }
                    }
                    continuation.resume(returning: record)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
