import ArgumentParser
import Foundation
import LaunchSupport

/// Runs directly under Lightroom but never accesses Photos. The app it launches
/// through Launch Services retains its own signed identity and Photos permission.
@main
struct LRPhotosLauncher: ParsableCommand {
    @Option var app: String
    @Option var stdout: String
    @Option var stderr: String
    @Option var status: String
    @Option var startupTimeout: Double = 30
    @Argument(parsing: .postTerminator) var arguments: [String] = []

    mutating func validate() throws {
        guard startupTimeout.isFinite, startupTimeout > 0 else {
            throw ValidationError("Startup timeout must be a positive finite number")
        }
    }

    mutating func run() throws {
        let statusURL = URL(fileURLWithPath: status)
        do {
            let result = try LaunchMonitor.run(
                app: app, arguments: arguments, stdout: stdout, stderr: stderr, startupTimeout: startupTimeout
            )
            try result.record.write(to: statusURL, atomically: true, encoding: .utf8)
            FileHandle.standardError.write(Data((result.description + "\n").utf8))
        } catch {
            let state = (error as? LaunchFailure)?.state ?? "startupFailed"
            try? "version=1\nstate=\(state)\n".write(to: statusURL, atomically: true, encoding: .utf8)
            throw ValidationError(error.localizedDescription)
        }
    }
}
