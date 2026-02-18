import Foundation
import Photos

/// Real implementation using Photos.framework for the importer tool
///
/// Note: This class is marked `@unchecked Sendable` because it has no mutable state
/// and all PHPhotoLibrary methods are thread-safe.
final class PhotoKitAccessor: PhotoLibrary, @unchecked Sendable {

    // MARK: - Authorization

    /// Check current authorization status
    func authorizationStatus() async -> PHAuthorizationStatus {
        return PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// Request authorization if needed
    func requestAuthorization() async -> PHAuthorizationStatus {
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Ensure we have read access, throwing if not
    func ensureReadAccess() async throws {
        let status = await authorizationStatus()

        switch status {
        case .authorized, .limited:
            return
        case .notDetermined:
            let newStatus = await requestAuthorization()
            if newStatus != .authorized && newStatus != .limited {
                throw PhotoKitError.readAuthorizationDenied
            }
        default:
            throw PhotoKitError.readAuthorizationDenied
        }
    }

    /// Ensure we have write access, throwing if not
    func ensureWriteAccess() async throws {
        let status = await authorizationStatus()

        switch status {
        case .authorized:
            return
        case .notDetermined:
            let newStatus = await requestAuthorization()
            if newStatus != .authorized {
                throw PhotoKitError.writeAuthorizationDenied
            }
        default:
            throw PhotoKitError.writeAuthorizationDenied
        }
    }

    // MARK: - Asset Operations

    /// Fetch an asset by its local identifier
    func fetchAsset(withIdentifier identifier: String) async -> PHAsset? {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        return result.firstObject
    }

    /// Check if an asset is accessible
    func isAssetAccessible(identifier: String) async -> Bool {
        guard let asset = await fetchAsset(withIdentifier: identifier) else {
            return false
        }
        return asset.mediaType != .unknown
    }

    /// Fetch all albums containing a specific asset
    func fetchAlbumsContaining(assetIdentifier: String) async -> [AlbumMembership] {
        guard let asset = await fetchAsset(withIdentifier: assetIdentifier) else {
            return []
        }

        let collections = PHAssetCollection.fetchAssetCollectionsContaining(
            asset,
            with: .album,
            options: nil
        )

        var memberships: [AlbumMembership] = []
        collections.enumerateObjects { collection, _, _ in
            memberships.append(AlbumMembership(
                uuid: collection.localIdentifier,
                title: collection.localizedTitle
            ))
        }
        return memberships
    }

    /// Fetch an album by its local identifier
    func fetchAlbum(withIdentifier identifier: String) async -> PHAssetCollection? {
        let result = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [identifier],
            options: nil
        )
        return result.firstObject
    }

    /// Check if an asset is marked as favorite
    func isFavorite(assetIdentifier: String) async -> Bool {
        guard let asset = await fetchAsset(withIdentifier: assetIdentifier) else {
            return false
        }
        return asset.isFavorite
    }

    /// Set the favorite status on an asset
    func setFavorite(_ favorite: Bool, forAsset identifier: String) async throws {
        guard let asset = await fetchAsset(withIdentifier: identifier) else {
            throw PhotoKitError.assetNotFound(identifier: identifier)
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetChangeRequest(for: asset)
            request.isFavorite = favorite
        }
    }

    // MARK: - Import

    /// Import a photo from a file URL
    /// - Parameter url: The file URL of the photo to import
    /// - Returns: The local identifier of the imported asset
    func importPhoto(from url: URL) async throws -> String {
        var localIdentifier: String?

        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false

            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: url, options: options)

            localIdentifier = request.placeholderForCreatedAsset?.localIdentifier
        }

        guard let identifier = localIdentifier else {
            throw PhotoKitError.importFailed(
                path: url,
                reason: "Asset placeholder not created"
            )
        }

        // Verify the UUID is queryable with retries
        let maxRetries = 3
        let retryDelay: UInt64 = 100_000_000 // 100ms

        for attempt in 1...maxRetries {
            if await isAssetAccessible(identifier: identifier) {
                return identifier
            }
            if attempt < maxRetries {
                try? await Task.sleep(nanoseconds: retryDelay)
            }
        }

        // Return identifier even if not immediately accessible
        return identifier
    }

    // MARK: - Delete

    /// Delete assets by their local identifiers
    func deleteAssets(identifiers: [String]) async throws {
        if identifiers.isEmpty { return }

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { // swiftlint:disable:this empty_count
            throw PhotoKitError.deleteFailed(
                identifiers: identifiers,
                reason: "No assets found with provided identifiers"
            )
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch {
            throw PhotoKitError.deleteFailed(
                identifiers: identifiers,
                reason: error.localizedDescription
            )
        }
    }

    // MARK: - Album Operations

    /// Fetch the User Library smart album identifier
    func userLibraryAlbumIdentifier() async -> String? {
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumUserLibrary,
            options: nil
        )
        return albums.firstObject?.localIdentifier
    }

    /// Add an asset to an album
    func addAsset(identifier: String, toAlbum albumIdentifier: String) async throws {
        guard let asset = await fetchAsset(withIdentifier: identifier) else {
            throw PhotoKitError.assetNotFound(identifier: identifier)
        }

        guard let album = await fetchAlbum(withIdentifier: albumIdentifier) else {
            throw PhotoKitError.albumNotFound(identifier: albumIdentifier)
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let albumChangeRequest = PHAssetCollectionChangeRequest(for: album) else {
                    return
                }
                albumChangeRequest.addAssets(NSArray(object: asset))
            }
        } catch {
            throw PhotoKitError.addToAlbumFailed(
                assetID: identifier,
                albumID: albumIdentifier,
                reason: error.localizedDescription
            )
        }
    }
}
