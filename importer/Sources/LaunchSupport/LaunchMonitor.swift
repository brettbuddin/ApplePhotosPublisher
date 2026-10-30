import Darwin
import Foundation

/// Observes a Launch Services app without making it a child of Lightroom.
public enum LaunchMonitor {
    public static func run(
        app: String, arguments: [String], stdout: String, stderr: String,
        startupTimeout: TimeInterval = 30
    ) throws -> ProcessExitStatus {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lrphotoslauncher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        // open owns only the launch. kqueue owns the wait and its real exit status.
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        opener.arguments = ["-n", "-a", app, "--stdout", stdout, "--stderr", stderr, "--args",
                            StartupHandshake.argument, directory.path] + arguments
        opener.standardOutput = FileHandle.standardError
        opener.standardError = FileHandle.standardError
        try opener.run()
        defer { if opener.isRunning { opener.terminate() } }

        let pid = try waitForHandshake(directory: directory, opener: opener, timeout: startupTimeout)
        let queue = kqueue()
        guard queue >= 0 else { throw LaunchFailure.startup("Could not create exit monitor: \(systemError())") }
        defer { close(queue) }

        var registration = kevent64_s(
            ident: UInt64(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT) | UInt32(NOTE_EXITSTATUS), data: 0, udata: 0, ext: (0, 0)
        )
        guard kevent64(queue, &registration, 1, nil, 0, 0, nil) == 0 else {
            throw LaunchFailure.startup("Could not attach exit monitor to helper PID \(pid): \(systemError())")
        }

        // The helper cannot run its command until this acknowledgment is written.
        try "\(pid)\n".write(to: directory.appendingPathComponent("continue"), atomically: true, encoding: .utf8)
        var event = kevent64_s()
        while true {
            let count = kevent64(queue, nil, 0, &event, 1, 0, nil)
            if count < 0 && errno == EINTR { continue }
            guard count == 1, event.flags & UInt16(EV_ERROR) == 0,
                  event.fflags & UInt32(NOTE_EXITSTATUS) != 0 else {
                throw LaunchFailure.monitor("Exit monitor lost the helper's termination status")
            }
            return ProcessExitStatus(pid: pid, rawStatus: Int32(truncatingIfNeeded: event.data))
        }
    }

    private static func waitForHandshake(directory: URL, opener: Process, timeout: TimeInterval) throws -> Int32 {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let text = try? String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8) {
                guard let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
                    throw LaunchFailure.startup("Helper supplied an invalid PID during startup")
                }
                return pid
            }
            if !opener.isRunning && opener.terminationStatus != 0 {
                throw LaunchFailure.startup("Launch Services failed before the helper's startup handshake")
            }
            usleep(10_000)
        }
        throw LaunchFailure.startup(
            "Helper did not complete its startup handshake; it may have failed before the monitor attached. "
            + "Its exit status is unavailable. Check ~/Library/Logs/DiagnosticReports/lrphotosimporter*.ips."
        )
    }

    private static func systemError() -> String {
        String(cString: strerror(errno))
    }
}
