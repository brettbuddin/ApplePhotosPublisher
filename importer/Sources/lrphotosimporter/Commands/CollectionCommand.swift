import ArgumentParser
import Foundation

/// Shared plumbing for the album and folder subcommands.
///
/// Each of these comes from a single action in Lightroom's Publish Services panel, so one
/// helper launch per operation is acceptable. Batch work belongs in the import manifest,
/// which carries its album with it to stay inside one launch.
enum CollectionRunner {

    /// Ensures write access, runs `body`, and prints its result as XML.
    ///
    /// Authorization failures and PhotoKit errors both reach the plugin as a `<collectionResult>`
    /// carrying the error code, which is how the plugin tells a cancelled dialog from a fault.
    static func run(
        _ body: (any PhotoLibrary) async throws -> CollectionRef?
    ) async -> String {
        let photoKit = PhotoKitAccessor()
        do {
            try await photoKit.ensureWriteAccess()
        } catch let error as PhotoKitError {
            return XMLOutput.collectionError(
                code: error.code, message: error.errorDescription ?? "Authorization failed")
        } catch {
            return XMLOutput.collectionError(code: "AUTH_ERROR", message: error.localizedDescription)
        }

        do {
            return XMLOutput.collectionSuccess(collection: try await body(photoKit))
        } catch let error as PhotoKitError {
            return XMLOutput.collectionError(
                code: error.code, message: error.errorDescription ?? "Operation failed")
        } catch {
            return XMLOutput.collectionError(
                code: "COLLECTION_FAILED", message: error.localizedDescription)
        }
    }
}

/// Manages the Photos album that mirrors a Lightroom published collection.
struct AlbumCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "album",
        abstract: "Manage the Photos album for a published collection",
        subcommands: [Ensure.self, Rename.self, Delete.self, Remove.self, Sync.self]
    )

    /// Resolves the album for a collection, creating it when the recorded identifier is
    /// missing or no longer points at anything.
    struct Ensure: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "ensure", abstract: "Find or create the album for a collection")

        @Option(name: .customLong("name"), help: "The collection's name, used as the album title")
        var name: String

        @Option(name: .customLong("identifier"), help: "Album identifier recorded by a previous publish")
        var identifier: String?

        @Option(name: .customLong("folder"), help: "Identifier of the folder to create the album in")
        var folder: String?

        mutating func run() async {
            let (name, identifier, folder) = (self.name, self.identifier, self.folder)
            print(await CollectionRunner.run { photoKit in
                try await photoKit.ensureAlbum(identifier: identifier, name: name, folder: folder)
            })
        }
    }

    struct Rename: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "rename", abstract: "Rename an album")

        @Option(name: .customLong("identifier"), help: "Album identifier")
        var identifier: String

        @Option(name: .customLong("name"), help: "New album title")
        var name: String

        mutating func run() async {
            let (name, identifier) = (self.name, self.identifier)
            print(await CollectionRunner.run { photoKit in
                try await photoKit.renameAlbum(identifier: identifier, to: name)
                return nil
            })
        }
    }

    /// Deletes the album and leaves its photos in the library.
    ///
    /// This raises the macOS confirmation dialog. A refusal comes back as `USER_CANCELLED`.
    struct Delete: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "delete", abstract: "Delete an album, keeping its photos")

        @Option(name: .customLong("identifier"), help: "Album identifier")
        var identifier: String

        mutating func run() async {
            let identifier = self.identifier
            print(await CollectionRunner.run { photoKit in
                try await photoKit.deleteAlbum(identifier: identifier)
                return nil
            })
        }
    }

    /// Takes photos out of an album without deleting them, which is silent.
    struct Remove: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "remove", abstract: "Remove photos from an album, keeping them in the library")

        @Option(name: .customLong("identifier"), help: "Album identifier")
        var identifier: String

        @Argument(help: "Local identifiers of the photos to remove")
        var assets: [String] = []

        mutating func run() async {
            let (identifier, assets) = (self.identifier, self.assets)
            print(await CollectionRunner.run { photoKit in
                try await photoKit.removeAssets(identifiers: assets, fromAlbum: identifier)
                return nil
            })
        }
    }

    /// Sets an album's membership to exactly the listed assets.
    ///
    /// This is the reconcile path. Lightroom only reports what changed, so an album created
    /// for a collection that already had published photos starts out missing all of them, and
    /// membership drifts whenever the album is edited in Photos.
    struct Sync: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "sync", abstract: "Set an album's photos to exactly the given set")

        @Option(name: .customLong("identifier"), help: "Album identifier")
        var identifier: String

        @Argument(help: "Local identifiers the album should contain")
        var assets: [String] = []

        mutating func run() async {
            let (identifier, assets) = (self.identifier, self.assets)
            print(await CollectionRunner.run { photoKit in
                let wanted = Set(assets.map(\.uuidPrefix))
                let present = await photoKit.assetIdentifiers(inAlbum: identifier)
                let presentPrefixes = Set(present.map(\.uuidPrefix))

                let surplus = present.filter { !wanted.contains($0.uuidPrefix) }
                if !surplus.isEmpty {
                    try await photoKit.removeAssets(identifiers: surplus, fromAlbum: identifier)
                }
                for asset in assets where !presentPrefixes.contains(asset.uuidPrefix) {
                    try await photoKit.addAsset(identifier: asset, toAlbum: identifier)
                }
                return nil
            })
        }
    }
}

/// Manages the Photos folder that mirrors a Lightroom published collection set.
struct FolderCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "folder",
        abstract: "Manage the Photos folder for a published collection set",
        subcommands: [Ensure.self, Rename.self, Delete.self, Move.self]
    )

    struct Ensure: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "ensure", abstract: "Find or create the folder for a collection set")

        @Option(name: .customLong("name"), help: "The collection set's name, used as the folder title")
        var name: String

        @Option(name: .customLong("identifier"), help: "Folder identifier recorded by a previous publish")
        var identifier: String?

        @Option(name: .customLong("parent"), help: "Identifier of the folder to nest inside")
        var parent: String?

        mutating func run() async {
            let (name, identifier, parent) = (self.name, self.identifier, self.parent)
            print(await CollectionRunner.run { photoKit in
                try await photoKit.ensureFolder(identifier: identifier, name: name, parent: parent)
            })
        }
    }

    struct Rename: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "rename", abstract: "Rename a folder")

        @Option(name: .customLong("identifier"), help: "Folder identifier")
        var identifier: String

        @Option(name: .customLong("name"), help: "New folder title")
        var name: String

        mutating func run() async {
            let (name, identifier) = (self.name, self.identifier)
            print(await CollectionRunner.run { photoKit in
                try await photoKit.renameFolder(identifier: identifier, to: name)
                return nil
            })
        }
    }

    /// Deletes the folder and every collection inside it, keeping all their photos.
    struct Delete: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "delete", abstract: "Delete a folder and its children, keeping all photos")

        @Option(name: .customLong("identifier"), help: "Folder identifier")
        var identifier: String

        mutating func run() async {
            let identifier = self.identifier
            print(await CollectionRunner.run { photoKit in
                try await photoKit.deleteFolder(identifier: identifier)
                return nil
            })
        }
    }

    /// Moves an album or folder to another folder, or to the top level.
    struct Move: AsyncParsableCommand {
        static var configuration = CommandConfiguration(
            commandName: "move", abstract: "Move an album or folder to a new parent")

        @Option(name: .customLong("identifier"), help: "Album or folder identifier to move")
        var identifier: String

        @Option(name: .customLong("folder"), help: "Destination folder, omitted for the top level")
        var folder: String?

        mutating func run() async {
            let (identifier, folder) = (self.identifier, self.folder)
            print(await CollectionRunner.run { photoKit in
                try await photoKit.move(identifier: identifier, toFolder: folder)
                return nil
            })
        }
    }
}
