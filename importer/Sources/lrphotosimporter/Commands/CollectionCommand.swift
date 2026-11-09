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

/// Setting an album's contents to exactly what Lightroom says it should hold.
///
/// Apart from the command plumbing so it can be tested directly: this is the one operation
/// here that is partway through something after its first write, and what it does with a
/// photo Photos no longer has is the whole question.
enum AlbumSync {

    /// Removes what the album should not hold, then adds what it is missing.
    ///
    /// A photo Lightroom still claims but Photos no longer has is reported and skipped.
    /// Failing instead would abandon the rest of the album having already taken the surplus
    /// out, which leaves it further from what was asked for than when it started.
    static func apply(
        photoKit: any PhotoLibrary, identifier: String, assets: [String]
    ) async throws {
        let wanted = Set(assets.map(\.uuidPrefix))
        let present = await photoKit.assetIdentifiers(inAlbum: identifier)
        let presentPrefixes = Set(present.map(\.uuidPrefix))

        let surplus = present.filter { !wanted.contains($0.uuidPrefix) }
        if !surplus.isEmpty {
            try await photoKit.removeAssets(identifiers: surplus, fromAlbum: identifier)
        }

        for asset in assets where !presentPrefixes.contains(asset.uuidPrefix) {
            do {
                try await photoKit.addAsset(identifier: asset, toAlbum: identifier)
            } catch PhotoKitError.assetNotFound {
                let msg = "Warning: \(asset) is no longer in Photos\n"
                FileHandle.standardError.write(Data(msg.utf8))
            }
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

        mutating func run() async {
            let (name, identifier) = (self.name, self.identifier)
            print(await CollectionRunner.run { photoKit in
                try await photoKit.ensureAlbum(identifier: identifier, name: name)
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
                try await AlbumSync.apply(
                    photoKit: photoKit, identifier: identifier, assets: assets)
                return nil
            })
        }
    }
}
