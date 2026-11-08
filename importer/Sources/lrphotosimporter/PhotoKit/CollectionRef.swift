import Foundation

/// A Photos album or folder the helper resolved for a Lightroom collection.
///
/// Stored identifiers go stale when the user deletes a container in Photos, switches
/// libraries or rebuilds one, so resolving may land on a different container than the
/// plugin asked for. ``created`` tells the plugin whether to record a new identifier
/// and log that it had to start over.
struct CollectionRef: Sendable, Equatable {
    /// The container's local identifier in the Photos library.
    let identifier: String

    /// Whether this container had to be created, as opposed to being found by
    /// identifier or adopted by name.
    let created: Bool
}

/// An album and the folder chain leading to it, as resolved for one publish.
///
/// The folders travel back to the plugin alongside the album because the plugin has to
/// record each one's identifier against its collection set. Without that, the next publish
/// arrives with no folder identifier and builds a second folder beside the first.
struct ResolvedAlbum: Sendable, Equatable {
    /// The album mirroring the published collection.
    let album: CollectionRef

    /// The folders mirroring the containing collection sets, outermost first.
    let folders: [CollectionRef]
}
