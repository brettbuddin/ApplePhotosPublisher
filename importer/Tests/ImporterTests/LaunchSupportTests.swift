import Foundation
import LaunchSupport
import Testing

@Suite("Launch support")
struct LaunchSupportTests {
    @Test(arguments: [(Int32(0), Int32(0)), (23 << 8, 23), (134 << 8, 134), (255 << 8, 255)])
    func normalExit(raw: Int32, code: Int32) {
        let result = ProcessExitStatus(pid: 42, rawStatus: raw)
        #expect(result.exitCode == code)
        #expect(result.signal == nil)
        #expect(result.record.contains("state=exited\n"))
    }

    @Test(arguments: [(Int32(6), Int32(6)), (6 | 0x80, 6), (9, 9)])
    func signalExit(raw: Int32, signal: Int32) {
        let result = ProcessExitStatus(pid: 42, rawStatus: raw)
        #expect(result.signal == signal)
        #expect(result.exitCode == nil)
        #expect(result.record.contains("state=signaled\n"))
    }

    @Test func directDiagnosticsDoNotRequireHandshake() throws {
        let arguments = ["authorize", "--status-only"]
        #expect(try StartupHandshake.complete(arguments: arguments) == arguments)
    }

    @Test func missingMonitorFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: LaunchFailure.self) {
            try StartupHandshake.complete(
                arguments: [StartupHandshake.argument, directory.path, "import"], timeout: 0.02
            )
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pid").path))
    }
}
