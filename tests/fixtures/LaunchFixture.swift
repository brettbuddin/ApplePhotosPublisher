import Darwin
import Foundation

// Compiled alongside the production handshake code. Never accesses Photos.
@main
enum LaunchFixture {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(78)
        }
    }

    static func run() throws {
        let original = Array(CommandLine.arguments.dropFirst())
        if original.last == "before-handshake" { exit(23) }
        let arguments = try StartupHandshake.complete(arguments: original, timeout: 2)
        switch arguments.first {
        case "abort": abort()
        case "kill": raise(SIGKILL)
        case "success-then-abort":
            print("<result><status>success</status></result>")
            fflush(stdout)
            abort()
        case "echo": print(arguments.dropFirst().joined(separator: "\n"))
        case "no-xml": break
        default: exit(Int32(arguments.first ?? "0") ?? 99)
        }
    }
}
