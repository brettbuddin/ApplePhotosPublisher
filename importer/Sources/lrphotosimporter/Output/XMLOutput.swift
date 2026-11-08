import Foundation

/// Represents the result of importing a single photo in a batch.
///
/// Use the ``success(path:localIdentifier:albumsRestored:favoriteRestored:)`` and
/// ``error(path:code:message:)`` factory methods to create instances.
struct SingleImportResult {
    /// The file path of the photo that was imported (or attempted).
    let path: String

    /// `"success"` or `"error"` indicating the outcome.
    let status: String

    /// The Photos library local identifier of the newly created asset, or `nil` on error.
    let localIdentifier: String?

    /// Albums whose membership was restored from the previous version of the photo.
    let albumsRestored: [AlbumMembership]

    /// Whether the favorite status was successfully restored from the previous version.
    let favoriteRestored: Bool

    /// Whether an existing asset was reused instead of importing a new one.
    ///
    /// True when the photo was only being added to another collection, so its asset was
    /// already current and replacing it would have orphaned the collections pointing at it.
    let reused: Bool

    /// A machine-readable error code, or `nil` on success.
    let errorCode: String?

    /// A human-readable error message, or `nil` on success.
    let errorMessage: String?

    /// Creates a successful import result.
    /// - Parameters:
    ///   - path: The file path of the imported photo.
    ///   - localIdentifier: The Photos library local identifier of the new asset.
    ///   - albumsRestored: Albums whose membership was restored.
    ///   - favoriteRestored: Whether the favorite flag was restored.
    ///   - reused: Whether an existing asset was reused instead of imported.
    static func success(
        path: String,
        localIdentifier: String,
        albumsRestored: [AlbumMembership],
        favoriteRestored: Bool,
        reused: Bool = false
    ) -> SingleImportResult {
        SingleImportResult(
            path: path,
            status: "success",
            localIdentifier: localIdentifier,
            albumsRestored: albumsRestored,
            favoriteRestored: favoriteRestored,
            reused: reused,
            errorCode: nil,
            errorMessage: nil
        )
    }

    /// Creates a failed import result.
    /// - Parameters:
    ///   - path: The file path of the photo that failed to import.
    ///   - code: A machine-readable error code.
    ///   - message: A human-readable error description.
    static func error(path: String, code: String, message: String) -> SingleImportResult {
        SingleImportResult(
            path: path,
            status: "error",
            localIdentifier: nil,
            albumsRestored: [],
            favoriteRestored: false,
            reused: false,
            errorCode: code,
            errorMessage: message
        )
    }
}

/// Generates XML output strings for all importer command responses.
///
/// All output follows the same pattern: an XML document with a UTF-8 declaration
/// and pretty-printed formatting, suitable for parsing by the Lightroom plugin.
enum XMLOutput {

    // MARK: - Batch Import Results

    /// Generates XML for a batch import result containing per-photo outcomes.
    /// - Parameters:
    ///   - results: The individual import results for each photo in the batch.
    ///   - albumUuid: The User Library album UUID used to construct deep-link URLs, or `nil`.
    ///   - album: The album the batch was filed into and the folders leading to it, so the
    ///     plugin can record every identifier and notice which stale ones were recreated.
    /// - Returns: A complete XML document string.
    static func batchImportResult(
        results: [SingleImportResult], albumUuid: String?, album: ResolvedAlbum? = nil
    ) -> String {
        let root = XMLElement(name: "batchImportResult")
        root.addChild(XMLElement(name: "status", stringValue: "success"))

        if let album {
            root.addChild(element(for: album))
        }

        let resultsElement = XMLElement(name: "results")
        for result in results {
            resultsElement.addChild(element(for: result, albumUuid: albumUuid))
        }
        root.addChild(resultsElement)

        return xmlString(from: root)
    }

    /// Builds the `<result>` element for one photo in a batch.
    private static func element(for result: SingleImportResult, albumUuid: String?) -> XMLElement {
        let resultElement = XMLElement(name: "result")
        resultElement.setAttributesWith(["path": result.path])
        resultElement.addChild(XMLElement(name: "status", stringValue: result.status))

        guard result.status == "success" else {
            if let code = result.errorCode {
                resultElement.addChild(XMLElement(name: "errorCode", stringValue: code))
            }
            if let message = result.errorMessage {
                resultElement.addChild(XMLElement(name: "errorMessage", stringValue: message))
            }
            return resultElement
        }

        if let localId = result.localIdentifier {
            resultElement.addChild(XMLElement(name: "localIdentifier", stringValue: localId))
            let assetUuid = localId.uuidPrefix
            let url: String
            if let albumUuid {
                url = "photos:albums?albumUuid=\(albumUuid)&assetUuid=\(assetUuid)"
            } else {
                url = "photos://asset?assetLocalIdentifier=\(assetUuid)"
            }
            resultElement.addChild(XMLElement(name: "url", stringValue: url))
        }

        if result.favoriteRestored {
            resultElement.addChild(XMLElement(name: "favoriteRestored", stringValue: "true"))
        }

        if result.reused {
            resultElement.addChild(XMLElement(name: "reused", stringValue: "true"))
        }

        if !result.albumsRestored.isEmpty {
            let albumsElement = XMLElement(name: "albumsRestored")
            for album in result.albumsRestored {
                let albumElement = XMLElement(name: "album")
                albumElement.addChild(XMLElement(name: "identifier", stringValue: album.uuid))
                albumElement.addChild(XMLElement(name: "title", stringValue: album.title ?? ""))
                albumsElement.addChild(albumElement)
            }
            resultElement.addChild(albumsElement)
        }

        return resultElement
    }

    /// Generates XML for a fatal batch import error that prevented processing.
    /// - Parameters:
    ///   - code: A machine-readable error code (e.g. `"AUTH_ERROR"`).
    ///   - message: A human-readable error description.
    /// - Returns: A complete XML document string.
    static func batchImportError(code: String, message: String) -> String {
        let root = XMLElement(name: "batchImportResult")
        root.addChild(XMLElement(name: "status", stringValue: "error"))
        root.addChild(XMLElement(name: "errorCode", stringValue: code))
        root.addChild(XMLElement(name: "errorMessage", stringValue: message))
        return xmlString(from: root)
    }

    // MARK: - Delete Results

    /// Generates XML for a successful delete operation.
    /// - Parameter deletedCount: The number of assets that were deleted.
    /// - Returns: A complete XML document string.
    static func deleteSuccess(deletedCount: Int) -> String {
        let root = XMLElement(name: "deleteResult")
        root.addChild(XMLElement(name: "status", stringValue: "success"))
        root.addChild(XMLElement(name: "deletedCount", stringValue: String(deletedCount)))
        return xmlString(from: root)
    }

    /// Generates XML for a failed delete operation.
    /// - Parameters:
    ///   - code: A machine-readable error code (e.g. `"DELETE_FAILED"`).
    ///   - message: A human-readable error description.
    /// - Returns: A complete XML document string.
    static func deleteError(code: String, message: String) -> String {
        let root = XMLElement(name: "deleteResult")
        root.addChild(XMLElement(name: "status", stringValue: "error"))
        root.addChild(XMLElement(name: "errorCode", stringValue: code))
        root.addChild(XMLElement(name: "errorMessage", stringValue: message))
        return xmlString(from: root)
    }

    /// Builds the `<album>` block, including the folder chain in manifest order.
    private static func element(for resolved: ResolvedAlbum) -> XMLElement {
        let albumElement = XMLElement(name: "album")
        albumElement.addChild(
            XMLElement(name: "identifier", stringValue: resolved.album.identifier))
        albumElement.addChild(
            XMLElement(name: "created", stringValue: resolved.album.created ? "true" : "false"))

        if !resolved.folders.isEmpty {
            let foldersElement = XMLElement(name: "folders")
            for folder in resolved.folders {
                let folderElement = XMLElement(name: "folder")
                folderElement.addChild(
                    XMLElement(name: "identifier", stringValue: folder.identifier))
                folderElement.addChild(
                    XMLElement(name: "created", stringValue: folder.created ? "true" : "false"))
                foldersElement.addChild(folderElement)
            }
            albumElement.addChild(foldersElement)
        }

        return albumElement
    }

    // MARK: - Collection Results

    /// Generates XML for a successful album or folder operation.
    /// - Parameters:
    ///   - collection: The container the operation resolved, when it produced one.
    /// - Returns: A complete XML document string.
    static func collectionSuccess(collection: CollectionRef? = nil) -> String {
        let root = XMLElement(name: "collectionResult")
        root.addChild(XMLElement(name: "status", stringValue: "success"))
        if let collection {
            root.addChild(XMLElement(name: "identifier", stringValue: collection.identifier))
            root.addChild(
                XMLElement(name: "created", stringValue: collection.created ? "true" : "false"))
        }
        return xmlString(from: root)
    }

    /// Generates XML for a failed album or folder operation.
    static func collectionError(code: String, message: String) -> String {
        let root = XMLElement(name: "collectionResult")
        root.addChild(XMLElement(name: "status", stringValue: "error"))
        root.addChild(XMLElement(name: "errorCode", stringValue: code))
        root.addChild(XMLElement(name: "errorMessage", stringValue: message))
        return xmlString(from: root)
    }

    // MARK: - Helpers

    /// Wraps an XML element in a document with version and encoding declarations.
    /// - Parameter root: The root element for the XML document.
    /// - Returns: A pretty-printed XML string with a trailing newline.
    private static func xmlString(from root: XMLElement) -> String {
        let doc = XMLDocument(rootElement: root)
        doc.version = "1.0"
        doc.characterEncoding = "UTF-8"
        return doc.xmlString(options: [.nodePrettyPrint]) + "\n"
    }
}
