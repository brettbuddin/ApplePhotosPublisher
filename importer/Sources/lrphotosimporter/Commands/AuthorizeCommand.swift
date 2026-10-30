import ArgumentParser
import Foundation
import Photos

/// Diagnose Photos authorization without reading, importing, or deleting assets.
struct AuthorizeCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "authorize",
        abstract: "Check or request Photos library access without changing any photos"
    )

    @Flag(help: "Report the current status without displaying a permission prompt")
    var statusOnly = false

    @Flag(help: "Verify the Photos service accepts this app using an empty change transaction (no photos changed)")
    var checkLibrary = false

    mutating func run() async throws {
        let photoKit = PhotoKitAccessor()
        if !statusOnly {
            do {
                try await photoKit.ensureWriteAccess()
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            }
        }
        let status = await photoKit.authorizationStatus()
        print("Photos authorization: \(status.rawValue) (0=not determined, 1=restricted, 2=denied, 3=full access, 4=limited)")
        print("App: \(Bundle.main.bundleIdentifier ?? "unbundled")")
        if checkLibrary {
            guard status == .authorized else {
                throw PhotoKitError.writeAuthorizationDenied
            }
            // A successful permission callback alone is insufficient: the Photos
            // service independently validates our code identity when connecting.
            try await PHPhotoLibrary.shared().performChanges { }
            print("Photos library connection: OK (no changes)")
        }
    }
}
