import ArgumentParser
import Foundation

struct DeleteCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete photos from Apple Photos by identifier"
    )

    @Argument(help: "Local identifiers of photos to delete")
    var identifiers: [String]

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
