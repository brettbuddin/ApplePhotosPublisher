import Foundation
import Testing
@testable import lrphotosimporter

/// Tests for mirroring published collections as Photos albums and collection sets as folders.
@Suite("Collections")
struct CollectionTests {

    private func parseResult(_ xml: String) throws -> XMLElement {
        let doc = try XMLDocument(xmlString: xml)
        return try #require(doc.rootElement())
    }

    /// A real file, since the import path checks the file system before importing.
    private func makeFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("collection-\(UUID()).jpg")
        try Data([0xFF, 0xD8]).write(to: url)
        return url
    }

    // MARK: - Manifest parsing

    @Test func parseAlbumBlock() throws {
        let xml = """
        <manifest>
          <album>
            <identifier>alb-1/L0/040</identifier>
            <name>Family 2026</name>
          </album>
          <photos>
            <photo><path>/tmp/a.jpg</path><reuseIdentifier>reuse-1</reuseIdentifier></photo>
          </photos>
        </manifest>
        """
        let manifest = try ImportCommand().parseManifestXML(try XMLDocument(xmlString: xml))
        let album = try #require(manifest.album)
        #expect(album.identifier == "alb-1/L0/040")
        #expect(album.name == "Family 2026")
        #expect(manifest.photos[0].reuseIdentifier == "reuse-1")
    }

    @Test func parseAlbumWithoutIdentifier() throws {
        let xml = """
        <manifest><album><name>Apple Photos</name></album><photos></photos></manifest>
        """
        let manifest = try ImportCommand().parseManifestXML(try XMLDocument(xmlString: xml))
        let album = try #require(manifest.album)
        #expect(album.identifier == nil)
        #expect(album.name == "Apple Photos")
    }

    /// An album block with no usable name is no album at all, rather than an album titled "".
    @Test func parseAlbumWithoutNameIsIgnored() throws {
        let xml = "<manifest><album><identifier>alb-1</identifier></album></manifest>"
        let manifest = try ImportCommand().parseManifestXML(try XMLDocument(xmlString: xml))
        #expect(manifest.album == nil)
    }

    /// Empty elements are absent, not empty strings, or a stale blank would look like a real id.
    @Test func parseTreatsEmptyElementsAsAbsent() throws {
        let xml = """
        <manifest>
          <album><identifier></identifier><name>Trip</name></album>
          <photos><photo><path>/tmp/a.jpg</path><previousIdentifier></previousIdentifier></photo></photos>
        </manifest>
        """
        let manifest = try ImportCommand().parseManifestXML(try XMLDocument(xmlString: xml))
        #expect(manifest.album?.identifier == nil)
        #expect(manifest.photos[0].previousIdentifier == nil)
    }

    // MARK: - Album resolution

    @Test func reusesAlbumWhenIdentifierStillResolves() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.collectionTitles["alb-1"] = "Family"
        mock.importPhotoReturn = "new-id"

        let manifest = Manifest(
            album: ManifestAlbum(identifier: "alb-1", name: "Family"),
            photos: [ManifestPhoto(path: file.path)])
        let xml = await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest)

        let album = try #require(try parseResult(xml).elements(forName: "album").first)
        #expect(album.elements(forName: "identifier").first?.stringValue == "alb-1")
        #expect(album.elements(forName: "created").first?.stringValue == "false")
    }

    /// A stale identifier means the album was deleted in Photos, so publishing recreates it
    /// and reports the new identifier for the plugin to record.
    @Test func recreatesAlbumWhenIdentifierIsStale() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.importPhotoReturn = "new-id"

        let manifest = Manifest(
            album: ManifestAlbum(identifier: "gone", name: "Family"),
            photos: [ManifestPhoto(path: file.path)])
        let xml = await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest)

        let album = try #require(try parseResult(xml).elements(forName: "album").first)
        #expect(album.elements(forName: "identifier").first?.stringValue == "created-1")
        #expect(album.elements(forName: "created").first?.stringValue == "true")
    }

    /// Resolving the album happens before any import, so a failure leaves nothing half filed.
    @Test func albumFailureAbortsBeforeImporting() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.ensureAlbumError = PhotoKitError.operationNotPermitted(
            identifier: "alb-1", operation: "creating")

        let manifest = Manifest(
            album: ManifestAlbum(identifier: nil, name: "Family"),
            photos: [ManifestPhoto(path: file.path)])
        let root = try parseResult(
            await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest))

        #expect(root.elements(forName: "status").first?.stringValue == "error")
        #expect(root.elements(forName: "errorCode").first?.stringValue == "OPERATION_NOT_PERMITTED")
        #expect(mock.importPhotoCalls.isEmpty)
    }
}
