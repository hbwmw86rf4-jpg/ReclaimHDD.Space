import Foundation

enum Command {
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> String {
        let task = Process()
        let out = Pipe()
        let err = Pipe()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        task.standardOutput = out
        task.standardError = err
        try task.run()
        task.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if task.terminationStatus != 0 {
            let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw OffloadError.commandFailed(launchPath, task.terminationStatus, stderr.isEmpty ? stdout : stderr)
        }
        return stdout
    }

    static func diskUsageKilobytes(at path: String) -> Int64 {
        guard let output = try? run("/usr/bin/du", ["-sk", path]) else { return 0 }
        let token = output.split(whereSeparator: { $0.isWhitespace || $0 == "\t" }).first
        guard let token, let kb = Int64(token) else { return 0 }
        return kb * 1024
    }
}
