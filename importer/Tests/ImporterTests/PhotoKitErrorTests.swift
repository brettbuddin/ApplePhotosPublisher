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
}
