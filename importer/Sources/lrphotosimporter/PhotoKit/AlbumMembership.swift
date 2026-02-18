import Foundation

/// Represents membership of a photo in an album
struct AlbumMembership: Sendable, Codable, Equatable, Hashable {
    /// Album's unique identifier in Photos library
    let uuid: String

    /// Album name (may be nil for untitled albums)
    let title: String?
}
