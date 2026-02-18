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
}

/// Command that imports photos into Apple Photos from an XML manifest file.
///
/// Reads a manifest listing photo file paths and optional previous identifiers,
/// then imports each photo into the Photos library. When a previous identifier is
/// provided, album memberships and favorite status are preserved on the new asset.
/// Results are output as XML to stdout.
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

    /// Parses an XML manifest document into an array of ``ManifestPhoto`` entries.
    /// - Parameter doc: The parsed XML document with a `<manifest>` root element.
    /// - Returns: An array of photos extracted from the manifest.
    /// - Throws: An error if the root element is missing or not named `manifest`.
    func parseManifestXML(_ doc: XMLDocument) throws -> [ManifestPhoto] {
        var photos: [ManifestPhoto] = []

        guard let root = doc.rootElement(), root.name == "manifest" else {
            throw NSError(
                domain: "ImportCommand",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid manifest: missing root element"]
            )
        }

        guard let photosElement = root.elements(forName: "photos").first else {
            return photos
        }

        for photoElement in photosElement.elements(forName: "photo") {
            guard let pathElement = photoElement.elements(forName: "path").first,
                  let path = pathElement.stringValue, !path.isEmpty else {
                continue
            }

            let previousIdentifier = photoElement.elements(forName: "previousIdentifier").first?.stringValue

            photos.append(ManifestPhoto(path: path, previousIdentifier: previousIdentifier))
        }

        return photos
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

        let photos: [ManifestPhoto]
        do {
            let data = try Data(contentsOf: manifestURL)
            let doc = try XMLDocument(data: data)
            photos = try parseManifestXML(doc)
        } catch {
            let msg = "Failed to parse manifest: \(error.localizedDescription)"
            print(XMLOutput.batchImportError(code: "MANIFEST_PARSE_ERROR", message: msg))
            return
        }

        print(await executeBatchImport(photoKit: PhotoKitAccessor(), photos: photos))
    }

    /// Execute a batch import with the given photos and photo library.
    /// Returns the XML result string.
    func executeBatchImport(
        photoKit: any PhotoLibrary,
        photos: [ManifestPhoto]
    ) async -> String {
        if photos.isEmpty {
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

        // Process each photo
        var results: [SingleImportResult] = []
        for photo in photos {
            let result = await importSinglePhoto(
                photoKit: photoKit, path: photo.path, previousIdentifier: photo.previousIdentifier
            )
            results.append(result)
        }

        let albumUuid = await photoKit.userLibraryAlbumIdentifier()?.uuidPrefix
        return XMLOutput.batchImportResult(results: results, albumUuid: albumUuid)
    }

    /// Imports a single photo, optionally preserving metadata from a previous version.
    ///
    /// If `previousIdentifier` is provided, album memberships and favorite status are
    /// fetched from the previous asset and restored on the newly imported photo.
    /// Failures during metadata restoration are logged to stderr but do not cause
    /// the overall import to fail.
    ///
    /// - Parameters:
    ///   - photoKit: The photo library to import into.
    ///   - path: File system path to the photo file.
    ///   - previousIdentifier: Optional local identifier of a previously published version.
    /// - Returns: A ``SingleImportResult`` describing the outcome.
    func importSinglePhoto(
        photoKit: any PhotoLibrary, path: String, previousIdentifier: String?
    ) async -> SingleImportResult {
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

        // Restore favorite status
        var favoriteRestored = false
        if wasFavorite {
            do {
                try await photoKit.setFavorite(true, forAsset: newIdentifier)
                favoriteRestored = true
            } catch {
                    let msg = "Warning: Failed to restore favorite status: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }

        // Restore album memberships
        var restoredAlbums: [AlbumMembership] = []
        for album in albumsToRestore {
            do {
                try await photoKit.addAsset(identifier: newIdentifier, toAlbum: album.uuid)
                restoredAlbums.append(album)
            } catch {
                // Log but continue - album restoration is best-effort
                let name = album.title ?? album.uuid
                let msg = "Warning: Failed to restore album \(name): \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
        }

        return .success(
            path: path,
            localIdentifier: newIdentifier,
            albumsRestored: restoredAlbums,
            favoriteRestored: favoriteRestored
        )
    }
}
