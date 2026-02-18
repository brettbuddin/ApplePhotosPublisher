import Foundation
import Testing
@testable import lrphotosimporter

@Suite("DeleteCommand")
struct DeleteTests {

    @Test func deleteSuccess() async throws {
        let mock = MockPhotoLibrary()
        let cmd = DeleteCommand()
        let output = await cmd.performDelete(
            photoKit: mock,
            identifiers: ["id-1", "id-2"]
        )
        let doc = try XMLDocument(xmlString: output)
        let root = try #require(doc.rootElement())
        #expect(root.elements(forName: "status").first?.stringValue == "success")
        #expect(root.elements(forName: "deletedCount").first?.stringValue == "2")
        #expect(mock.deleteAssetsCalls.count == 1)
        #expect(mock.deleteAssetsCalls.first == ["id-1", "id-2"])
    }

    @Test func deleteFailure() async throws {
        let mock = MockPhotoLibrary()
        mock.deleteAssetsError = PhotoKitError.deleteFailed(
            identifiers: ["id-1"],
            reason: "not found"
        )
        let cmd = DeleteCommand()
        let output = await cmd.performDelete(
            photoKit: mock,
            identifiers: ["id-1"]
        )
        let doc = try XMLDocument(xmlString: output)
        let root = try #require(doc.rootElement())
        #expect(root.elements(forName: "status").first?.stringValue == "error")
        #expect(root.elements(forName: "errorCode").first?.stringValue == "DELETE_FAILED")
    }
}
