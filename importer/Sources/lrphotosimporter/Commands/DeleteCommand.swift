import ArgumentParser
import Foundation

/// Command that deletes one or more photos from the Apple Photos library by their local identifiers.
///
/// Outputs an XML result to stdout indicating success or failure, suitable for parsing
/// by the Lightroom plugin.
struct DeleteCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete photos from Apple Photos by identifier"
    )

    @Argument(help: "Local identifiers of photos to delete")
    var identifiers: [String]

    /// Validates identifiers, ensures Photos library write access, and performs the deletion.
    mutating func run() async {
        guard !identifiers.isEmpty else {
            print(XMLOutput.deleteError(code: "NO_IDENTIFIERS", message: "No identifiers provided"))
            return
        }

        let photoKit = PhotoKitAccessor()

        // Ensure authorization
        do {
            try await photoKit.ensureWriteAccess()
        } catch let error as PhotoKitError {
            print(XMLOutput.deleteError(code: error.code, message: error.errorDescription ?? "Authorization failed"))
            return
        } catch {
            print(XMLOutput.deleteError(code: "AUTH_ERROR", message: error.localizedDescription))
            return
        }

        print(await performDelete(photoKit: photoKit, identifiers: identifiers))
    }

    /// Performs the delete operation against the given photo library.
    /// - Parameters:
    ///   - photoKit: The photo library to delete assets from.
    ///   - identifiers: Local identifiers of the assets to delete.
    /// - Returns: An XML string describing the result of the deletion.
    func performDelete(photoKit: any PhotoLibrary, identifiers: [String]) async -> String {
        do {
            try await photoKit.deleteAssets(identifiers: identifiers)
            return XMLOutput.deleteSuccess(deletedCount: identifiers.count)
        } catch let error as PhotoKitError {
            return XMLOutput.deleteError(code: error.code, message: error.errorDescription ?? "Delete failed")
        } catch {
            return XMLOutput.deleteError(code: "DELETE_FAILED", message: error.localizedDescription)
        }
    }
}
