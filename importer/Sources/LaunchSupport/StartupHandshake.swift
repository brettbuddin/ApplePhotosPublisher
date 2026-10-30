import Darwin
import Foundation

/// The helper waits here before parsing commands or accessing Photos. Only the
/// launcher knows this private directory, and it acknowledges after kqueue is armed.
public enum StartupHandshake {
    public static let argument = "--launcher-handshake"

    public static func complete(arguments: [String], timeout: TimeInterval = 30) throws -> [String] {
        guard arguments.first == argument else { return arguments }
        guard arguments.count >= 2 else {
            throw LaunchFailure.startup("Missing startup handshake directory")
        }
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let pid = "\(getpid())\n"
        try pid.write(to: directory.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let reply = try? String(contentsOf: directory.appendingPathComponent("continue"), encoding: .utf8),
               reply == pid {
                return Array(arguments.dropFirst(2))
            }
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw LaunchFailure.startup("Launcher disconnected before completing the startup handshake")
            }
            usleep(10_000)
        }
        throw LaunchFailure.startup("Timed out waiting for the exit-status monitor; no Photos operation started")
    }
}

public enum LaunchFailure: LocalizedError {
    case startup(String)
    case monitor(String)

    public var state: String {
        switch self {
        case .startup: return "startupFailed"
        case .monitor: return "monitorFailed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .startup(let message), .monitor(let message): return message
        }
    }
}
