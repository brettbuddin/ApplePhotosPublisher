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

    /// Reports whether an asset is still present in the library.
    ///
    /// Used before reusing a recorded identifier, since the asset may have been deleted in
    /// Photos since the plugin last saw it.
    func assetExists(identifier: String) async -> Bool

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

    // MARK: - Albums

    /// Resolves the album for a published collection, creating it when necessary.
    ///
    /// Tries `identifier` first, and creates a new album when it is absent or dangling.
    /// Albums are never matched by name: they all sit at the top level, where that would
    /// silently absorb an unrelated album the user happens to have named the same thing.
    /// - Parameters:
    ///   - identifier: The album identifier the plugin recorded previously, if any.
    ///   - name: The collection's name, used as the album title.
    /// - Returns: The resolved album and whether it had to be created.
    func ensureAlbum(identifier: String?, name: String) async throws -> CollectionRef

    /// Renames an album.
    /// - Throws: ``PhotoKitError/albumNotFound(identifier:)`` if it no longer exists.
    func renameAlbum(identifier: String, to name: String) async throws

    /// Deletes an album, leaving its assets in the library.
    ///
    /// Raises the macOS confirmation dialog. A refusal throws
    /// ``PhotoKitError/userCancelled(operation:)``.
    func deleteAlbum(identifier: String) async throws

    /// Returns the local identifiers of the assets in an album, in album order.
    /// - Returns: The identifiers, or an empty array if the album does not exist.
    func assetIdentifiers(inAlbum identifier: String) async -> [String]

    /// Removes assets from an album without deleting them from the library.
    ///
    /// Identifiers that are not in the album are ignored.
    func removeAssets(identifiers: [String], fromAlbum identifier: String) async throws
}
