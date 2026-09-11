import SwiftUI
import AppKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VolumeSidebar()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                itemList
                Divider()
                footer
            }
        }
        .navigationTitle("XcodeOffload")
        .task {
            model.refreshVolumes()
            await model.scan()
        }
        .alert("Could not finish", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "Quit Xcode first?",
            isPresented: $model.confirmQuitXcode,
            titleVisibility: .visible
        ) {
            Button("Quit \(model.xcodeRunning.joined(separator: ", ")) and continue") {
                Task { await model.quitThenConfirm() }
            }
            Button("Cancel", role: .cancel) {
                model.pendingAction = nil
            }
        } message: {
            Text("Xcode or Simulator is running. They should be quit before files are deleted or moved.")
        }
        .confirmationDialog(
            "Move \(model.selectedItems.count) items to Trash?",
            isPresented: $model.confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                model.confirmPending()
            }
            Button("Cancel", role: .cancel) {
                model.pendingAction = nil
            }
        } message: {
            Text("\(ByteFormat.string(model.selectedBytes)) will go to Trash. Regenerable caches come back on the next build. Archives and unique dSYMs do not.")
        }
        .confirmationDialog(
            "Move \(model.selectedItems.count) items off this Mac?",
            isPresented: $model.confirmMove,
            titleVisibility: .visible
        ) {
            Button("Copy to \(model.selectedVolume?.name ?? "drive") and leave a pointer") {
                model.confirmPending()
            }
            Button("Cancel", role: .cancel) {
                model.pendingAction = nil
            }
        } message: {
            Text("Files copy to \(model.selectedVolume?.name ?? "the selected volume"). The original path becomes a symlink, so Xcode still finds them. Keep that drive plugged in while you build.")
        }
        .overlay {
            if model.isBusy || model.isScanning {
                ZStack {
                    Color.black.opacity(0.18)
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(model.progressText ?? model.status)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .ignoresSafeArea()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Internal disk")
                    .font(.headline)
                Text("\(ByteFormat.string(model.internalFreeBytes)) free of \(ByteFormat.string(model.internalTotalBytes))")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Spacer()
            if model.recommendedDeleteBytes > 0 {
                LabeledValue(title: "Safe to delete", value: ByteFormat.string(model.recommendedDeleteBytes))
            }
            if model.recommendedMoveBytes > 0 {
                LabeledValue(title: "Better to move", value: ByteFormat.string(model.recommendedMoveBytes))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var itemList: some View {
        @Bindable var model = model
        return List(selection: $model.selectedIDs) {
            section("Recommended to delete", items: model.items.filter(\.recommendedDelete))
            section("Device symbols", items: model.items.filter { $0.kind == .deviceSupportVersion && !$0.recommendedDelete })
            section("Move to keep, but off this disk", items: model.items.filter { $0.recommendedMove && !$0.recommendedDelete })
            section("Already pointing at an external drive", items: model.items.filter { $0.safety == .alreadyOffloaded })
            section("Other Xcode data", items: otherItems)
        }
        .listStyle(.inset)
    }

    private var otherItems: [ScanItem] {
        model.items.filter { item in
            !item.recommendedDelete
                && !item.recommendedMove
                && item.safety != .alreadyOffloaded
                && item.kind != .deviceSupportVersion
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [ScanItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    ItemRow(item: item)
                        .tag(item.id)
                        .contextMenu {
                            Button("Reveal in Finder") { model.reveal(item) }
                            if item.isSymlink {
                                Button("Repair pointer") {
                                    Task { await model.repair(item) }
                                }
                            }
                        }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Scan") {
                Task { await model.scan() }
            }
            Button("Select recommended deletes") {
                model.applyRecommendedDeletes()
            }
            .disabled(model.items.isEmpty)
            Button("Select recommended moves") {
                model.applyRecommendedMoves()
            }
            .disabled(model.items.isEmpty)
            Spacer()
            Text(model.status)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Move to Trash…") {
                model.requestDelete()
            }
            .disabled(model.selectedItems.isEmpty || model.isBusy)
            Button("Move to drive…") {
                model.requestMove()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedItems.isEmpty || model.isBusy || model.selectedVolume?.isEligible != true)
        }
        .padding(12)
    }
}

private struct VolumeSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedVolumeID) {
            Section("Destination volume") {
                ForEach(model.volumes) { volume in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: volume.isEligible ? "externaldrive" : "externaldrive.badge.xmark")
                            Text(volume.name)
                                .fontWeight(.medium)
                        }
                        Text("\(volume.filesystem) · \(ByteFormat.string(volume.freeBytes)) free")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let reason = volume.ineligibilityReason {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .tag(volume.id)
                    .padding(.vertical, 4)
                }
            }
            Section("Notes") {
                Text("Use APFS, not ExFAT. A symlink stays at the original path so Xcode still finds the files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("CoreDevice/DeviceFS is skipped. That mount is the phone, not this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}

private struct ItemRow: View {
    let item: ScanItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.systemImage)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.name)
                        .fontWeight(.medium)
                    if item.recommendedDelete {
                        Badge(text: "Delete", color: .orange)
                    }
                    if item.recommendedMove {
                        Badge(text: "Move", color: .blue)
                    }
                    if item.isSymlink {
                        Badge(text: "Offloaded", color: .green)
                    }
                }
                Text(item.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let issue = item.healthIssue {
                    Text(issue)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let dest = item.symlinkDestination {
                    Text(dest)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(ByteFormat.string(item.bytes))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct LabeledValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
        }
    }
}
