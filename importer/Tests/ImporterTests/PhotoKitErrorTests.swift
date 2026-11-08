import Foundation
import Testing
@testable import lrphotosimporter

/// Tests for the authorization cases of ``PhotoKitError``.
@Suite("PhotoKitError")
struct PhotoKitErrorTests {

    @Test(arguments: [
        (PhotoKitError.writeAuthorizationDenied, "WRITE_AUTH_DENIED"),
        (PhotoKitError.writeAuthorizationLimited, "WRITE_AUTH_LIMITED"),
        (PhotoKitError.writeAuthorizationRestricted, "WRITE_AUTH_RESTRICTED"),
    ])
    func writeAuthorizationCodes(error: PhotoKitError, code: String) {
        #expect(error.code == code)
    }

    /// Denied and limited access can be fixed by the user, so the message must say where.
    @Test(arguments: [PhotoKitError.writeAuthorizationDenied, .writeAuthorizationLimited])
    func fixableAuthorizationErrorsPointToSystemSettings(error: PhotoKitError) throws {
        let message = try #require(error.errorDescription)
        #expect(message.contains("System Settings"))
        #expect(message.contains("Full Access"))
        #expect(message.contains("set Apple Photos Publisher for Lightroom Classic to Full Access"))
        #expect(!message.contains("set Lightroom Classic"))
    }

    /// Restricted access cannot be changed by the user, so no System Settings remedy is offered.
    @Test func restrictedAuthorizationErrorOffersNoRemedy() throws {
        let message = try #require(PhotoKitError.writeAuthorizationRestricted.errorDescription)
        #expect(!message.contains("System Settings"))
    }

    /// A refused confirmation dialog has to stay distinguishable from a genuine failure,
    /// because the plugin words them differently.
    @Test func userCancelledHasItsOwnCodeAndMessage() throws {
        let error = PhotoKitError.userCancelled(operation: "deleting the album")
        #expect(error.code == "USER_CANCELLED")
        let message = try #require(error.errorDescription)
        #expect(message.contains("cancelled"))
        #expect(message.contains("deleting the album"))
        // PhotoKit's own text for 3072 says only that the operation could not be completed.
        #expect(!message.contains("couldn’t be completed"))
    }

    @Test func collectionErrorCodes() {
        #expect(PhotoKitError.folderNotFound(identifier: "f").code == "FOLDER_NOT_FOUND")
        #expect(PhotoKitError.operationNotPermitted(identifier: "a", operation: "renaming").code
            == "OPERATION_NOT_PERMITTED")
        #expect(PhotoKitError.createCollectionFailed(name: "a", reason: "r").code
            == "CREATE_COLLECTION_FAILED")
        #expect(PhotoKitError.renameCollectionFailed(identifier: "a", name: "b", reason: "r").code
            == "RENAME_COLLECTION_FAILED")
        #expect(PhotoKitError.deleteCollectionFailed(identifier: "a", reason: "r").code
            == "DELETE_COLLECTION_FAILED")
        #expect(PhotoKitError.moveCollectionFailed(identifier: "a", reason: "r").code
            == "MOVE_COLLECTION_FAILED")
        #expect(PhotoKitError.removeFromAlbumFailed(albumID: "a", reason: "r").code
            == "REMOVE_FROM_ALBUM_FAILED")
    }
}
