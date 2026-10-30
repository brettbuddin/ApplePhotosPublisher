import Foundation

/// A kernel wait status. A normal exit(134) is distinct from death by SIGABRT.
public struct ProcessExitStatus {
    public let pid: Int32
    public let rawStatus: Int32

    public init(pid: Int32, rawStatus: Int32) {
        self.pid = pid
        self.rawStatus = rawStatus
    }

    public var signal: Int32? {
        let value = rawStatus & 0x7f
        return value == 0 ? nil : value
    }

    public var exitCode: Int32? {
        signal == nil ? (rawStatus >> 8) & 0xff : nil
    }

    public var record: String {
        var lines = ["version=1", "pid=\(pid)", "rawStatus=\(rawStatus)"]
        if let signal {
            lines += ["state=signaled", "signal=\(signal)"]
        } else if let exitCode {
            lines += ["state=exited", "exitCode=\(exitCode)"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public var description: String {
        let reason = signal.map { "signal \($0)" } ?? "exit code \(exitCode ?? 0)"
        return "Helper PID \(pid) terminated: \(reason) (raw status \(rawStatus))"
    }
}
