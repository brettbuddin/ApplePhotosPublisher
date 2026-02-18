import Foundation
@testable import lrphotosimporter

final class MockPhotoLibrary: PhotoLibrary, @unchecked Sendable {

    // MARK: - Configuration

    var ensureWriteAccessError: Error?
    var albumsToReturn: [AlbumMembership] = []
    var isFavoriteReturn: Bool = false
    var setFavoriteError: Error?
    var importPhotoReturn: String = "mock-identifier"
    var importPhotoError: Error?
    var deleteAssetsError: Error?
    var addAssetError: Error?
    var userLibraryAlbumIdentifierReturn: String? = "user-library-id"

    // MARK: - Call Tracking

    var ensureWriteAccessCalled = false
    var fetchAlbumsCalls: [String] = []
    var isFavoriteCalls: [String] = []
    var setFavoriteCalls: [(Bool, String)] = []
    var importPhotoCalls: [URL] = []
    var deleteAssetsCalls: [[String]] = []
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
