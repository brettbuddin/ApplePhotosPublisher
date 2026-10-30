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
        }
    }
}
