import Foundation

/// Errors from PhotoKit operations
enum PhotoKitError: Error, LocalizedError, Sendable {
    /// Read authorization not granted
    case readAuthorizationDenied

    /// Write authorization not granted (the user chose Don't Allow, or access was never granted)
    case writeAuthorizationDenied

    /// The user granted Limited Access rather than Full Access
    case writeAuthorizationLimited

    /// Photos access is restricted by Screen Time or a management profile
    case writeAuthorizationRestricted

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

    /// Folder not found in library
    case folderNotFound(identifier: String)

    /// Photos refused the edit this container does not support
    case operationNotPermitted(identifier: String, operation: String)

    /// The user dismissed the macOS confirmation dialog without allowing the change.
    ///
    /// PhotoKit reports this as `PHPhotosErrorUserCancelled`. Deleting an album or a folder
    /// always raises that dialog, so a refusal is an ordinary outcome rather than a fault,
    /// and it has to stay distinguishable from one.
    case userCancelled(operation: String)

    /// Creating an album or folder failed
    case createCollectionFailed(name: String, reason: String)

    /// Renaming an album or folder failed
    case renameCollectionFailed(identifier: String, name: String, reason: String)

    /// Deleting an album or folder failed
    case deleteCollectionFailed(identifier: String, reason: String)

    /// Moving an album or folder to another parent failed
    case moveCollectionFailed(identifier: String, reason: String)

    /// Removing assets from an album failed
    case removeFromAlbumFailed(albumID: String, reason: String)

    /// Launch Services gives the helper its own Photos permission in Settings.
    private static let fullAccessRemedy = "Open System Settings > Privacy & Security > Photos, "
        + "set Apple Photos Publisher for Lightroom Classic to Full Access, then retry publishing in Lightroom Classic."

    /// A human-readable description of the error, conforming to `LocalizedError`.
    var errorDescription: String? {
        switch self {
        case .readAuthorizationDenied:
            return "Photos library read access not authorized"
        case .writeAuthorizationDenied:
            return "Apple Photos Publisher for Lightroom Classic does not have Full Access to your Photos library. "
                + Self.fullAccessRemedy
        case .writeAuthorizationLimited:
            return "Apple Photos Publisher for Lightroom Classic has Limited Access to your Photos library, but "
                + "requires Full Access to replace published photos and preserve album memberships. " + Self.fullAccessRemedy
        case .writeAuthorizationRestricted:
            return "Access to the Photos library is restricted on this Mac, for example by "
                + "Screen Time or a management profile, so it cannot be granted to Apple Photos Publisher for Lightroom Classic."
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
        case .folderNotFound(let id):
            return "Folder not found: \(id)"
        case .operationNotPermitted(let id, let operation):
            return "Photos does not allow \(operation) on \(id)"
        case .userCancelled(let operation):
            return "You cancelled the Photos confirmation dialog, so \(operation) did not happen. "
                + "Nothing in your Photos library was changed."
        case .createCollectionFailed(let name, let reason):
            return "Failed to create \(name): \(reason)"
        case .renameCollectionFailed(let id, let name, let reason):
            return "Failed to rename \(id) to \(name): \(reason)"
        case .deleteCollectionFailed(let id, let reason):
            return "Failed to delete \(id): \(reason)"
        case .moveCollectionFailed(let id, let reason):
            return "Failed to move \(id): \(reason)"
        case .removeFromAlbumFailed(let albumID, let reason):
            return "Failed to remove assets from album \(albumID): \(reason)"
        }
    }

    /// Error code for XML output
    var code: String {
        switch self {
        case .readAuthorizationDenied:
            return "READ_AUTH_DENIED"
        case .writeAuthorizationDenied:
            return "WRITE_AUTH_DENIED"
        case .writeAuthorizationLimited:
            return "WRITE_AUTH_LIMITED"
        case .writeAuthorizationRestricted:
            return "WRITE_AUTH_RESTRICTED"
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
        case .folderNotFound:
            return "FOLDER_NOT_FOUND"
        case .operationNotPermitted:
            return "OPERATION_NOT_PERMITTED"
        case .userCancelled:
            return "USER_CANCELLED"
        case .createCollectionFailed:
            return "CREATE_COLLECTION_FAILED"
        case .renameCollectionFailed:
            return "RENAME_COLLECTION_FAILED"
        case .deleteCollectionFailed:
            return "DELETE_COLLECTION_FAILED"
        case .moveCollectionFailed:
            return "MOVE_COLLECTION_FAILED"
        case .removeFromAlbumFailed:
            return "REMOVE_FROM_ALBUM_FAILED"
        }
    }
}
