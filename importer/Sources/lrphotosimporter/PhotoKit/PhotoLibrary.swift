import Foundation

/// Protocol abstracting Photos library operations for testability.
///
/// The production implementation is ``PhotoKitAccessor``; tests use ``MockPhotoLibrary``.
protocol PhotoLibrary: Sendable {
    /// Ensures the app has write access to the Photos library, requesting authorization if needed.
    /// - Throws: ``PhotoKitError/writeAuthorizationDenied`` if access is not granted.
    func ensureWriteAccess() async throws

    /// Returns all albums that contain the asset with the given identifier.
    /// - Parameter assetIdentifier: The local identifier (UUID prefix) of the asset to look up.
    /// - Returns: An array of ``AlbumMembership`` values for each album the asset belongs to.
    func fetchAlbumsContaining(assetIdentifier: String) async -> [AlbumMembership]

    /// Checks whether the asset with the given identifier is marked as a favorite.
    /// - Parameter assetIdentifier: The local identifier (UUID prefix) of the asset.
    /// - Returns: `true` if the asset is a favorite, `false` otherwise or if not found.
    func isFavorite(assetIdentifier: String) async -> Bool

    /// Sets or clears the favorite flag on an asset.
    /// - Parameters:
    ///   - favorite: Whether the asset should be marked as a favorite.
    ///   - identifier: The local identifier of the asset.
    /// - Throws: ``PhotoKitError/assetNotFound(identifier:)`` if the asset does not exist.
    func setFavorite(_ favorite: Bool, forAsset identifier: String) async throws

    /// Imports a photo file into the Photos library.
    /// - Parameter url: The file URL of the photo to import.
    /// - Returns: The local identifier of the newly created asset.
    /// - Throws: ``PhotoKitError/importFailed(path:reason:)`` if the import fails.
    func importPhoto(from url: URL) async throws -> String

    /// Deletes assets from the Photos library by their local identifiers.
    /// - Parameter identifiers: The local identifiers of the assets to delete.
    /// - Throws: ``PhotoKitError/deleteFailed(identifiers:reason:)`` if deletion fails.
    func deleteAssets(identifiers: [String]) async throws

    /// Adds an asset to an existing album.
    /// - Parameters:
    ///   - identifier: The local identifier of the asset to add.
    ///   - albumIdentifier: The local identifier of the target album.
    /// - Throws: ``PhotoKitError`` if the asset or album is not found, or the operation fails.
    func addAsset(identifier: String, toAlbum albumIdentifier: String) async throws

    /// Returns the local identifier of the User Library smart album, if available.
    /// - Returns: The local identifier string, or `nil` if the album cannot be found.
    func userLibraryAlbumIdentifier() async -> String?
}
