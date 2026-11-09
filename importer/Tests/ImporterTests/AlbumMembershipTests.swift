import Foundation
import Testing
@testable import lrphotosimporter

/// Tests for album membership, asset reuse and the deep links publishing records.
@Suite("Album membership")
struct AlbumMembershipTests {

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

    // MARK: - Membership

    @Test func filesImportedPhotosIntoTheAlbum() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.collectionTitles["alb-1"] = "Family"
        mock.albumContents["alb-1"] = []
        mock.importPhotoReturn = "new-id"

        let manifest = Manifest(
            album: ManifestAlbum(identifier: "alb-1", name: "Family"),
            photos: [ManifestPhoto(path: file.path)])
        _ = await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest)

        #expect(mock.addAssetCalls.contains { $0.0 == "new-id" && $0.1 == "alb-1" })
    }

    /// Photos ignores a duplicate add, but skipping it keeps the warning noise down.
    @Test func skipsPhotosAlreadyInTheAlbum() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.collectionTitles["alb-1"] = "Family"
        mock.albumContents["alb-1"] = ["new-id/L0/001"]
        mock.importPhotoReturn = "new-id/L0/001"

        let manifest = Manifest(
            album: ManifestAlbum(identifier: "alb-1", name: "Family"),
            photos: [ManifestPhoto(path: file.path)])
        _ = await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest)

        #expect(mock.addAssetCalls.isEmpty)
    }

    /// Membership is compared on the UUID prefix, so the `/L0/001` suffix cannot cause a
    /// photo already in the album to be added a second time.
    @Test func membershipComparisonIgnoresIdentifierSuffix() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.collectionTitles["alb-1"] = "Family"
        mock.albumContents["alb-1"] = ["abc-123/L0/001"]
        mock.importPhotoReturn = "abc-123/L0/004"

        let manifest = Manifest(
            album: ManifestAlbum(identifier: "alb-1", name: "Family"),
            photos: [ManifestPhoto(path: file.path)])
        _ = await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest)

        #expect(mock.addAssetCalls.isEmpty)
    }

    @Test func removeAssetsLeavesTheRestAlone() async throws {
        let mock = MockPhotoLibrary()
        mock.albumContents["alb-1"] = ["a", "b", "c"]

        try await mock.removeAssets(identifiers: ["b"], fromAlbum: "alb-1")
        #expect(await mock.assetIdentifiers(inAlbum: "alb-1") == ["a", "c"])
    }

    // MARK: - Reconcile

    /// Reconciling adds what the album is missing and takes out what it should not hold.
    @Test func syncSetsTheAlbumToExactlyWhatWasAskedFor() async throws {
        let mock = MockPhotoLibrary()
        mock.albumContents["alb-1"] = ["a", "b"]

        try await AlbumSync.apply(photoKit: mock, identifier: "alb-1", assets: ["a", "c"])

        #expect(await mock.assetIdentifiers(inAlbum: "alb-1") == ["a", "c"])
        #expect(mock.addAssetCalls.map(\.0) == ["c"])
    }

    /// A photo Lightroom still claims but Photos no longer has must not abandon the rest of
    /// the album, which by then has already had its surplus removed.
    @Test func syncCarriesOnPastAPhotoPhotosNoLongerHas() async throws {
        let mock = MockPhotoLibrary()
        mock.albumContents["alb-1"] = ["a", "surplus"]
        mock.existingAssets = ["a", "live"]

        try await AlbumSync.apply(
            photoKit: mock, identifier: "alb-1", assets: ["a", "deleted", "live"])

        #expect(await mock.assetIdentifiers(inAlbum: "alb-1") == ["a", "live"])
        #expect(mock.addAssetCalls.map(\.0) == ["deleted", "live"])
    }

    // MARK: - Reuse

    /// A photo merely added to another collection keeps its asset, so the collections already
    /// pointing at it are not orphaned.
    @Test func reusesExistingAssetWithoutImporting() async throws {
        let mock = MockPhotoLibrary()
        mock.collectionTitles["alb-1"] = "Family"
        mock.albumContents["alb-1"] = []
        mock.existingAssets = ["live-id"]

        // No file on disk: Lightroom skipped the render, so there is nothing to read.
        let manifest = Manifest(
            album: ManifestAlbum(identifier: "alb-1", name: "Family"),
            photos: [ManifestPhoto(path: "/nonexistent/skipped.jpg", reuseIdentifier: "live-id")])
        let root = try parseResult(
            await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest))

        let result = try #require(
            root.elements(forName: "results").first?.elements(forName: "result").first)
        #expect(result.elements(forName: "status").first?.stringValue == "success")
        #expect(result.elements(forName: "localIdentifier").first?.stringValue == "live-id")
        #expect(result.elements(forName: "reused").first?.stringValue == "true")
        #expect(mock.importPhotoCalls.isEmpty)
        // Reused or not, it still has to join the album.
        #expect(mock.addAssetCalls.contains { $0.0 == "live-id" && $0.1 == "alb-1" })
    }

    /// If the asset was deleted in Photos, reuse is not possible and the photo imports again.
    @Test func fallsBackToImportWhenReusedAssetIsGone() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.existingAssets = []
        mock.importPhotoReturn = "fresh-id"

        let manifest = Manifest(
            album: nil,
            photos: [ManifestPhoto(path: file.path, reuseIdentifier: "deleted-id")])
        let root = try parseResult(
            await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest))

        let result = try #require(
            root.elements(forName: "results").first?.elements(forName: "result").first)
        #expect(result.elements(forName: "localIdentifier").first?.stringValue == "fresh-id")
        #expect(result.elements(forName: "reused").first == nil)
        #expect(mock.importPhotoCalls.count == 1)
    }

    /// An asset deleted in Photos after the render was skipped on the strength of it leaves
    /// nothing to import. The plugin drops the identifier on that code, so the next publish
    /// renders rather than skipping again, and the message has to say that rather than
    /// reporting the missing file it caused.
    @Test func reportsTheMissingAssetRatherThanTheMissingFile() async throws {
        let mock = MockPhotoLibrary()
        mock.existingAssets = []

        let manifest = Manifest(
            album: nil,
            photos: [ManifestPhoto(path: "/nonexistent/skipped.jpg", reuseIdentifier: "deleted-id")])
        let root = try parseResult(
            await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest))

        let result = try #require(
            root.elements(forName: "results").first?.elements(forName: "result").first)
        #expect(result.elements(forName: "status").first?.stringValue == "error")
        #expect(result.elements(forName: "errorCode").first?.stringValue == "REUSE_MISSING")
        #expect(mock.importPhotoCalls.isEmpty)
    }

    // MARK: - Deep links

    /// Deep links point at the mirrored album so "Go to Published Photo" lands in the
    /// collection rather than the whole library.
    @Test func deepLinkPrefersTheMirroredAlbum() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.collectionTitles["alb-1/L0/040"] = "Family"
        mock.albumContents["alb-1/L0/040"] = []
        mock.importPhotoReturn = "asset-9/L0/001"
        mock.userLibraryAlbumIdentifierReturn = "library-id"

        let manifest = Manifest(
            album: ManifestAlbum(identifier: "alb-1/L0/040", name: "Family"),
            photos: [ManifestPhoto(path: file.path)])
        let root = try parseResult(
            await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest))

        let url = try #require(
            root.elements(forName: "results").first?.elements(forName: "result").first?
                .elements(forName: "url").first?.stringValue)
        #expect(url == "photos:albums?albumUuid=alb-1&assetUuid=asset-9")
    }

    @Test func deepLinkFallsBackToTheLibraryWithoutAnAlbum() async throws {
        let file = try makeFile()
        defer { try? FileManager.default.removeItem(at: file) }

        let mock = MockPhotoLibrary()
        mock.importPhotoReturn = "asset-9/L0/001"
        mock.userLibraryAlbumIdentifierReturn = "library-id/L0/009"

        let manifest = Manifest(album: nil, photos: [ManifestPhoto(path: file.path)])
        let root = try parseResult(
            await ImportCommand().executeBatchImport(photoKit: mock, manifest: manifest))

        let url = try #require(
            root.elements(forName: "results").first?.elements(forName: "result").first?
                .elements(forName: "url").first?.stringValue)
        #expect(url == "photos:albums?albumUuid=library-id&assetUuid=asset-9")
    }
}
