import Foundation

enum Safety: String, Codable, CaseIterable, Sendable {
    case deleteAnytime
    case deleteOldVersion
    case movePreferred
    case alreadyOffloaded
}

enum ItemKind: String, Codable, Sendable {
    case derivedData
    case archives
    case deviceSupportRoot
    case deviceSupportVersion
    case simulatorRoot
    case simulatorDevice
    case documentation
    case previews
    case codingAssistant
    case swiftPM
    case xcodeCache
    case xcTestDevices
    case deviceLogs

    var title: String {
        switch self {
        case .derivedData: return "DerivedData"
        case .archives: return "Archives"
        case .deviceSupportRoot: return "Device support"
        case .deviceSupportVersion: return "Device symbols"
        case .simulatorRoot: return "Simulators"
        case .simulatorDevice: return "Simulator"
        case .documentation: return "Documentation cache"
        case .previews: return "Previews"
        case .codingAssistant: return "Coding Assistant"
        case .swiftPM: return "Swift packages"
        case .xcodeCache: return "Xcode cache"
        case .xcTestDevices: return "XCTest devices"
        case .deviceLogs: return "Device logs"
        }
    }

    var systemImage: String {
        switch self {
        case .derivedData: return "hammer"
        case .archives: return "shippingbox"
        case .deviceSupportRoot, .deviceSupportVersion: return "iphone"
        case .simulatorRoot, .simulatorDevice: return "rectangle.dashed"
        case .documentation: return "book"
        case .previews: return "eye"
        case .codingAssistant: return "brain"
        case .swiftPM: return "shippingbox.and.arrow.backward"
        case .xcodeCache: return "internaldrive"
        case .xcTestDevices: return "checkmark.diamond"
        case .deviceLogs: return "doc.text"
        }
    }
}

struct ScanItem: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var bytes: Int64
    var kind: ItemKind
    var safety: Safety
    var note: String
    var parentPath: String?
    var isSymlink: Bool
    var symlinkDestination: String?
    var recommendedDelete: Bool
    var recommendedMove: Bool
    var healthIssue: String?
}

struct ExternalVolume: Identifiable, Hashable, Sendable {
    var id: String { uuid.isEmpty ? url.path : uuid }
    var url: URL
    var name: String
    var uuid: String
    var filesystem: String
    var freeBytes: Int64
    var totalBytes: Int64
    var isEligible: Bool
    var ineligibilityReason: String?
}

struct RelocationRecord: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var originalPath: String
    var destinationPath: String
    var bookmark: Data
    var movedAt: Date
    var bytes: Int64
}

enum OffloadError: LocalizedError {
    case commandFailed(String, Int32, String)
    case volumeIneligible(String)
    case xcodeStillRunning([String])
    case copyVerificationFailed(String)
    case notEnoughSpace
    case cancelled

    var errorDescription: String? {
        switch self {
        case .commandFailed(let cmd, let status, let err):
            return "\(cmd) failed (\(status)): \(err)"
        case .volumeIneligible(let reason):
            return reason
        case .xcodeStillRunning(let names):
            return "Quit \(names.joined(separator: ", ")) before changing these files."
        case .copyVerificationFailed(let detail):
            return "Copy did not verify: \(detail)"
        case .notEnoughSpace:
            return "The destination volume does not have enough free space."
        case .cancelled:
            return "Cancelled."
        }
    }
}

enum ByteFormat {
    static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useGB, .useMB, .useKB]
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}

enum KnownPaths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var developer: URL {
        home.appendingPathComponent("Library/Developer", isDirectory: true)
    }

    static var xcode: URL {
        developer.appendingPathComponent("Xcode", isDirectory: true)
    }

    static var offloadRootName: String { "XcodeOffload" }
}
