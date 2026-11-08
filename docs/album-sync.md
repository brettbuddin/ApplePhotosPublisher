# Album Sync Design

Mirror published collections in the Apple Photos publish service as albums in Apple Photos.

## Goal

Today every published photo lands in the Photos library with no album of its own. Album
memberships are only ever *preserved* across a republish, never *created*. This change makes
the structure of the Publish Services panel visible in Photos: a published collection becomes
an album, a published collection set becomes a folder.

## Decisions

If there is a collection, it is published into Apple Photos. There are no special cases. The
built-in `Apple Photos` collection keeps its name and mirrors to an album exactly like any
collection the user adds.

Published collection sets mirror to folders, so the hierarchy carries over. A collection at
the top level of the service becomes a top-level album; a collection inside a set becomes an
album inside the matching folder.

Renames carry over at both levels: renaming a collection renames its album, renaming a set
renames its folder.

Deleting a collection deletes its album and never its assets.

Removing a photo from a collection takes the asset out of that collection's album, and deletes
the asset only when no other collection in the service still publishes the photo.

Custom sort order is out of scope. See [Deferred](#deferred).

### Existing albums start out behind

Lightroom only reports what changed, so the album for an existing collection is created on the
next publish and fills with the photos that publish touches. Everything published before the
upgrade stays absent from the album until it is republished. For an established catalog that
means the `Apple Photos` album looks badly incomplete at first.

A reconcile action that sets an album's membership to exactly its collection's published
assets is the fix, and this is why it belongs in the first pass rather than being deferred. It
doubles as the repair path for drift after the user edits an album in Photos.

## Mapping

| Lightroom | Apple Photos | Identifier stored as |
| --- | --- | --- |
| Published collection | User album (`PHAssetCollectionTypeAlbum` / `AlbumRegular`) | collection `remoteId` |
| Published collection set | Folder (`PHCollectionList`) | collection set `remoteId` |
| Published photo | Asset | photo `remoteId` plus `photosLocalIdentifier` |

Album and folder identifiers are PhotoKit `localIdentifier` values. They are recorded with
`exportSession:recordRemoteCollectionId` during publish and read back from
`publishedCollectionInfo.remoteId` and the `info.remoteId` of each lifecycle callback.

## Lightroom side

### Publish flow

`processRenderedPhotos` gains an album target. The work stays inside a single helper launch,
which matters because repeated rapid launches panic Lightroom's fork/exec machinery (see the
comment on `Importer.importPhotos`). The manifest carries the album, so the helper creates it,
imports the batch and sets membership in one invocation.

1. Read `exportContext.publishedCollectionInfo` for the collection name and its recorded
   `remoteId`. This applies to the default collection too.
2. Resolve the folder chain from `publishedCollectionInfo.parents`, outermost first. Each entry
   carries `remoteCollectionId`, which is the folder identifier when it was already published.
3. Build the manifest with the album block and the photo list.
4. On success, call `exportSession:recordRemoteCollectionId(album.identifier)` and
   `recordRemoteCollectionUrl('photos:albums?albumUuid=' .. uuid)`.

### Lifecycle callbacks to implement

| Callback | Action |
| --- | --- |
| `renamePublishedCollection` | Rename the album or folder. No-op when `info.remoteId` is nil. |
| `deletePublishedCollection` | Delete the album or folder, never its assets. |
| `reparentPublishedCollection` | Move the album or folder to the new parent, or to the top level. |
| `deletePhotosFromPublishedCollection` | Remove from the album, then delete newly orphaned assets. |
| `goToPublishedCollection` | Open `photos:albums?albumUuid=<uuid>`, confirmed to select the album. |
| `validatePublishedCollectionName` | Reject empty and whitespace-only names. |

Each of these throws a Lua error on failure, which makes Lightroom offer to revert the local
change. That is the behavior we want: a failed album rename should not leave the catalog
claiming a name Photos never accepted.

Supporting values:

- `getCollectionBehaviorInfo` keeps `defaultCollectionName = 'Apple Photos'`,
  `defaultCollectionCanBeDeleted = false` and `canAddCollection = true`, and drops
  `maxCollectionSetDepth` so collection sets are allowed and may nest freely. It is currently
  pinned to `0`, which disallows them.
- `titleForPublishedCollection = 'Album'` and `titleForPublishedCollectionSet = 'Folder'` make
  the context menus read "Create Album" and "Create Folder".
- `titleForGoToPublishedCollection = 'Show in Photos'`.

Whether Lightroom lets the user rename the built-in default collection is unconfirmed. Either
way the handler is uniform, so this only decides whether the `Apple Photos` album can ever
change name.

### Correctness fixes this feature requires

Album sync is about one photo living in several collections, which is exactly what breaks
today. Both bugs predate this work and both must be fixed for mirroring to be coherent.

**Stale sibling identifiers.** `PhotosServiceProvider.lua:229` falls back to the per-photo
`photosLocalIdentifier` when a rendition has no `publishedPhotoId`. Photo X published in
collection A becomes asset 1. Add X to collection B and publish: B sees no `publishedPhotoId`,
falls back to asset 1, imports asset 2, then deletes asset 1 at `PhotosServiceProvider.lua:249`.
Collection A now references a deleted asset, so removing X from A fails with `DELETE_FAILED`
and republishing X from A restores no memberships.

Fix: after a replace, walk the service's collections and call `publishedPhoto:setRemoteId(new)`
on every entry whose `getRemoteId()` matches the replaced identifier.

**Shared assets deleted by a single removal.** `deletePhotosFromPublishedCollection`
(`PhotosServiceProvider.lua:269`) deletes assets unconditionally and clears plugin metadata,
so removing X from B destroys the asset A still points at. The orphan rule fixes this: delete
only once nothing else publishes the photo.

A side effect worth having is that the macOS delete confirmation stops appearing for every
removal. It appears only when an asset is genuinely destroyed, so moving a photo between
albums becomes silent.

**Avoid the duplicate-asset churn.** A photo merely added to a second collection does not need
re-rendering. `publishedPhoto:getEditedFlag()` distinguishes "edited since last published" from
"new to this collection". When a photo already has a live asset and is not flagged as edited,
call `rendition:skipRender()`, reuse the existing identifier via
`rendition:recordPublishedPhotoId(existing)` and have the helper only add it to the album.

Both the sibling fix-up and the orphan check need to find every collection publishing a given
photo. Walk `publishService:getChildCollections()` plus `getChildCollectionSets()` recursively
and read `collection:getPublishedPhotos()`. Do not use
`photo:getContainedPublishedCollections()`: it explicitly omits smart published collections,
which would make orphan detection delete assets that a smart collection still publishes.

## Helper side

Every API needed is present in the macOS SDK and needs no new entitlement. Album membership
changes already happen today through `PhotoKitAccessor.addAsset` during membership restore,
which is evidence that adds do not raise a confirmation dialog.

### Protocol additions

Added to `PhotoLibrary` and `MockPhotoLibrary` alongside the existing methods:

```swift
func ensureAlbum(identifier: String?, name: String, folder: String?) async throws -> CollectionRef
func renameAlbum(identifier: String, to name: String) async throws
func deleteAlbum(identifier: String) async throws
func assetIdentifiers(inAlbum identifier: String) async -> [String]
func removeAssets(identifiers: [String], fromAlbum identifier: String) async throws

func ensureFolder(identifier: String?, name: String, parent: String?) async throws -> CollectionRef
func renameFolder(identifier: String, to name: String) async throws
func deleteFolder(identifier: String) async throws
func move(identifier: String, toFolder folder: String?) async throws
```

`CollectionRef` carries the identifier plus whether it was created or adopted, so the plugin
can log a recreate and record the new `remoteId`.

Backed by `creationRequestForAssetCollectionWithTitle:`,
`placeholderForCreatedAssetCollection`, `changeRequestForAssetCollection:` for `title`,
`addAssets:` and `removeAssets:`, `deleteAssetCollections:`, and the
`PHCollectionListChangeRequest` equivalents for folders. Gate each mutation on
`canPerformEditOperation:` and map a refusal to a distinct error code rather than a generic
failure.

A `PHCollection` has exactly one parent, and the probe confirmed that adding it to a new
parent moves it rather than duplicating it, so a move is a single `addChildCollections:`
with no explicit removal. Reaching the top level needs
`changeRequestForTopLevelCollectionListUserCollections:` (macOS 11+), whose Swift spelling is
`PHCollectionListChangeRequest(forTopLevelCollectionListUserCollections:)`.

`deleteCollectionLists:` is documented as deleting a folder *and all its child collections
recursively*. That matches Lightroom, where deleting a collection set takes its children with
it, and it still only removes containers rather than assets. It does mean
`deletePublishedCollection` for a set destroys the child albums in one call, so the child
collections' recorded identifiers are stale afterwards.

### Deleting a collection costs a dialog

Container deletion prompts, so the two deletions involved in removing a published collection
should land in one `performChanges` to raise one dialog instead of two. The Flickr sample
reads `info.photoIds` inside `deletePublishedCollection`, which would let a single helper
command delete the orphaned assets and the album together. The SDK reference does not document
that field, so confirm it before relying on it; the fallback is accepting two prompts.

It also means a declined deletion is a normal outcome rather than an edge case. The helper maps
`PHPhotosErrorUserCancelled` to its own code, say `DELETE_CANCELLED`, so the plugin can say
what happened instead of surfacing PhotoKit's unhelpful message.

The plugin should still throw a Lua error on a decline, because Lightroom's response to one is
exactly right here: it offers to revert the local change or keep it while warning that the
remote is untouched. That is a true description of a refused album deletion. What has to change
is the wording, which should name the cancelled Photos dialog rather than read as a crash.

For `deletePhotosFromPublishedCollection` a decline means not calling `deletedCallback` for
those photos, which leaves them parked in the "Delete Photos to Remove" group for a retry. The
existing authorization-failure path in `PhotosServiceProvider.lua` already works this way.

`PhotoKitAccessor.deleteAssets` currently throws `deleteFailed` from its
`guard assets.count > 0` when nothing matches. With shared assets and orphan checks in play,
an already-absent asset should count as success.

### Membership is idempotent, but check anyway

Restoring memberships from the previous asset and explicitly adding to the target album can
name the same album twice. The probe showed Photos ignores the second add rather than creating
a duplicate entry, so this is not a correctness problem. Reading `assetIdentifiers(inAlbum:)`
and skipping assets already present is still worth doing to keep the reconcile path honest
about what it changed.

### Manifest schema

```xml
<manifest>
  <album>
    <identifier>D1F4…/L0/040</identifier>
    <name>Family 2026</name>
    <folders>
      <folder><identifier>9B2C…/L0/050</identifier><name>Trips</name></folder>
    </folders>
  </album>
  <photos>
    <photo>
      <path>/var/folders/…/x.jpg</path>
      <previousIdentifier>A3E9…/L0/001</previousIdentifier>
    </photo>
    <photo>
      <path>/var/folders/…/y.jpg</path>
      <reuseIdentifier>B7D1…/L0/001</reuseIdentifier>
    </photo>
  </photos>
</manifest>
```

`<folders>` is ordered outermost first and is absent for a top-level collection. Any
identifier may be absent or stale. `<reuseIdentifier>` means the asset already exists and only
needs album membership.

### Result schema

`<batchImportResult>` gains an `<album>` block so the plugin can record the identifier and
notice a recreate:

```xml
<album>
  <identifier>D1F4…/L0/040</identifier>
  <created>true</created>
</album>
```

### One-shot commands

Rename, delete, reparent and album removal each come from a single UI action, so one launch
each is acceptable:

```
album  ensure --name <name> [--identifier <id>] [--folder <id>]
album  rename --identifier <id> --name <name>
album  delete --identifier <id>
album  remove --identifier <id> <assetId>...
album  sync   --manifest <path>
folder ensure --name <name> [--identifier <id>] [--parent <id>]
folder rename --identifier <id> --name <name>
folder delete --identifier <id>
move          --identifier <id> [--folder <id>]
```

`album sync` is the reconcile path: it sets membership to exactly the assets listed.

Removal needs at most two launches: `album remove` for the memberships, then the existing
`delete` for orphaned assets. Only the second prompts.

Partition the photos before acting rather than doing both to everything. An orphan needs only
its asset deleted, because deleting an asset removes it from every album anyway, and a
non-orphan needs only the membership removed, which is silent. Doing it that way means a
declined asset deletion cannot leave a photo already stripped from the album it is still
published in.

## Self-healing

Stored identifiers can go stale when the user deletes an album in Photos, switches libraries
or rebuilds one. `ensureAlbum` and `ensureFolder` therefore:

1. Fetch by identifier. Use it when found.
2. When the identifier is absent or dangling and a parent folder is given, adopt a child of
   that folder whose title matches exactly.
3. Otherwise create a new one.

Name adoption is scoped to the parent folder on purpose. Adopting by name at the top level
would silently absorb an unrelated album the user happens to have named "Family 2026". The
tradeoff is that a top-level album deleted in Photos comes back empty rather than
reconnecting, and refills over subsequent publishes or in one step via reconcile.

## Measured on macOS 27.3

`python3 tests/collection-probe.py` ran against a real library on macOS 27.3 (build
26C5035r). Every operation below was timed; the non-deleting ones all finished in under
130ms.

| Operation | Result |
| --- | --- |
| Create album | silent, 0.127s |
| Rename album | silent, 0.057s |
| Add asset to album | silent, 0.022s |
| Add the same asset again | silent, no duplicate created |
| Remove asset from album | silent, 0.010s |
| Create folder | silent, 0.010s |
| Move album into folder | silent, 0.014s |
| Move album to top level | silent, 0.014s |
| **Delete album** | **prompted** |
| **Delete folder** | **prompted** |

The two deleting operations took between 1.4 and 5.5 seconds across runs. That spread is how
long a human took to reach the dialog, not what the operation costs, so only the presence of
the dialog is meaningful.

Four findings change the design.

**Container deletion prompts.** `deleteAssetCollections:` and `deleteCollectionLists:` both
blocked for seconds while every other operation finished in milliseconds, including deleting
an album that was empty at the time. The decline run settles it beyond the timings: refusing
the dialog returned `PHPhotosErrorUserCancelled`, and a dialog that never appeared cannot be
refused. So deleting a collection or a collection set raises a macOS confirmation dialog,
which the README currently presents as something only photo deletion does. Two consequences
are in [Deleting a collection costs a dialog](#deleting-a-collection-costs-a-dialog).

**Albums reject duplicate adds.** Adding the same asset twice left the count at 1. The
membership check is therefore belt and braces rather than a correctness requirement.

**A plain add moves a collection.** Adding an album to the top-level list moved it out of its
folder with no explicit removal, so a move is one operation rather than two.

**A declined dialog is distinguishable.** Refusing the deletion throws
`PHPhotosErrorDomain` code 3072, `PHPhotosErrorUserCancelled`, and the album survives. Its
`localizedDescription` is the useless "The operation couldn't be completed.
(PHPhotosErrorDomain error 3072.)", so the helper has to recognize the code and supply its own
wording.

Both albums and folders reported every capability as available:
`addContent`, `removeContent`, `deleteContent`, `rearrangeContent`, `delete` and `rename`.

`photos:albums?albumUuid=<uuid>` with no `assetUuid` works. Photos came to the front with that
album selected, confirmed by eye because no API reports it back. So
`goToPublishedCollection` can drop the `assetUuid` that `OpenCommand` uses for a single photo.

### Still open

1. Whether Lightroom allows renaming the built-in default collection, which decides whether
   the `Apple Photos` album's name is fixed. Only Lightroom itself can answer this one.
2. Whether `info.photoIds` really is passed to `deletePublishedCollection`. The Flickr sample
   reads it, but the SDK reference does not document it. See below.

Both are Lightroom-side questions, so they resolve during implementation rather than needing
another probe.

## Work breakdown

Plugin:

- `PhotosServiceProvider.lua`: album target in the publish flow, the six lifecycle callbacks,
  the title and behavior values, orphan-aware removal, sibling identifier fix-up, skip-render
  reuse.
- `lib/Albums.lua` (new): collection and set to album and folder resolution, the recursive
  service walk for membership and orphan checks, reconcile.
- `lib/Importer.lua`: album block in the manifest, the new `album`, `folder` and `move`
  commands.
- `lib/XML.lua`: parse the `<album>` result block and the new command results.
- `PhotosMetadataDefinition.lua`: bump `schemaVersion` with a migration if new per-photo
  fields are added.
- `Info.lua`: reconcile menu item.

Helper:

- `PhotoKit/PhotoLibrary.swift`: protocol additions.
- `PhotoKit/PhotoKitAccessor.swift`: album and folder CRUD, membership reads, capability
  gates, already-absent assets treated as deleted.
- `PhotoKit/PhotoKitError.swift`: codes for a refused capability, a missing folder and a
  rename conflict.
- `Commands/ImportCommand.swift`: parse and honor the album block, honor `reuseIdentifier`.
- `Commands/AlbumCommand.swift` (new) and `Commands/FolderCommand.swift` (new).
- `Output/XMLOutput.swift`: the `<album>` block and the new result documents.
- `Tests/ImporterTests/`: extend `MockPhotoLibrary`, add album and folder suites.

Docs: the `README.md` usage section, and `DEVELOPMENT.md` for the probe.

## Test plan

Unit coverage follows the existing mock pattern: manifest parsing with and without folders,
ensure-album and ensure-folder across the found, dangling, adopted and created paths,
membership dedupe, reconcile adding and removing, deleting an already-absent asset treated as
success, orphan detection with a photo in one, two and zero collections, and capability
refusal mapped to its error code.

Manual scenarios against a real library:

- Publish a new collection and confirm the album appears with the right photos.
- Publish the built-in `Apple Photos` collection and confirm it gets an album like any other.
- Create a collection set, publish a collection inside it and confirm the folder hierarchy.
- Rename a collection and a set, and confirm Photos follows.
- Reparent a collection into and out of a set, and confirm the album moves.
- Delete a collection and confirm the album goes and the assets survive.
- Add a published photo to a second collection and confirm no re-import happens, the asset is
  shared and both collections still resolve.
- Remove the photo from one collection and confirm the asset stays with no dialog, then remove
  it from the last one and confirm it is deleted.
- Delete the album in Photos and republish to confirm the recreate path.
- Edit an album in Photos and run reconcile.
- Upgrade an established catalog and confirm reconcile backfills the existing album.

## Deferred

Custom sort order through `supportsCustomSortOrder` and `imposeSortOrderOnPublishedCollection`
backed by `moveAssetsAtIndexes:toIndex:`. The probe reported `rearrangeContent` as available on
both albums and folders, so the PhotoKit side is permitted; what remains unknown is whether
iCloud Photos preserves the ordering across devices.
