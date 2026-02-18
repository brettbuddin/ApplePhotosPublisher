import ArgumentParser
import AppKit
import Foundation
import Photos

struct OpenCommand: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a photo in Apple Photos by identifier"
    )

    @Argument(help: "Local identifier of the photo to open")
    var identifier: String

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
