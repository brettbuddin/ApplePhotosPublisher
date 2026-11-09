import AppKit
import Foundation
import Photos

// Measures which PhotoKit collection operations raise a macOS confirmation dialog.
//
// Unlike the other fixtures in this directory, this one does access Photos. It runs
// under its own bundle identifier so TCC grants it an identity separate from the
// production helper, and it only ever mutates collections it created itself. The one
// existing asset it reads is added to and removed from the probe's own album, which
// never modifies the asset.
//
// Every operation is timed. An operation that blocks on a system dialog takes
// human-scale time; a silent one completes in milliseconds.
//
// Lines beginning with "@" are machine readable and consumed by collection-probe.py.
@main
enum CollectionProbe {

    // MARK: - Logging

    nonisolated(unsafe) static var logHandle: FileHandle?

    static func log(_ message: String) {
        let line = message + "\n"
        FileHandle.standardError.write(Data(line.utf8))
        logHandle?.write(Data(line.utf8))
    }

    static func fact(_ key: String, _ value: String) {
        log("@fact \(key)=\(value)")
    }

    /// Runs `body`, reporting how long it took.
    @discardableResult
    static func timed<T>(_ step: String, _ body: () async throws -> T) async -> T? {
        let start = Date()
        do {
            let value = try await body()
            log(String(format: "@step %@ status=ok seconds=%.3f", step, Date().timeIntervalSince(start)))
            return value
        } catch {
            log(String(format: "@step %@ status=failed seconds=%.3f error=%@",
                       step, Date().timeIntervalSince(start),
                       String(describing: error).replacingOccurrences(of: "\n", with: " ")))
            return nil
        }
    }

    // MARK: - Fetch helpers

    static func album(_ identifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    static func folder(_ identifier: String) -> PHCollectionList? {
        PHCollectionList.fetchCollectionLists(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    static func parentDescription(of collection: PHCollection) -> String {
        let lists = PHCollectionList.fetchCollectionListsContaining(collection, options: nil)
        guard let list = lists.firstObject else { return "top-level" }
        return list.localizedTitle ?? "untitled"
    }

    static func assetCount(in identifier: String) -> Int {
        guard let album = album(identifier) else { return -1 }
        return PHAsset.fetchAssets(in: album, options: nil).count
    }

    static func capabilities(of collection: PHCollection) -> String {
        let operations: [(String, PHCollectionEditOperation)] = [
            ("addContent", .addContent),
            ("removeContent", .removeContent),
            ("deleteContent", .deleteContent),
            ("rearrangeContent", .rearrangeContent),
            ("delete", .delete),
            ("rename", .rename),
        ]
        return operations
            .map { "\($0.0):\(collection.canPerform($0.1) ? "yes" : "no")" }
            .joined(separator: ",")
    }

    static func change(_ body: @escaping () -> Void) async throws {
        try await PHPhotoLibrary.shared().performChanges(body)
    }

    /// Names the `PHPhotosError` codes a collection change is plausibly rejected with, so a
    /// declined dialog can be told apart from a real failure.
    static func describeError(_ error: Error) -> String {
        let names: [Int: String] = [
            -1: "internalError",
            3072: "userCancelled",
            3300: "changeNotSupported",
            3301: "operationInterrupted",
            3310: "accessRestricted",
            3311: "accessUserDenied",
        ]
        let nsError = error as NSError
        let name = nsError.domain == PHPhotosErrorDomain
            ? (names[nsError.code] ?? "unmapped") : "non-photokit"
        return "domain=\(nsError.domain) code=\(nsError.code) name=\(name)"
    }

    static func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Decline probe

    /// Deletes an album the user is asked to refuse, to learn what a declined dialog looks
    /// like from the caller's side. Runs on its own because its instructions contradict the
    /// main flow's "allow everything".
    static func runDeclineProbe(stamp: Int) async {
        let title = "PhotoKit Probe Decline \(stamp)"
        var albumID: String?
        await timed("create-album") {
            var placeholder: PHObjectPlaceholder?
            try await change {
                placeholder = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: title)
                    .placeholderForCreatedAssetCollection
            }
            albumID = placeholder?.localIdentifier
        }
        guard let albumID, album(albumID) != nil else {
            log("STOP: album was not created")
            try? logHandle?.synchronize()
            exit(1)
        }
        fact("album-identifier", albumID)

        log("")
        log("====================================================")
        log("  DECLINE the next dialog. Cancel it, do not allow.")
        log("====================================================")
        log("")

        let start = Date()
        var thrown: Error?
        do {
            guard let album = album(albumID) else { return }
            try await change {
                PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
            }
        } catch {
            thrown = error
        }
        let seconds = Date().timeIntervalSince(start)

        log(String(format: "@step delete-album-declined status=%@ seconds=%.3f",
                   thrown == nil ? "ok" : "failed", seconds))
        fact("decline-threw", thrown == nil ? "false" : "true")
        if let thrown {
            fact("decline-error", describeError(thrown))
            fact("decline-error-message", (thrown as NSError).localizedDescription
                .replacingOccurrences(of: "\n", with: " "))
        }
        let survived = album(albumID) != nil
        fact("decline-album-survived", survived ? "true" : "false")

        if survived {
            log("")
            log("================================================")
            log("  Now ALLOW the next dialog so this cleans up.")
            log("================================================")
            log("")
            await timed("delete-album-cleanup") {
                guard let album = album(albumID) else { return }
                try await change {
                    PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
                }
            }
            fact("cleanup-album-deleted", album(albumID) == nil ? "true" : "false")
        } else {
            log("the decline deleted it anyway, nothing to clean up")
            fact("cleanup-album-deleted", "not-needed")
        }

        log("@done")
        try? logHandle?.synchronize()
        exit(0)
    }

    // MARK: - Cleanup

    /// Deletes every container the probe has ever left behind. A declined dialog leaves the
    /// album in place, so a run that was cancelled mid-flight needs sweeping up.
    ///
    /// Everything goes in one change block, so this asks once however much it finds.
    static func runCleanup() async {
        let prefix = "PhotoKit Probe"

        var albums: [PHAssetCollection] = []
        PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, _ in
                if collection.localizedTitle?.hasPrefix(prefix) == true { albums.append(collection) }
            }

        var folders: [PHCollectionList] = []
        PHCollectionList.fetchCollectionLists(with: .folder, subtype: .any, options: nil)
            .enumerateObjects { list, _, _ in
                if list.localizedTitle?.hasPrefix(prefix) == true { folders.append(list) }
            }

        for album in albums { log("  found album:  \(album.localizedTitle ?? "?")") }
        for folder in folders { log("  found folder: \(folder.localizedTitle ?? "?")") }
        fact("cleanup-albums-found", String(albums.count))
        fact("cleanup-folders-found", String(folders.count))

        if albums.isEmpty && folders.isEmpty {
            log("nothing left behind")
            fact("cleanup-complete", "true")
            log("@done")
            try? logHandle?.synchronize()
            exit(0)
        }

        log("")
        log("=============================================")
        log("  ALLOW the next dialog to remove these.")
        log("=============================================")
        log("")

        await timed("cleanup-delete") {
            try await change {
                if !albums.isEmpty {
                    PHAssetCollectionChangeRequest.deleteAssetCollections(albums as NSArray)
                }
                if !folders.isEmpty {
                    PHCollectionListChangeRequest.deleteCollectionLists(folders as NSArray)
                }
            }
        }

        let remaining = albums.filter { album($0.localIdentifier) != nil }.count
            + folders.filter { folder($0.localIdentifier) != nil }.count
        fact("cleanup-remaining", String(remaining))
        fact("cleanup-complete", remaining == 0 ? "true" : "false")
        log("@done")
        try? logHandle?.synchronize()
        exit(0)
    }

    // MARK: - Main

    static func main() async {
        var logPath: String?
        var openURL = false
        var declineMode = false
        var cleanupMode = false
        var dwellSeconds = 4.0
        var arguments = Array(CommandLine.arguments.dropFirst())
        while !arguments.isEmpty {
            switch arguments.removeFirst() {
            case "--log":
                logPath = arguments.isEmpty ? nil : arguments.removeFirst()
            case "--open-url":
                openURL = true
            case "--decline":
                declineMode = true
            case "--cleanup":
                cleanupMode = true
            case "--dwell":
                dwellSeconds = arguments.isEmpty ? dwellSeconds
                    : (Double(arguments.removeFirst()) ?? dwellSeconds)
            default:
                break
            }
        }

        if let logPath {
            FileManager.default.createFile(atPath: logPath, contents: nil)
            logHandle = FileHandle(forWritingAtPath: logPath)
        }

        log("PhotoKit collection probe")
        fact("bundle", Bundle.main.bundleIdentifier ?? "none")
        fact("macos", ProcessInfo.processInfo.operatingSystemVersionString)

        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            log("requesting access, a permission prompt is expected now")
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        fact("authorization", describe(status))
        guard status == .authorized else {
            log("STOP: needs Full Access. Grant it in System Settings > Privacy & Security > Photos.")
            try? logHandle?.synchronize()
            exit(1)
        }

        let stamp = Int(Date().timeIntervalSince1970)
        fact("mode", cleanupMode ? "cleanup" : (declineMode ? "decline" : "full"))
        if cleanupMode {
            await runCleanup()
            return
        }
        if declineMode {
            await runDeclineProbe(stamp: stamp)
            return
        }

        let albumTitle = "PhotoKit Probe Album \(stamp)"
        let folderTitle = "PhotoKit Probe Folder \(stamp)"

        // Create an album.
        var albumID: String?
        await timed("create-album") {
            var placeholder: PHObjectPlaceholder?
            try await change {
                placeholder = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: albumTitle)
                    .placeholderForCreatedAssetCollection
            }
            albumID = placeholder?.localIdentifier
        }
        guard let albumID, let newAlbum = album(albumID) else {
            log("STOP: album was not created")
            try? logHandle?.synchronize()
            exit(1)
        }
        fact("album-identifier", albumID)
        fact("album-capabilities", capabilities(of: newAlbum))

        // Rename it.
        await timed("rename-album") {
            guard let album = album(albumID) else { return }
            try await change {
                PHAssetCollectionChangeRequest(for: album)?.title = albumTitle + " renamed"
            }
        }
        fact("album-renamed", album(albumID)?.localizedTitle == albumTitle + " renamed" ? "true" : "false")

        // Membership, including adding the same asset twice.
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        if let asset = PHAsset.fetchAssets(with: .image, options: options).firstObject {
            await timed("add-asset") {
                guard let album = album(albumID) else { return }
                try await change {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
                }
            }
            let afterFirst = assetCount(in: albumID)
            await timed("add-asset-again") {
                guard let album = album(albumID) else { return }
                try await change {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([asset] as NSArray)
                }
            }
            let afterSecond = assetCount(in: albumID)
            fact("album-count-after-one-add", String(afterFirst))
            fact("album-count-after-duplicate-add", String(afterSecond))
            fact("duplicate-adds-tolerated", afterSecond > afterFirst ? "true" : "false")
            await timed("remove-asset") {
                guard let album = album(albumID) else { return }
                try await change {
                    PHAssetCollectionChangeRequest(for: album)?.removeAssets([asset] as NSArray)
                }
            }
            fact("album-count-after-remove", String(assetCount(in: albumID)))
        } else {
            fact("duplicate-adds-tolerated", "skipped-no-assets")
        }

        // Create a folder and move the album into it.
        var folderID: String?
        await timed("create-folder") {
            var placeholder: PHObjectPlaceholder?
            try await change {
                placeholder = PHCollectionListChangeRequest
                    .creationRequestForCollectionList(withTitle: folderTitle)
                    .placeholderForCreatedCollectionList
            }
            folderID = placeholder?.localIdentifier
        }
        if let folderID, let newFolder = folder(folderID) {
            fact("folder-identifier", folderID)
            fact("folder-capabilities", capabilities(of: newFolder))

            await timed("move-album-into-folder") {
                guard let folder = folder(folderID), let album = album(albumID) else { return }
                try await change {
                    PHCollectionListChangeRequest(for: folder)?.addChildCollections([album] as NSArray)
                }
            }
            if let album = album(albumID) {
                fact("album-parent-in-folder", parentDescription(of: album))
            }

            // Move it back to the top level. A PHCollection has exactly one parent, so
            // adding it to the root list should be enough to move it.
            await timed("move-album-to-top-level") {
                guard let album = album(albumID) else { return }
                let topLevel = PHCollection.fetchTopLevelUserCollections(with: nil)
                try await change {
                    PHCollectionListChangeRequest(
                        forTopLevelCollectionListUserCollections: topLevel
                    )?.addChildCollections([album] as NSArray)
                }
            }
            if let album = album(albumID) {
                fact("album-parent-after-move", parentDescription(of: album))
            }
        }

        // Open the album by URL.
        if openURL, let album = album(albumID) {
            let uuid = album.localIdentifier.components(separatedBy: "/").first ?? album.localIdentifier
            let string = "photos:albums?albumUuid=\(uuid)"
            let opened = URL(string: string).map { NSWorkspace.shared.open($0) } ?? false
            fact("open-url", string)
            fact("open-url-accepted", opened ? "true" : "false")
            log("Look at Photos now. Does it show the album named:")
            log("  \(album.localizedTitle ?? "?")")
            log(String(format: "Holding for %.0fs before deleting it.", dwellSeconds))
            try? await Task.sleep(nanoseconds: UInt64(dwellSeconds * 1_000_000_000))
        }

        // Delete the album. This is the measurement the probe exists for.
        await timed("delete-album") {
            guard let album = album(albumID) else { return }
            try await change {
                PHAssetCollectionChangeRequest.deleteAssetCollections([album] as NSArray)
            }
        }
        fact("album-deleted", album(albumID) == nil ? "true" : "false")

        if let folderID {
            await timed("delete-folder") {
                guard let folder = folder(folderID) else { return }
                try await change {
                    PHCollectionListChangeRequest.deleteCollectionLists([folder] as NSArray)
                }
            }
            fact("folder-deleted", folder(folderID) == nil ? "true" : "false")
        }

        log("@done")
        try? logHandle?.synchronize()
        exit(0)
    }
}
