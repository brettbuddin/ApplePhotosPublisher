import Foundation
import Testing
@testable import lrphotosimporter

@Suite("BatchImport")
struct BatchImportTests {

    private func parseResult(_ xml: String) throws -> XMLElement {
        let doc = try XMLDocument(xmlString: xml)
        return try #require(doc.rootElement())
    }

    @Test func emptyPhotos() async throws {
        let mock = MockPhotoLibrary()
        let cmd = ImportCommand()
        let xml = await cmd.executeBatchImport(photoKit: mock, photos: [])
        let root = try parseResult(xml)
        #expect(root.name == "batchImportResult")
        #expect(root.elements(forName: "status").first?.stringValue == "success")
        let results = try #require(root.elements(forName: "results").first)
        #expect(results.elements(forName: "result").isEmpty)
        #expect(!mock.ensureWriteAccessCalled)
    }

    @Test func authFailurePhotoKitError() async throws {
        let mock = MockPhotoLibrary()
        mock.ensureWriteAccessError = PhotoKitError.writeAuthorizationDenied

        let cmd = ImportCommand()
        let photos = [ManifestPhoto(path: "/tmp/a.jpg", previousIdentifier: nil)]
        let xml = await cmd.executeBatchImport(photoKit: mock, photos: photos)
        let root = try parseResult(xml)
        #expect(root.elements(forName: "status").first?.stringValue == "error")
        #expect(root.elements(forName: "errorCode").first?.stringValue == "WRITE_AUTH_DENIED")
        #expect(mock.importPhotoCalls.isEmpty)
    }

    @Test func authFailureGenericError() async throws {
        let mock = MockPhotoLibrary()
        mock.ensureWriteAccessError = NSError(domain: "test", code: 42, userInfo: [
            NSLocalizedDescriptionKey: "something went wrong"
        ])

        let cmd = ImportCommand()
        let photos = [ManifestPhoto(path: "/tmp/a.jpg", previousIdentifier: nil)]
        let xml = await cmd.executeBatchImport(photoKit: mock, photos: photos)
        let root = try parseResult(xml)
        #expect(root.elements(forName: "status").first?.stringValue == "error")
        #expect(root.elements(forName: "errorCode").first?.stringValue == "AUTH_ERROR")
        #expect(mock.importPhotoCalls.isEmpty)
    }

    @Test func multiplePhotos() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
        let file1 = tmpDir.appendingPathComponent("batch-\(UUID()).jpg")
        let file2 = tmpDir.appendingPathComponent("batch-\(UUID()).jpg")
        try Data([0xFF, 0xD8]).write(to: file1)
        try Data([0xFF, 0xD8]).write(to: file2)
        defer {
            try? FileManager.default.removeItem(at: file1)
            try? FileManager.default.removeItem(at: file2)
        }

        let mock = MockPhotoLibrary()
        mock.importPhotoReturn = "new-id"

        let cmd = ImportCommand()
        let photos = [
            ManifestPhoto(path: file1.path, previousIdentifier: nil),
            ManifestPhoto(path: file2.path, previousIdentifier: nil)
        ]
        let xml = await cmd.executeBatchImport(photoKit: mock, photos: photos)
        let root = try parseResult(xml)
        #expect(root.elements(forName: "status").first?.stringValue == "success")
        let results = try #require(root.elements(forName: "results").first)
        let resultElements = results.elements(forName: "result")
        #expect(resultElements.count == 2)
        #expect(resultElements[0].attribute(forName: "path")?.stringValue == file1.path)
        #expect(resultElements[1].attribute(forName: "path")?.stringValue == file2.path)
        #expect(mock.ensureWriteAccessCalled)
        #expect(mock.importPhotoCalls.count == 2)
    }

    @Test func mixOfSuccessAndFailure() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("batch-\(UUID()).jpg")
        try Data([0xFF, 0xD8]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mock = MockPhotoLibrary()
        mock.importPhotoReturn = "new-id"

        let cmd = ImportCommand()
        let photos = [
            ManifestPhoto(path: tmp.path, previousIdentifier: nil),
            ManifestPhoto(path: "/nonexistent/missing.jpg", previousIdentifier: nil)
        ]
        let xml = await cmd.executeBatchImport(photoKit: mock, photos: photos)
        let root = try parseResult(xml)
        #expect(root.elements(forName: "status").first?.stringValue == "success")
        let results = try #require(root.elements(forName: "results").first)
        let resultElements = results.elements(forName: "result")
        #expect(resultElements.count == 2)
        #expect(resultElements[0].elements(forName: "status").first?.stringValue == "success")
        #expect(resultElements[1].elements(forName: "status").first?.stringValue == "error")
        #expect(resultElements[1].elements(forName: "errorCode").first?.stringValue == "FILE_NOT_FOUND")
    }

    @Test func withPreviousIdentifiers() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("batch-\(UUID()).jpg")
        try Data([0xFF, 0xD8]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mock = MockPhotoLibrary()
        mock.importPhotoReturn = "new-id"
        mock.isFavoriteReturn = true
        mock.albumsToReturn = [AlbumMembership(uuid: "alb-1", title: "Vacation")]

        let cmd = ImportCommand()
        let photos = [ManifestPhoto(path: tmp.path, previousIdentifier: "prev-id")]
        let xml = await cmd.executeBatchImport(photoKit: mock, photos: photos)
        let root = try parseResult(xml)
        let results = try #require(root.elements(forName: "results").first)
        let resultElements = results.elements(forName: "result")
        #expect(resultElements.count == 1)
        #expect(resultElements[0].elements(forName: "status").first?.stringValue == "success")
        #expect(resultElements[0].elements(forName: "localIdentifier").first?.stringValue == "new-id")
        #expect(resultElements[0].elements(forName: "favoriteRestored").first?.stringValue == "true")
        let albumsRestored = try #require(resultElements[0].elements(forName: "albumsRestored").first)
        let albums = albumsRestored.elements(forName: "album")
        #expect(albums.count == 1)
        #expect(albums[0].elements(forName: "identifier").first?.stringValue == "alb-1")
    }
}
