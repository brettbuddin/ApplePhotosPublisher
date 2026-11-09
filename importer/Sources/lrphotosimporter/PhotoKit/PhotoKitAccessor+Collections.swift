import Foundation
import Photos

/// Album management, mirroring Lightroom's published collections into Photos.
///
/// Lives apart from the asset operations in ``PhotoKitAccessor`` because the two have little
/// to do with each other: these only ever touch containers, never the photos inside them.
extension PhotoKitAccessor {

    /// Fetch a folder by its local identifier
    /// Rename a container back to its collection's name when the two have diverged.
    ///
    /// Renames only ever travel from Lightroom to Photos, so without this a container renamed
    /// inside Photos would keep that name forever. Lightroom is the authority on titles the
    /// same way it is on membership. A rename Photos refuses is reported rather than
    /// swallowed, since it means the mirror is wrong.
    private func enforce(
        title: String, on collection: PHCollection, _ rename: () async throws -> Void
    ) async throws {
        guard collection.localizedTitle != title else { return }
        guard collection.canPerform(.rename) else {
            // Nothing to be done about a container Photos will not let us rename, and the
            // batch is more important than its name.
            let msg = "Warning: Photos does not allow renaming "
                + "\(collection.localizedTitle ?? collection.localIdentifier) to \(title)\n"
            FileHandle.standardError.write(Data(msg.utf8))
            return
        }
        try await rename()
    }

    /// Creates a container and returns its identifier, mapping failures to one error.
    private func create(
        _ name: String, _ placeholder: @escaping () -> PHObjectPlaceholder?
    ) async throws -> String {
        var identifier: String?
        do {
            try await perform("creating \(name)") {
                identifier = placeholder()?.localIdentifier
            }
        } catch let error as PhotoKitError {
            throw error
        } catch {
            throw PhotoKitError.createCollectionFailed(name: name, reason: error.localizedDescription)
        }
        guard let identifier else {
            throw PhotoKitError.createCollectionFailed(name: name, reason: "Placeholder not created")
        }
        return identifier
    }

    private func applyRename(
        _ identifier: String, _ name: String, _ changes: @escaping () -> Void
    ) async throws {
        do {
            try await perform("renaming to \(name)", changes)
        } catch let error as PhotoKitError {
            throw error
        } catch {
            throw PhotoKitError.renameCollectionFailed(
                identifier: identifier, name: name, reason: error.localizedDescription
            )
        }
    }

    private func applyDelete(
        _ identifier: String, _ what: String, _ changes: @escaping () -> Void
    ) async throws {
        do {
            try await perform("deleting the \(what)", changes)
        } catch let error as PhotoKitError {
            throw error
        } catch {
            throw PhotoKitError.deleteCollectionFailed(
                identifier: identifier, reason: error.localizedDescription
            )
        }
    }

    func ensureAlbum(identifier: String?, name: String) async throws -> CollectionRef {
        if let identifier, let found = await fetchAlbum(withIdentifier: identifier) {
            try await enforce(title: name, on: found) {
                try await self.renameAlbum(identifier: found.localIdentifier, to: name)
            }
            return CollectionRef(identifier: found.localIdentifier, created: false)
        }
        // No matching by name. Albums all sit at the top level, where an album the user
        // happens to have given this name would be absorbed by mistake.
        let created = try await create(name) {
            PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: name)
                .placeholderForCreatedAssetCollection
        }
        return CollectionRef(identifier: created, created: true)
    }

    func renameAlbum(identifier: String, to name: String) async throws {
        guard let album = await fetchAlbum(withIdentifier: identifier) else {
            throw PhotoKitError.albumNotFound(identifier: identifier)
        }
        try require(album, .rename, "renaming")
        try await applyRename(identifier, name) {
            PHAssetCollectionChangeRequest(for: album)?.title = name
        }
    }

    func deleteAlbum(identifier: String) async throws {
        guard let album = await fetchAlbum(withIdentifier: identifier) else {
            // Already gone is the state the caller wanted.
            return
        }
        try require(album, .delete, "deleting")
        try await applyDelete(identifier, "album") {
            PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
        }
    }

    func assetIdentifiers(inAlbum identifier: String) async -> [String] {
        guard let album = await fetchAlbum(withIdentifier: identifier) else { return [] }
        var identifiers: [String] = []
        PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { asset, _, _ in
            identifiers.append(asset.localIdentifier)
        }
        return identifiers
    }

    func removeAssets(identifiers: [String], fromAlbum identifier: String) async throws {
        if identifiers.isEmpty { return }
        guard let album = await fetchAlbum(withIdentifier: identifier) else {
            throw PhotoKitError.albumNotFound(identifier: identifier)
        }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        guard assets.count > 0 else { return } // swiftlint:disable:this empty_count
        try require(album, .removeContent, "removing photos")
        do {
            try await perform("removing photos from the album") {
                PHAssetCollectionChangeRequest(for: album)?.removeAssets(assets)
            }
        } catch let error as PhotoKitError {
            throw error
        } catch {
            throw PhotoKitError.removeFromAlbumFailed(
                albumID: identifier, reason: error.localizedDescription
            )
        }
    }
}
