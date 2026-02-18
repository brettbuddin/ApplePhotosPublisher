import Foundation

/// Represents the result of importing a single photo in a batch
struct SingleImportResult {
    let path: String
    let status: String
    let localIdentifier: String?
    let albumsRestored: [AlbumMembership]
    let favoriteRestored: Bool
    let errorCode: String?
    let errorMessage: String?

    static func success(
        path: String,
        localIdentifier: String,
        albumsRestored: [AlbumMembership],
        favoriteRestored: Bool
    ) -> SingleImportResult {
        SingleImportResult(
            path: path,
            status: "success",
            localIdentifier: localIdentifier,
            albumsRestored: albumsRestored,
            favoriteRestored: favoriteRestored,
            errorCode: nil,
            errorMessage: nil
        )
    }

    static func error(path: String, code: String, message: String) -> SingleImportResult {
        SingleImportResult(
            path: path,
            status: "error",
            localIdentifier: nil,
            albumsRestored: [],
            favoriteRestored: false,
            errorCode: code,
            errorMessage: message
        )
    }
}

/// Generates XML output for importer responses
enum XMLOutput {

    // MARK: - Batch Import Results

    /// Generate XML for batch import results
    static func batchImportResult(results: [SingleImportResult], albumUuid: String?) -> String {
        let root = XMLElement(name: "batchImportResult")
        root.addChild(XMLElement(name: "status", stringValue: "success"))

        let resultsElement = XMLElement(name: "results")
        for result in results {
            let resultElement = XMLElement(name: "result")
            resultElement.setAttributesWith(["path": result.path])
            resultElement.addChild(XMLElement(name: "status", stringValue: result.status))

            if result.status == "success" {
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
            } else {
                if let code = result.errorCode {
                    resultElement.addChild(XMLElement(name: "errorCode", stringValue: code))
                }
                if let message = result.errorMessage {
                    resultElement.addChild(XMLElement(name: "errorMessage", stringValue: message))
                }
            }

            resultsElement.addChild(resultElement)
        }
        root.addChild(resultsElement)

        return xmlString(from: root)
    }

    /// Generate XML for batch import error (fatal error before processing)
    static func batchImportError(code: String, message: String) -> String {
        let root = XMLElement(name: "batchImportResult")
        root.addChild(XMLElement(name: "status", stringValue: "error"))
        root.addChild(XMLElement(name: "errorCode", stringValue: code))
        root.addChild(XMLElement(name: "errorMessage", stringValue: message))
        return xmlString(from: root)
    }

    // MARK: - Delete Results

    /// Generate XML for successful delete
    static func deleteSuccess(deletedCount: Int) -> String {
        let root = XMLElement(name: "deleteResult")
        root.addChild(XMLElement(name: "status", stringValue: "success"))
        root.addChild(XMLElement(name: "deletedCount", stringValue: String(deletedCount)))
        return xmlString(from: root)
    }

    /// Generate XML for delete error
    static func deleteError(code: String, message: String) -> String {
        let root = XMLElement(name: "deleteResult")
        root.addChild(XMLElement(name: "status", stringValue: "error"))
        root.addChild(XMLElement(name: "errorCode", stringValue: code))
        root.addChild(XMLElement(name: "errorMessage", stringValue: message))
        return xmlString(from: root)
    }

    // MARK: - Helpers

    private static func xmlString(from root: XMLElement) -> String {
        let doc = XMLDocument(rootElement: root)
        doc.version = "1.0"
        doc.characterEncoding = "UTF-8"
        return doc.xmlString(options: [.nodePrettyPrint]) + "\n"
    }
}
