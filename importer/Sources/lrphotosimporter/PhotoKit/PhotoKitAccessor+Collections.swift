import Foundation
import Photos

/// Album and folder management, mirroring Lightroom's published collections and collection
/// sets into Photos.
///
/// Lives apart from the asset operations in ``PhotoKitAccessor`` because the two have little
/// to do with each other: these only ever touch containers, never the photos inside them.
extension PhotoKitAccessor {

    /// Fetch a folder by its local identifier
    func fetchFolder(withIdentifier identifier: String) async -> PHCollectionList? {
        PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

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

    /// The child of `folder` whose title matches `name` exactly, if there is one.
    private func child(of folder: PHCollectionList, titled name: String) -> PHCollection? {
        var match: PHCollection?
        PHCollection.fetchCollections(in: folder, options: nil)
            .enumerateObjects { collection, _, stop in
                if collection.localizedTitle == name {
                    match = collection
                    stop.pointee = true
                }
            }
        return match
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

    func ensureAlbum(identifier: String?, name: String, folder: String?) async throws -> CollectionRef {
        if let identifier, let found = await fetchAlbum(withIdentifier: identifier) {
            try await enforce(title: name, on: found) {
                try await self.renameAlbum(identifier: found.localIdentifier, to: name)
            }
            return CollectionRef(identifier: found.localIdentifier, created: false)
        }
        // Adopt by name only inside a known folder. At the top level the same check would
        // absorb an unrelated album the user happens to have given this name.
        if let folder, let parent = await fetchFolder(withIdentifier: folder),
           let adopted = child(of: parent, titled: name) as? PHAssetCollection {
            return CollectionRef(identifier: adopted.localIdentifier, created: false)
        }
        let created = try await create(name) {
            PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: name)
                .placeholderForCreatedAssetCollection
        }
        if folder != nil {
            try await move(identifier: created, toFolder: folder)
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

    // MARK: - Folders

    func ensureFolder(identifier: String?, name: String, parent: String?) async throws -> CollectionRef {
        if let identifier, let found = await fetchFolder(withIdentifier: identifier) {
            try await enforce(title: name, on: found) {
                try await self.renameFolder(identifier: found.localIdentifier, to: name)
            }
            return CollectionRef(identifier: found.localIdentifier, created: false)
        }
        if let parent, let container = await fetchFolder(withIdentifier: parent),
           let adopted = child(of: container, titled: name) as? PHCollectionList {
            return CollectionRef(identifier: adopted.localIdentifier, created: false)
        }
        let created = try await create(name) {
            PHCollectionListChangeRequest
                .creationRequestForCollectionList(withTitle: name)
                .placeholderForCreatedCollectionList
        }
        if parent != nil {
            try await move(identifier: created, toFolder: parent)
        }
        return CollectionRef(identifier: created, created: true)
    }

    func renameFolder(identifier: String, to name: String) async throws {
        guard let folder = await fetchFolder(withIdentifier: identifier) else {
            throw PhotoKitError.folderNotFound(identifier: identifier)
        }
        try require(folder, .rename, "renaming")
        try await applyRename(identifier, name) {
            PHCollectionListChangeRequest(for: folder)?.title = name
        }
    }

    func deleteFolder(identifier: String) async throws {
        guard let folder = await fetchFolder(withIdentifier: identifier) else { return }
        try require(folder, .delete, "deleting")
        // PhotoKit takes the folder's child collections with it. That matches Lightroom,
        // where deleting a collection set deletes its children, and assets survive either way.
        try await applyDelete(identifier, "folder") {
            PHCollectionListChangeRequest.deleteCollectionLists([folder] as NSArray)
        }
    }

    func move(identifier: String, toFolder folder: String?) async throws {
        let collection: PHCollection
        if let album = await fetchAlbum(withIdentifier: identifier) {
            collection = album
        } else if let existing = await fetchFolder(withIdentifier: identifier) {
            collection = existing
        } else {
            throw PhotoKitError.albumNotFound(identifier: identifier)
        }

        do {
            // A PHCollection has exactly one parent, so adding it to the destination moves it.
            if let folder {
                guard let parent = await fetchFolder(withIdentifier: folder) else {
                    throw PhotoKitError.folderNotFound(identifier: folder)
                }
                try require(parent, .addContent, "adding collections")
                try await perform("moving into the folder") {
                    PHCollectionListChangeRequest(for: parent)?
                        .addChildCollections([collection] as NSArray)
                }
            } else {
                let topLevel = PHCollection.fetchTopLevelUserCollections(with: nil)
                try await perform("moving to the top level") {
                    PHCollectionListChangeRequest(
                        forTopLevelCollectionListUserCollections: topLevel
                    )?.addChildCollections([collection] as NSArray)
                }
            }
        } catch let error as PhotoKitError {
            throw error
        } catch {
            throw PhotoKitError.moveCollectionFailed(
                identifier: identifier, reason: error.localizedDescription
            )
        }
    }
}
