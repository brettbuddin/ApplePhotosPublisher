import Foundation
import Testing
@testable import lrphotosimporter

@Suite("ImportCommand")
struct ImportTests {

    // MARK: - importSinglePhoto

    @Test func fileNotFound() async {
        let mock = MockPhotoLibrary()
        let cmd = ImportCommand()
        let result = await cmd.importSinglePhoto(
            photoKit: mock,
            path: "/nonexistent/photo.jpg",
            previousIdentifier: nil
        )
        #expect(result.status == "error")
        #expect(result.errorCode == "FILE_NOT_FOUND")
        #expect(mock.importPhotoCalls.isEmpty)
    }

    @Test func successfulImportNoPrevious() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).jpg")
        try Data([0xFF, 0xD8]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mock = MockPhotoLibrary()
        mock.importPhotoReturn = "new-id-123"

        let cmd = ImportCommand()
        let result = await cmd.importSinglePhoto(
            photoKit: mock,
            path: tmp.path,
            previousIdentifier: nil
        )
        #expect(result.status == "success")
        #expect(result.localIdentifier == "new-id-123")
        #expect(result.albumsRestored.isEmpty)
        #expect(result.favoriteRestored == false)
        #expect(mock.importPhotoCalls.count == 1)
        #expect(mock.fetchAlbumsCalls.isEmpty)
    }

    @Test func importWithPreviousRestoresFavoritesAndAlbums() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).jpg")
        try Data([0xFF, 0xD8]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mock = MockPhotoLibrary()
        mock.importPhotoReturn = "new-id"
        mock.isFavoriteReturn = true
        mock.albumsToReturn = [AlbumMembership(uuid: "alb-1", title: "Trip")]

        let cmd = ImportCommand()
        let result = await cmd.importSinglePhoto(
            photoKit: mock,
            path: tmp.path,
            previousIdentifier: "prev-id"
        )
        #expect(result.status == "success")
        #expect(result.favoriteRestored == true)
        #expect(result.albumsRestored.count == 1)
        #expect(result.albumsRestored.first?.uuid == "alb-1")
        #expect(mock.setFavoriteCalls.count == 1)
        #expect(mock.addAssetCalls.count == 1)
        #expect(mock.addAssetCalls.first?.0 == "new-id")
        #expect(mock.addAssetCalls.first?.1 == "alb-1")
    }

    @Test func previousIdentifierSuffixIsStripped() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).jpg")
        try Data([0xFF, 0xD8]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mock = MockPhotoLibrary()
        mock.importPhotoReturn = "new-id/L0/001"
        mock.isFavoriteReturn = true
        mock.albumsToReturn = [AlbumMembership(uuid: "alb-1", title: "Trip")]

        let cmd = ImportCommand()
        let result = await cmd.importSinglePhoto(
            photoKit: mock,
            path: tmp.path,
            previousIdentifier: "prev-id/L0/001"
        )
        #expect(result.status == "success")
        // PhotoKit lookups should receive the stripped UUID
        #expect(mock.fetchAlbumsCalls == ["prev-id"])
        #expect(mock.isFavoriteCalls == ["prev-id"])
        // The full identifier should still be returned to Lightroom
        #expect(result.localIdentifier == "new-id/L0/001")
    }

    @Test func favoriteRestoreFailureStillSucceeds() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).jpg")
        try Data([0xFF, 0xD8]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mock = MockPhotoLibrary()
        mock.importPhotoReturn = "new-id"
        mock.isFavoriteReturn = true
        mock.setFavoriteError = NSError(domain: "test", code: 1)

        let cmd = ImportCommand()
        let result = await cmd.importSinglePhoto(
            photoKit: mock,
            path: tmp.path,
            previousIdentifier: "prev-id"
        )
        #expect(result.status == "success")
        #expect(result.favoriteRestored == false)
    }

    @Test func albumRestoreFailureStillSucceeds() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).jpg")
        try Data([0xFF, 0xD8]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mock = MockPhotoLibrary()
        mock.importPhotoReturn = "new-id"
        mock.albumsToReturn = [AlbumMembership(uuid: "alb-1", title: "Trip")]
        mock.addAssetError = NSError(domain: "test", code: 1)

        let cmd = ImportCommand()
        let result = await cmd.importSinglePhoto(
            photoKit: mock,
            path: tmp.path,
            previousIdentifier: "prev-id"
        )
        #expect(result.status == "success")
        #expect(result.albumsRestored.isEmpty)
    }

    @Test func importFailure() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID()).jpg")
        try Data([0xFF, 0xD8]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let mock = MockPhotoLibrary()
        mock.importPhotoError = PhotoKitError.importFailed(
            path: tmp,
            reason: "disk full"
        )

        let cmd = ImportCommand()
        let result = await cmd.importSinglePhoto(
            photoKit: mock,
            path: tmp.path,
            previousIdentifier: nil
        )
        #expect(result.status == "error")
        #expect(result.errorCode == "IMPORT_FAILED")
    }
    // MARK: - parseManifestXML

    @Test func parseValidManifest() throws {
        let xml = """
        <manifest>
          <photos>
            <photo>
              <path>/tmp/a.jpg</path>
              <previousIdentifier>prev-1</previousIdentifier>
            </photo>
            <photo>
              <path>/tmp/b.jpg</path>
            </photo>
          </photos>
        </manifest>
        """
        let doc = try XMLDocument(xmlString: xml)
        let cmd = ImportCommand()
        let photos = try cmd.parseManifestXML(doc)
        #expect(photos.count == 2)
        #expect(photos[0].path == "/tmp/a.jpg")
        #expect(photos[0].previousIdentifier == "prev-1")
        #expect(photos[1].path == "/tmp/b.jpg")
        #expect(photos[1].previousIdentifier == nil)
    }

    @Test func parseEmptyManifest() throws {
        let xml = "<manifest><photos></photos></manifest>"
        let doc = try XMLDocument(xmlString: xml)
        let cmd = ImportCommand()
        let photos = try cmd.parseManifestXML(doc)
        #expect(photos.isEmpty)
    }

    @Test func parseManifestNoPhotosElement() throws {
        let xml = "<manifest></manifest>"
        let doc = try XMLDocument(xmlString: xml)
        let cmd = ImportCommand()
        let photos = try cmd.parseManifestXML(doc)
        #expect(photos.isEmpty)
    }

    @Test func parseInvalidManifestRoot() throws {
        let xml = "<notmanifest></notmanifest>"
        let doc = try XMLDocument(xmlString: xml)
        let cmd = ImportCommand()
        #expect(throws: Error.self) {
            try cmd.parseManifestXML(doc)
        }
    }
}
