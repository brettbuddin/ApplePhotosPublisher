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

    @Test func parseAlbumWithFolderChain() throws {
        let xml = """
        <manifest>
          <album>
            <identifier>alb-1/L0/040</identifier>
            <name>Family 2026</name>
            <folders>
              <folder><identifier>fld-1/L0/020</identifier><name>Trips</name></folder>
              <folder><name>Summer</name></folder>
            </folders>
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
        #expect(album.folders.count == 2)
        // Outermost first, so the chain can be walked while threading each parent.
        #expect(album.folders[0].name == "Trips")
        #expect(album.folders[0].identifier == "fld-1/L0/020")
        #expect(album.folders[1].name == "Summer")
        #expect(album.folders[1].identifier == nil)
        #expect(manifest.photos[0].reuseIdentifier == "reuse-1")
    }

    @Test func parseAlbumWithoutIdentifierOrFolders() throws {
        let xml = """
        <manifest><album><name>Apple Photos</name></album><photos></photos></manifest>
        """
        let manifest = try ImportCommand().parseManifestXML(try XMLDocument(xmlString: xml))
        let album = try #require(manifest.album)
        #expect(album.identifier == nil)
        #expect(album.name == "Apple Photos")
        #expect(album.folders.isEmpty)
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
            album: ManifestAlbum(identifier: "alb-1", name: "Family", folders: []),
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
            album: ManifestAlbum(identifier: "gone", name: "Family", folders: []),
            photos: [ManifestPhoto(path: file.path)])
        let xml = await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest)

        let album = try #require(try parseResult(xml).elements(forName: "album").first)
        #expect(album.elements(forName: "identifier").first?.stringValue == "created-1")
        #expect(album.elements(forName: "created").first?.stringValue == "true")
    }

    /// Inside a known folder a stale identifier adopts the album with the matching title,
    /// rather than leaving a duplicate beside it.
    @Test func adoptsAlbumByNameInsideFolder() async throws {
        let mock = MockPhotoLibrary()
        mock.collectionTitles["fld-1"] = "Trips"
        mock.collectionTitles["existing"] = "Family"
        mock.folderChildren["fld-1"] = ["existing"]

        let ref = try await mock.ensureAlbum(identifier: "gone", name: "Family", folder: "fld-1")
        #expect(ref == CollectionRef(identifier: "existing", created: false))
    }

    @Test func resolvesFolderChainOutermostFirst() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.importPhotoReturn = "new-id"

        let manifest = Manifest(
            album: ManifestAlbum(identifier: nil, name: "Family", folders: [
                ManifestFolder(identifier: nil, name: "Trips"),
                ManifestFolder(identifier: nil, name: "Summer")
            ]),
            photos: [ManifestPhoto(path: file.path)])
        _ = await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest)

        #expect(mock.ensureFolderCalls.count == 2)
        #expect(mock.ensureFolderCalls[0].name == "Trips")
        #expect(mock.ensureFolderCalls[0].parent == nil)
        // The second folder nests inside the first, which is what outermost-first buys.
        #expect(mock.ensureFolderCalls[1].name == "Summer")
        #expect(mock.ensureFolderCalls[1].parent == "created-1")
        #expect(mock.ensureAlbumCalls.first?.parent == "created-2")
    }

    /// Every resolved folder travels back with the album. Without their identifiers the
    /// plugin has nothing to record, and the next publish builds the chain a second time.
    @Test func reportsResolvedFolderChain() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.collectionTitles["fld-outer"] = "Trips"
        mock.importPhotoReturn = "new-id"

        let manifest = Manifest(
            album: ManifestAlbum(identifier: nil, name: "Family", folders: [
                ManifestFolder(identifier: "fld-outer", name: "Trips"),
                ManifestFolder(identifier: nil, name: "Summer")
            ]),
            photos: [ManifestPhoto(path: file.path)])
        let xml = await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest)

        let album = try #require(try parseResult(xml).elements(forName: "album").first)
        let folders = try #require(album.elements(forName: "folders").first)
            .elements(forName: "folder")
        #expect(folders.count == 2)
        // Outermost first, matching the manifest so the plugin can pair them up.
        #expect(folders[0].elements(forName: "identifier").first?.stringValue == "fld-outer")
        #expect(folders[0].elements(forName: "created").first?.stringValue == "false")
        #expect(folders[1].elements(forName: "created").first?.stringValue == "true")
    }

    @Test func omitsFoldersForATopLevelCollection() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.importPhotoReturn = "new-id"

        let manifest = Manifest(
            album: ManifestAlbum(identifier: nil, name: "Family", folders: []),
            photos: [ManifestPhoto(path: file.path)])
        let xml = await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest)

        let album = try #require(try parseResult(xml).elements(forName: "album").first)
        #expect(album.elements(forName: "folders").isEmpty)
    }

    /// Resolving the album happens before any import, so a failure leaves nothing half filed.
    @Test func albumFailureAbortsBeforeImporting() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.ensureAlbumError = PhotoKitError.operationNotPermitted(
            identifier: "alb-1", operation: "creating")

        let manifest = Manifest(
            album: ManifestAlbum(identifier: nil, name: "Family", folders: []),
            photos: [ManifestPhoto(path: file.path)])
        let root = try parseResult(
            await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest))

        #expect(root.elements(forName: "status").first?.stringValue == "error")
        #expect(root.elements(forName: "errorCode").first?.stringValue == "OPERATION_NOT_PERMITTED")
        #expect(mock.importPhotoCalls.isEmpty)
    }
}
