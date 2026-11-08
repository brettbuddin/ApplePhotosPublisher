import ArgumentParser
import Foundation

/// A single entry from the batch import manifest file.
///
/// Each entry represents a photo to import, optionally referencing a previously
/// published photo whose album memberships and favorite status should be preserved.
struct ManifestPhoto {
    /// File system path to the rendered photo to import.
    let path: String

    /// Local identifier of the previously published version of this photo, if any.
    ///
    /// When present, the import process will copy album memberships and favorite
    /// status from the previous asset to the newly imported one.
    let previousIdentifier: String?

    /// Local identifier of an existing asset to file into the album instead of importing.
    ///
    /// Set when a photo is merely being added to another collection: its asset is already
    /// current, so Lightroom skipped the render and there is no file to read. Reusing it
    /// avoids replacing an asset that other collections still reference.
    let reuseIdentifier: String?

    init(path: String, previousIdentifier: String? = nil, reuseIdentifier: String? = nil) {
        self.path = path
        self.previousIdentifier = previousIdentifier
        self.reuseIdentifier = reuseIdentifier
    }
}

/// The album a batch should be filed into, mirroring the published collection.
struct ManifestAlbum {
    /// Identifier recorded by a previous publish, which may be absent or stale.
    let identifier: String?

    /// The collection's name, used as the album title.
    let name: String
}

/// A parsed import manifest.
struct Manifest {
    /// The album to file the batch into, absent when publishing without one.
    let album: ManifestAlbum?

    /// The photos to import or reuse.
    let photos: [ManifestPhoto]
}

/// Command that imports photos into Apple Photos from an XML manifest file.
///
/// Reads a manifest listing photo file paths and optional previous identifiers,
/// then imports each photo into the Photos library. When a previous identifier is
/// provided, album memberships and favorite status are preserved on the new asset.
/// The manifest also carries its target album, so creating the album, importing the batch
/// and setting membership all happen in one helper launch. Results are output as XML to
/// stdout.
struct ImportCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import photos into Apple Photos"
    )

    @Option(name: .customLong("manifest"), help: "Path to XML manifest file for batch import")
    var manifestPath: String

    /// Entry point that reads the manifest and runs the batch import.
    mutating func run() async {
        await runBatchImport(manifestPath: manifestPath)
    }

    // MARK: - Batch Import

    /// Parses an XML manifest document.
    /// - Parameter doc: The parsed XML document with a `<manifest>` root element.
    /// - Returns: The album target and photos extracted from the manifest.
    /// - Throws: An error if the root element is missing or not named `manifest`.
    func parseManifestXML(_ doc: XMLDocument) throws -> Manifest {
        guard let root = doc.rootElement(), root.name == "manifest" else {
            throw NSError(
                domain: "ImportCommand",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid manifest: missing root element"]
            )
        }

        return Manifest(album: parseAlbum(root), photos: parsePhotos(root))
    }

    /// Reads the optional `<album>` block.
    private func parseAlbum(_ root: XMLElement) -> ManifestAlbum? {
        guard let element = root.elements(forName: "album").first,
              let name = element.elements(forName: "name").first?.stringValue, !name.isEmpty else {
            return nil
        }

        return ManifestAlbum(identifier: nonEmpty(element, "identifier"), name: name)
    }

    private func parsePhotos(_ root: XMLElement) -> [ManifestPhoto] {
        guard let photosElement = root.elements(forName: "photos").first else {
            return []
        }

        var photos: [ManifestPhoto] = []
        for photoElement in photosElement.elements(forName: "photo") {
            guard let pathElement = photoElement.elements(forName: "path").first,
                  let path = pathElement.stringValue, !path.isEmpty else {
                continue
            }
            photos.append(ManifestPhoto(
                path: path,
                previousIdentifier: nonEmpty(photoElement, "previousIdentifier"),
                reuseIdentifier: nonEmpty(photoElement, "reuseIdentifier")
            ))
        }
        return photos
    }

    /// The text of a child element, treating empty as absent.
    private func nonEmpty(_ element: XMLElement, _ name: String) -> String? {
        guard let value = element.elements(forName: name).first?.stringValue, !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Reads and parses the manifest file, then performs the batch import.
    /// - Parameter manifestPath: File system path to the XML manifest.
    private func runBatchImport(manifestPath: String) async {
        // Read and parse manifest
        let manifestURL = URL(fileURLWithPath: manifestPath)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            let msg = "Manifest file does not exist: \(manifestPath)"
            print(XMLOutput.batchImportError(code: "MANIFEST_NOT_FOUND", message: msg))
            return
        }

        let manifest: Manifest
        do {
            let data = try Data(contentsOf: manifestURL)
            let doc = try XMLDocument(data: data)
            manifest = try parseManifestXML(doc)
        } catch {
            let msg = "Failed to parse manifest: \(error.localizedDescription)"
            print(XMLOutput.batchImportError(code: "MANIFEST_PARSE_ERROR", message: msg))
            return
        }

        print(await executeBatchImport(photoKit: PhotoKitAccessor(), manifest: manifest))
    }

    /// Execute a batch import with the given manifest and photo library.
    /// Returns the XML result string.
    func executeBatchImport(
        photoKit: any PhotoLibrary,
        manifest: Manifest
    ) async -> String {
        if manifest.photos.isEmpty && manifest.album == nil {
            return XMLOutput.batchImportResult(results: [], albumUuid: nil)
        }

        // Ensure authorization once for the batch
        do {
            try await photoKit.ensureWriteAccess()
        } catch let error as PhotoKitError {
            let msg = error.errorDescription ?? "Authorization failed"
            return XMLOutput.batchImportError(code: error.code, message: msg)
        } catch {
            return XMLOutput.batchImportError(code: "AUTH_ERROR", message: error.localizedDescription)
        }

        // Resolve the album before importing anything. Creating containers never prompts, so
        // a failure here is genuine, and failing now leaves no half-filed batch behind.
        var album: CollectionRef?
        if let target = manifest.album {
            do {
                album = try await photoKit.ensureAlbum(
                    identifier: target.identifier, name: target.name)
            } catch let error as PhotoKitError {
                return XMLOutput.batchImportError(
                    code: error.code, message: error.errorDescription ?? "Could not resolve the album")
            } catch {
                return XMLOutput.batchImportError(
                    code: "ALBUM_FAILED", message: error.localizedDescription)
            }
        }

        // Process each photo
        var results: [SingleImportResult] = []
        for photo in manifest.photos {
            results.append(await importSinglePhoto(
                photoKit: photoKit,
                path: photo.path,
                previousIdentifier: photo.previousIdentifier,
                reuseIdentifier: photo.reuseIdentifier
            ))
        }

        if let album {
            await fileIntoAlbum(photoKit: photoKit, album: album.identifier, results: results)
        }

        // Prefer the mirrored album for deep links so "Go to Published Photo" lands in the
        // collection's album rather than the whole library.
        let albumUuid: String?
        if let album {
            albumUuid = album.identifier.uuidPrefix
        } else {
            albumUuid = (await photoKit.userLibraryAlbumIdentifier())?.uuidPrefix
        }
        return XMLOutput.batchImportResult(results: results, albumUuid: albumUuid, album: album)
    }

    /// Adds the batch's assets to the album, skipping any already in it.
    ///
    /// Photos ignores a duplicate add rather than creating a second entry, so this check is
    /// not load-bearing; it keeps the warning noise down and the reconcile path honest.
    private func fileIntoAlbum(
        photoKit: any PhotoLibrary, album: String, results: [SingleImportResult]
    ) async {
        let present = Set(await photoKit.assetIdentifiers(inAlbum: album).map(\.uuidPrefix))
        for result in results {
            guard result.status == "success", let identifier = result.localIdentifier,
                  !present.contains(identifier.uuidPrefix) else {
                continue
            }
            do {
                try await photoKit.addAsset(identifier: identifier, toAlbum: album)
            } catch {
                let msg = "Warning: Failed to add \(identifier) to the album: "
                    + "\(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }
    }

    /// Imports a single photo, optionally preserving metadata from a previous version.
    ///
    /// When `reuseIdentifier` names an asset that still exists, that asset is used as-is and
    /// nothing is imported: the photo is only being added to another collection, so replacing
    /// its asset would orphan the collections already pointing at it.
    ///
    /// Otherwise, if `previousIdentifier` is provided, album memberships and favorite status
    /// are fetched from the previous asset and restored on the newly imported one. Failures
    /// during metadata restoration are logged to stderr but do not cause the overall import
    /// to fail.
    ///
    /// - Parameters:
    ///   - photoKit: The photo library to import into.
    ///   - path: File system path to the photo file.
    ///   - previousIdentifier: Optional local identifier of a previously published version.
    ///   - reuseIdentifier: Optional local identifier of an asset to reuse instead of importing.
    /// - Returns: A ``SingleImportResult`` describing the outcome.
    func importSinglePhoto(
        photoKit: any PhotoLibrary,
        path: String,
        previousIdentifier: String?,
        reuseIdentifier: String? = nil
    ) async -> SingleImportResult {
        // Check reuse before the file: a skipped render leaves no file to find.
        if let reuseIdentifier, !reuseIdentifier.isEmpty,
           await photoKit.assetExists(identifier: reuseIdentifier.uuidPrefix) {
            return .success(
                path: path, localIdentifier: reuseIdentifier,
                albumsRestored: [], favoriteRestored: false, reused: true
            )
        }

        let fileURL = URL(fileURLWithPath: path)

        // Validate file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .error(path: path, code: "FILE_NOT_FOUND", message: "File does not exist: \(path)")
        }

        // Fetch album memberships and favorite status from previous photo if provided
        var albumsToRestore: [AlbumMembership] = []
        var wasFavorite = false
        if let previousID = previousIdentifier?.uuidPrefix, !previousID.isEmpty {
            albumsToRestore = await photoKit.fetchAlbumsContaining(assetIdentifier: previousID)
            wasFavorite = await photoKit.isFavorite(assetIdentifier: previousID)
        }

        // Import the photo
        let newIdentifier: String
        do {
            newIdentifier = try await photoKit.importPhoto(from: fileURL)
        } catch let error as PhotoKitError {
            return .error(path: path, code: error.code, message: error.errorDescription ?? "Import failed")
        } catch {
            return .error(path: path, code: "IMPORT_FAILED", message: error.localizedDescription)
        }

        let restored = await restore(
            photoKit: photoKit, onto: newIdentifier, albums: albumsToRestore, favorite: wasFavorite)

        return .success(
            path: path,
            localIdentifier: newIdentifier,
            albumsRestored: restored.albums,
            favoriteRestored: restored.favorite
        )
    }

    /// Copies favorite status and album memberships onto a freshly imported asset.
    ///
    /// Best effort by design: a photo that imported successfully should not be reported as a
    /// failure because one album could not be restored, so problems go to stderr and the
    /// return value says what actually stuck.
    private func restore(
        photoKit: any PhotoLibrary,
        onto identifier: String,
        albums: [AlbumMembership],
        favorite: Bool
    ) async -> (albums: [AlbumMembership], favorite: Bool) {
        var favoriteRestored = false
        if favorite {
            do {
                try await photoKit.setFavorite(true, forAsset: identifier)
                favoriteRestored = true
            } catch {
                let msg = "Warning: Failed to restore favorite status: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }

        var restoredAlbums: [AlbumMembership] = []
        for album in albums {
            do {
                try await photoKit.addAsset(identifier: identifier, toAlbum: album.uuid)
                restoredAlbums.append(album)
            } catch {
                let name = album.title ?? album.uuid
                let msg = "Warning: Failed to restore album \(name): \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }

        return (restoredAlbums, favoriteRestored)
    }
}
