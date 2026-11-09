import Foundation
@testable import lrphotosimporter

/// Test double for ``PhotoLibrary`` that records calls and returns configurable responses.
///
/// Set the `*Return` and `*Error` properties to control behavior, then inspect
/// the `*Calls` and `*Called` properties to verify interactions.
final class MockPhotoLibrary: PhotoLibrary, @unchecked Sendable {

    // MARK: - Configuration

    /// Error to throw from ``ensureWriteAccess()``, or `nil` to succeed.
    var ensureWriteAccessError: Error?

    /// Albums returned by ``fetchAlbumsContaining(assetIdentifier:)``.
    var albumsToReturn: [AlbumMembership] = []

    /// Value returned by ``isFavorite(assetIdentifier:)``.
    var isFavoriteReturn: Bool = false

    /// Error to throw from ``setFavorite(_:forAsset:)``, or `nil` to succeed.
    var setFavoriteError: Error?

    /// Identifier returned by ``importPhoto(from:)`` on success.
    var importPhotoReturn: String = "mock-identifier"

    /// Error to throw from ``importPhoto(from:)``, or `nil` to succeed.
    var importPhotoError: Error?

    /// Error to throw from ``deleteAssets(identifiers:)``, or `nil` to succeed.
    var deleteAssetsError: Error?

    /// Error to throw from ``addAsset(identifier:toAlbum:)``, or `nil` to succeed.
    var addAssetError: Error?

    /// Value returned by ``userLibraryAlbumIdentifier()``.
    var userLibraryAlbumIdentifierReturn: String? = "user-library-id"

    // MARK: - Call Tracking

    /// Whether ``ensureWriteAccess()`` was called.
    var ensureWriteAccessCalled = false

    /// Asset identifiers passed to ``fetchAlbumsContaining(assetIdentifier:)``.
    var fetchAlbumsCalls: [String] = []

    /// Asset identifiers passed to ``isFavorite(assetIdentifier:)``.
    var isFavoriteCalls: [String] = []

    /// Arguments passed to ``setFavorite(_:forAsset:)`` as `(favorite, identifier)` tuples.
    var setFavoriteCalls: [(Bool, String)] = []

    /// File URLs passed to ``importPhoto(from:)``.
    var importPhotoCalls: [URL] = []

    /// Identifier arrays passed to ``deleteAssets(identifiers:)``.
    var deleteAssetsCalls: [[String]] = []

    /// Arguments passed to ``addAsset(identifier:toAlbum:)`` as `(assetID, albumID)` tuples.
    var addAssetCalls: [(String, String)] = []

    // MARK: - PhotoLibrary

    func ensureWriteAccess() async throws {
        ensureWriteAccessCalled = true
        if let error = ensureWriteAccessError { throw error }
    }

    func fetchAlbumsContaining(assetIdentifier: String) async -> [AlbumMembership] {
        fetchAlbumsCalls.append(assetIdentifier)
        return albumsToReturn
    }

    func isFavorite(assetIdentifier: String) async -> Bool {
        isFavoriteCalls.append(assetIdentifier)
        return isFavoriteReturn
    }

    func setFavorite(_ favorite: Bool, forAsset identifier: String) async throws {
        setFavoriteCalls.append((favorite, identifier))
        if let error = setFavoriteError { throw error }
    }

    func importPhoto(from url: URL) async throws -> String {
        importPhotoCalls.append(url)
        if let error = importPhotoError { throw error }
        return importPhotoReturn
    }

    func deleteAssets(identifiers: [String]) async throws {
        deleteAssetsCalls.append(identifiers)
        if let error = deleteAssetsError { throw error }
    }

    func addAsset(identifier: String, toAlbum albumIdentifier: String) async throws {
        addAssetCalls.append((identifier, albumIdentifier))
        if let error = addAssetError { throw error }
        // The real accessor fetches the asset first and reports it missing, which is what
        // callers have to cope with when Lightroom names a photo Photos no longer has.
        if let existingAssets, !existingAssets.contains(identifier) {
            throw PhotoKitError.assetNotFound(identifier: identifier)
        }
        albumContents[albumIdentifier, default: []].append(identifier)
    }

    func userLibraryAlbumIdentifier() async -> String? {
        return userLibraryAlbumIdentifierReturn
    }

    // MARK: - Collections

    /// Identifiers this mock reports as still present, consulted by ``assetExists(identifier:)``.
    /// `nil` means every asset exists.
    var existingAssets: Set<String>?

    /// Albums keyed by identifier, holding their asset identifiers in order.
    var albumContents: [String: [String]] = [:]

    /// Albums and folders this mock knows about, keyed by identifier, valued by title.
    var collectionTitles: [String: String] = [:]

    /// Identifier handed out by the next create. Each create appends a counter to it.
    var createdIdentifierPrefix = "created"

    var ensureAlbumError: Error?
    var renameError: Error?
    var deleteCollectionError: Error?
    var removeAssetsError: Error?

    /// A recorded ``ensureAlbum(identifier:name:)`` call.
    struct ResolveCall: Equatable {
        let identifier: String?
        let name: String
    }

    var ensureAlbumCalls: [ResolveCall] = []
    var renameCalls: [(identifier: String, name: String)] = []
    var deleteCollectionCalls: [String] = []
    var removeAssetsCalls: [(identifiers: [String], album: String)] = []
    private var createCount = 0

    func assetExists(identifier: String) async -> Bool {
        guard let existingAssets else { return true }
        return existingAssets.contains(identifier)
    }

    private func nextIdentifier() -> String {
        createCount += 1
        return "\(createdIdentifierPrefix)-\(createCount)"
    }

    /// Mirrors the accessor's found-or-created sequence.
    func ensureAlbum(identifier: String?, name: String) async throws -> CollectionRef {
        ensureAlbumCalls.append(ResolveCall(identifier: identifier, name: name))
        if let error = ensureAlbumError { throw error }

        let ref: CollectionRef
        if let identifier, collectionTitles[identifier] != nil {
            collectionTitles[identifier] = name
            ref = CollectionRef(identifier: identifier, created: false)
        } else {
            let created = nextIdentifier()
            collectionTitles[created] = name
            ref = CollectionRef(identifier: created, created: true)
        }
        if albumContents[ref.identifier] == nil { albumContents[ref.identifier] = [] }
        return ref
    }

    func renameAlbum(identifier: String, to name: String) async throws {
        renameCalls.append((identifier, name))
        if let error = renameError { throw error }
        collectionTitles[identifier] = name
    }

    func deleteAlbum(identifier: String) async throws {
        deleteCollectionCalls.append(identifier)
        if let error = deleteCollectionError { throw error }
        collectionTitles[identifier] = nil
        albumContents[identifier] = nil
    }

    func assetIdentifiers(inAlbum identifier: String) async -> [String] {
        return albumContents[identifier] ?? []
    }

    func removeAssets(identifiers: [String], fromAlbum identifier: String) async throws {
        removeAssetsCalls.append((identifiers, identifier))
        if let error = removeAssetsError { throw error }
        let removing = Set(identifiers)
        albumContents[identifier] = (albumContents[identifier] ?? []).filter { !removing.contains($0) }
    }
}
