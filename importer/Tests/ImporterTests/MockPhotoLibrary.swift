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

    /// Children of each folder, keyed by folder identifier, so adoption by name can be tested.
    var folderChildren: [String: [String]] = [:]

    /// Identifier handed out by the next create. Each create appends a counter to it.
    var createdIdentifierPrefix = "created"

    var ensureAlbumError: Error?
    var renameError: Error?
    var deleteCollectionError: Error?
    var removeAssetsError: Error?
    var moveError: Error?

    /// A recorded ``ensureAlbum(identifier:name:folder:)`` or
    /// ``ensureFolder(identifier:name:parent:)`` call.
    struct ResolveCall: Equatable {
        let identifier: String?
        let name: String
        /// The parent folder, which is `folder` for albums and `parent` for folders.
        let parent: String?
    }

    var ensureAlbumCalls: [ResolveCall] = []
    var ensureFolderCalls: [ResolveCall] = []
    var renameCalls: [(identifier: String, name: String)] = []
    var deleteCollectionCalls: [String] = []
    var removeAssetsCalls: [(identifiers: [String], album: String)] = []
    var moveCalls: [(identifier: String, folder: String?)] = []

    private var createCount = 0

    func assetExists(identifier: String) async -> Bool {
        guard let existingAssets else { return true }
        return existingAssets.contains(identifier)
    }

    private func nextIdentifier() -> String {
        createCount += 1
        return "\(createdIdentifierPrefix)-\(createCount)"
    }

    /// Mirrors the accessor's found, adopted or created sequence.
    private func resolve(
        identifier: String?, name: String, parent: String?
    ) -> CollectionRef {
        if let identifier, collectionTitles[identifier] != nil {
            return CollectionRef(identifier: identifier, created: false)
        }
        if let parent, let children = folderChildren[parent],
           let adopted = children.first(where: { collectionTitles[$0] == name }) {
            return CollectionRef(identifier: adopted, created: false)
        }
        let created = nextIdentifier()
        collectionTitles[created] = name
        if let parent {
            folderChildren[parent, default: []].append(created)
        }
        return CollectionRef(identifier: created, created: true)
    }

    func ensureAlbum(identifier: String?, name: String, folder: String?) async throws -> CollectionRef {
        ensureAlbumCalls.append(ResolveCall(identifier: identifier, name: name, parent: folder))
        if let error = ensureAlbumError { throw error }
        let ref = resolve(identifier: identifier, name: name, parent: folder)
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

    func ensureFolder(identifier: String?, name: String, parent: String?) async throws -> CollectionRef {
        ensureFolderCalls.append(ResolveCall(identifier: identifier, name: name, parent: parent))
        return resolve(identifier: identifier, name: name, parent: parent)
    }

    func renameFolder(identifier: String, to name: String) async throws {
        renameCalls.append((identifier, name))
        if let error = renameError { throw error }
        collectionTitles[identifier] = name
    }

    func deleteFolder(identifier: String) async throws {
        deleteCollectionCalls.append(identifier)
        if let error = deleteCollectionError { throw error }
        collectionTitles[identifier] = nil
    }

    func move(identifier: String, toFolder folder: String?) async throws {
        moveCalls.append((identifier, folder))
        if let error = moveError { throw error }
        for key in folderChildren.keys {
            folderChildren[key] = folderChildren[key]?.filter { $0 != identifier }
        }
        if let folder {
            folderChildren[folder, default: []].append(identifier)
        }
    }
}
