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
