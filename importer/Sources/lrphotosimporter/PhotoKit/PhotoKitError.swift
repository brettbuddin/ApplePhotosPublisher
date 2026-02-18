import Foundation

/// Errors from PhotoKit operations
enum PhotoKitError: Error, LocalizedError, Sendable {
    /// Read authorization not granted
    case readAuthorizationDenied

    /// Write authorization not granted
    case writeAuthorizationDenied

    /// Asset not found in library
    case assetNotFound(identifier: String)

    /// Album not found in library
    case albumNotFound(identifier: String)

    /// Import failed
    case importFailed(path: URL, reason: String)

    /// Delete failed
    case deleteFailed(identifiers: [String], reason: String)

    /// Add to album failed
    case addToAlbumFailed(assetID: String, albumID: String, reason: String)

    /// A human-readable description of the error, conforming to `LocalizedError`.
    var errorDescription: String? {
        switch self {
        case .readAuthorizationDenied:
            return "Photos library read access not authorized"
        case .writeAuthorizationDenied:
            return "Photos library write access not authorized"
        case .assetNotFound(let id):
            return "Asset not found: \(id)"
        case .albumNotFound(let id):
            return "Album not found: \(id)"
        case .importFailed(let path, let reason):
            return "Failed to import \(path.lastPathComponent): \(reason)"
        case .deleteFailed(let ids, let reason):
            return "Failed to delete \(ids.count) assets: \(reason)"
        case .addToAlbumFailed(let assetID, let albumID, let reason):
            return "Failed to add \(assetID) to album \(albumID): \(reason)"
        }
    }

    /// Error code for XML output
    var code: String {
        switch self {
        case .readAuthorizationDenied:
            return "READ_AUTH_DENIED"
        case .writeAuthorizationDenied:
            return "WRITE_AUTH_DENIED"
        case .assetNotFound:
            return "ASSET_NOT_FOUND"
        case .albumNotFound:
            return "ALBUM_NOT_FOUND"
        case .importFailed:
            return "IMPORT_FAILED"
        case .deleteFailed:
            return "DELETE_FAILED"
        case .addToAlbumFailed:
            return "ADD_TO_ALBUM_FAILED"
        }
    }
}
