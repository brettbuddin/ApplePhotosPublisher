import ArgumentParser
import AppKit
import Foundation
import Photos

/// Command that opens a photo in the Apple Photos app by its local identifier.
///
/// Constructs a `photos:` URL using the asset's UUID and the User Library album UUID,
/// then opens it via `NSWorkspace`, causing Apple Photos to navigate to the photo.
struct OpenCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a photo in Apple Photos by identifier"
    )

    @Argument(help: "Local identifier of the photo to open")
    var identifier: String

    /// Fetches the User Library album, constructs a deep-link URL, and opens it in Apple Photos.
    mutating func run() {
        // Get the User Library smart album for the URL
        let albums = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumUserLibrary,
            options: nil
        )

        guard let album = albums.firstObject else { return }

        let assetUuid = identifier.uuidPrefix
        let albumUuid = album.localIdentifier.uuidPrefix

        // Construct and open the URL
        guard let url = URL(string: "photos:albums?albumUuid=\(albumUuid)&assetUuid=\(assetUuid)") else { return }

        NSWorkspace.shared.open(url)
    }
}
