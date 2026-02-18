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
    }

    func userLibraryAlbumIdentifier() async -> String? {
        return userLibraryAlbumIdentifierReturn
    }
}
