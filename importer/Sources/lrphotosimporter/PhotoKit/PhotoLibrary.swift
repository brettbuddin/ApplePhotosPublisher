import Foundation

/// Protocol abstracting Photos library operations for testability
protocol PhotoLibrary: Sendable {
    func ensureWriteAccess() async throws
    func fetchAlbumsContaining(assetIdentifier: String) async -> [AlbumMembership]
    func isFavorite(assetIdentifier: String) async -> Bool
    func setFavorite(_ favorite: Bool, forAsset identifier: String) async throws
    func importPhoto(from url: URL) async throws -> String
    func deleteAssets(identifiers: [String]) async throws
    func addAsset(identifier: String, toAlbum albumIdentifier: String) async throws
    func userLibraryAlbumIdentifier() async -> String?
}
