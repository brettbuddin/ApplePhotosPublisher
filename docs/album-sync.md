# Album Sync Design

Mirror published collections in the Apple Photos publish service as albums in Apple Photos.

## Goal

Today every published photo lands in the Photos library with no album of its own. Album
memberships are only ever *preserved* across a republish, never *created*. This change makes
the structure of the Publish Services panel visible in Photos: a published collection becomes
an album.

## Decisions

Collections the user adds mirror to albums. The built-in `Apple Photos` collection does not:
publishing there means getting a photo into the Photos library without filing it anywhere, so
it has no album of its own. It keeps its name in the panel, which Lightroom will not let the
user change anyway.

Collection sets are not offered, so albums all sit at the top level of Photos. They would
mirror to folders, but deleting a folder in Photos is recursive: it takes every album inside
with it, including one the user had dragged in that belongs to a collection still being
published. That is silent and unrecoverable, so the hierarchy is left out until it can be
made safe. `maxCollectionSetDepth = 0` turns sets off.

Renaming a collection renames its album.

Removing a photo from a collection takes the asset out of that collection's album, and deletes
the asset only when no collection in the plugin still publishes the photo. The two cases that
follow are the point of the split: a photo in only `Family`, removed from it, is orphaned and
deleted; the same photo also in `Apple Photos` survives and becomes an unfiled library photo,
because the default collection still publishes it and has no album to remove it from.

Deleting a collection is the same rule applied to everything in it: the album goes, and so do
the assets nothing else publishes. The album goes first, because deleting a container is the
one thing here that raises a confirmation dialog, and a refusal that arrives after the photos
have been deleted cannot be answered by the revert Lightroom then offers.

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
| Default collection | nothing; the photo is in the library, unfiled | n/a |
| Photo | Asset | `photosLocalIdentifier` on the photo |
| Published photo | the same asset | published photo `remoteId`, kept in step |

Album and folder identifiers are PhotoKit `localIdentifier` values. They are recorded with
`exportSession:recordRemoteCollectionId` during publish and read back from
`publishedCollectionInfo.remoteId` and the `info.remoteId` of each lifecycle callback.

## One asset per photo

A photo has one asset in Photos, recorded on the photo as `photosLocalIdentifier`. Lightroom
also keeps a `remoteId` per published photo per collection, which cannot be avoided: the
panel's menus and `deletePhotosFromPublishedCollection` are built on it. Those are mirrors.
Anything that decides what happens to an asset reads the photo.

Treating the per-collection `remoteId` as the truth is what let two collections disagree.
Publishing replaced the asset and pointed only the collection being published at the
replacement, so a photo published by two collections ended up with two assets, each collection
sure it held the right one. Nothing could see the disagreement either, because the repair
walked the service looking for collections naming *the identifier being replaced*, and a
collection that had already drifted onto its own copy did not name it.

What follows from keying on the photo instead:

- Reuse. A photo whose asset no collection has flagged for republish keeps that asset:
  `rendition:skipRender()`, no import, and the helper only files it into the album. Publishing
  a service where one photo is pending in two collections therefore imports once and files
  twice, where it used to import twice and delete the first copy.
- Supersession. A publish deletes every asset the plugin held for the photo apart from the one
  it now has, taken from both the photo and its collections. A collection that had drifted onto
  its own copy loses it here.
- Re-pointing. Every other collection publishing the photo is set to the new identifier and has
  its edited flag cleared, in one transaction for the whole batch, before the assets they were
  holding are deleted.
- Removal. Whether an asset may be deleted is a question about its photo: delete only once no
  collection in the plugin still publishes it. Lightroom names assets rather than photos in
  that callback, so each identifier is resolved back to its photo first.
- Scope. The index spans every service of the plugin, not just the one being published. The
  identifier lives on the photo, and the helper only ever works on the system photo library, so
  two services really are two views of the same place.

An asset two photos publish is never deleted, which is what keeps a virtual copy from taking
its master's asset with it.

### The one case that needs two publishes

Reuse skips the render on the strength of an identifier. If that asset was deleted in Photos in
the meantime, there is no file to fall back to, so the helper reports `REUSE_MISSING`, the photo
fails, and the plugin forgets the identifier. The next publish renders and imports it. This is
reachable by deleting a photo in Photos and then adding it to another collection in Lightroom.

## Lightroom side

### Publish flow

`processRenderedPhotos` gains an album target. The work stays inside a single helper launch,
which matters because repeated rapid launches panic Lightroom's fork/exec machinery (see the
comment on `Importer.importPhotos`). The manifest carries the album, so the helper creates it,
imports the batch and sets membership in one invocation.

1. Index every published photo in the plugin, once, keyed by photo.
2. Walk the renditions before rendering starts and skip the render for every photo whose asset
   is already current. `skipRender` is only honored until the first render begins, which is why
   this is a pass of its own.
3. Read `exportContext.publishedCollectionInfo` for the collection name and its recorded
   `remoteId`. The default collection gets no album block.
4. Build the manifest with the album block and the photo list.
5. On success, call `exportSession:recordRemoteCollectionId(album.identifier)` and
   `recordRemoteCollectionUrl('photos:albums?albumUuid=' .. uuid)`.
6. Write the catalog: the asset onto each photo, the new identifier out to the other
   collections, then delete the superseded assets. One transaction each, and none of them able
   to abort the publish, because stopping before the deletes leaves duplicates in Photos with
   nothing left to remember them by.

### Lifecycle callbacks to implement

| Callback | Action |
| --- | --- |
| `renamePublishedCollection` | Rename the album. No-op when `info.remoteId` is nil. |
| `deletePublishedCollection` | Delete the album, then the assets nothing else publishes. |
| `deletePhotosFromPublishedCollection` | Remove from the album, or delete the assets of a photo nothing else publishes. |
| `goToPublishedCollection` | Open `photos:albums?albumUuid=<uuid>`, confirmed to select the album. |
| `validatePublishedCollectionName` | Reject empty and whitespace-only names. |

Each of these throws a Lua error on failure, which makes Lightroom offer to revert the local
change. That is the behavior we want: a failed album rename should not leave the catalog
claiming a name Photos never accepted.

Supporting values:

- `getCollectionBehaviorInfo` keeps `defaultCollectionName = 'Apple Photos'`,
  `defaultCollectionCanBeDeleted = false`, `canAddCollection = true` and
  `maxCollectionSetDepth = 0`.
- `titleForPublishedCollection = 'Album'` makes the context menus read "Create Album".
- `titleForGoToPublishedCollection = 'Show in Photos'`.

Lightroom does not allow renaming the built-in default collection, confirmed in the panel.
That is its own policy rather than anything the plugin asks for: `defaultCollectionCanBeDeleted`
is the only knob we set, and we leave `disableRenamePublishedCollection` alone. It no longer
matters for the mirror, since the default collection has no album to name, but it does mean the
panel entry stays `Apple Photos` permanently.

Every lifecycle callback that implies an album checks `isDefaultCollection` first. A `remoteId`
can survive on that collection from before it stopped mirroring, and acting on it would move or
rename an album nothing manages any more.

### Correctness fixes this feature requires

Album sync is about one photo living in several collections, which is exactly what breaks
today. Both bugs predate this work and both must be fixed for mirroring to be coherent.

**Stale sibling identifiers.** Photo X published in collection A becomes asset 1. Add X to
collection B and publish: B imports asset 2, then deletes asset 1. Collection A now references
a deleted asset, so removing X from A fails with `DELETE_FAILED` and republishing X from A
restores no memberships.

Fixed by [One asset per photo](#one-asset-per-photo). The first attempt matched collections
against the identifier being replaced, which repaired this case but not the one that followed
from it: once a collection had drifted onto its own copy, it no longer named the identifier
anybody was replacing, so it stayed invisible to every publish. Observed live, with one photo
held as two assets by two collections.

**Shared assets deleted by a single removal.** `deletePhotosFromPublishedCollection`
(`PhotosServiceProvider.lua:269`) deletes assets unconditionally and clears plugin metadata,
so removing X from B destroys the asset A still points at. The orphan rule fixes this: delete
only once nothing else publishes the photo.

A side effect worth having is that the macOS delete confirmation stops appearing for every
removal. It appears only when an asset is genuinely destroyed, so moving a photo between
albums becomes silent.

**Avoid the duplicate-asset churn.** A photo merely added to a second collection does not need
re-rendering. `publishedPhoto:getEditedFlag()` is what reports whether its asset is still
current, so reuse asks every collection publishing the photo rather than only this one, and a
collection has to be publishing it already for anything to vouch for the asset. A photo whose
only claim is the identifier on itself gets a fresh asset, since nothing says that identifier
predates the last edit.

Everything above needs to find every collection publishing a given photo, so one pass over
`publishService:getChildCollections()` and `collection:getPublishedPhotos()` builds an index
keyed by photo, which the whole operation then shares. The per-photo walk it replaced cost a
full pass over every published photo in the plugin for each photo in the batch. Do not use
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

### Lightroom places an album once, then leaves it alone

Albums are created at the top level of Photos. After that the placement is the user's:
resolving an album by its recorded identifier returns it as it is and never corrects its
parent, so moving it into a folder in Photos sticks.

Moving a collection in Photos does not change its `localIdentifier`, which is what the plugin
records, so the linkage survives. The probe confirmed this rather than assuming it: it moved
an album into a folder and back out, re-fetching it by the same identifier each time.

### Album titles drift one way

`ensureAlbum` finds an album by its recorded identifier and uses it as it is, without checking
that its title still matches the collection. So a rename in Lightroom reaches Photos, but a
rename in Photos is never corrected, and for the default collection there is no Lightroom-side
rename available at all.

Enforcing the title on every publish would make Lightroom authoritative and is cheap, since
renames are silent. The cost is overriding a rename the user made in Photos deliberately.

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
folder move   --identifier <id> [--folder <id>]
```

`folder move` takes an album as readily as a folder, since reparenting is the same operation
either way.

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
or rebuilds one. `ensureAlbum` therefore fetches by identifier, uses it when found, and
otherwise creates a new album.

Nothing is adopted by name. Albums all sit at the top level now that collection sets are gone,
and matching by name there would silently absorb an unrelated album the user happens to have
called "Family 2026". The tradeoff is that an album deleted in Photos comes back empty rather
than reconnecting, and refills over subsequent publishes or in one step via reconcile.

Reconcile is the repair for identifiers as well as membership: it sets the album to the assets
its photos have, points any collection that drifted at the asset its photo holds, and adopts a
`remoteId` onto a photo that has none, which is the state a catalog published before
`photosLocalIdentifier` existed would be in.

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

1. Whether `info.photoIds` really is passed to `deletePublishedCollection`. The Flickr sample
   reads it, but the SDK reference does not document it, and it decides whether deleting a
   collection costs one confirmation dialog or two. The implementation copes either way.

### Settled in the panel

The built-in default collection cannot be renamed. Lightroom enforces that itself, so the
`Apple Photos` album keeps its name unless it is renamed in Photos, which nothing in
Lightroom will ever undo. See
[Album titles drift one way](#album-titles-drift-one-way).

## Work breakdown

Plugin:

- `PhotosServiceProvider.lua`: album target in the publish flow, the lifecycle callbacks, the
  title and behavior values, reuse decided before rendering, orphan-aware removal, and the
  catalog writes batched into one transaction each.
- `lib/Assets.lua` (new): the asset a photo has, read and written through the private gate.
- `lib/Albums.lua` (new): collection to album resolution, the index of every published photo
  keyed by photo, supersession and re-pointing, reconcile.
- `lib/Importer.lua`: album block in the manifest, the `album` commands, `REUSE_MISSING`.
- `lib/XML.lua`: parse the `<album>` result block and the new command results.
- `Info.lua`: reconcile menu item.

Helper:

- `PhotoKit/PhotoLibrary.swift`: protocol additions.
- `PhotoKit/PhotoKitAccessor+Collections.swift` (new): album CRUD, membership reads,
  capability gates, title enforcement.
- `PhotoKit/PhotoKitError.swift`: codes for a refused capability, a missing album and a
  refused confirmation dialog.
- `Commands/ImportCommand.swift`: parse and honor the album block, honor `reuseIdentifier`.
- `Commands/CollectionCommand.swift` (new): `album ensure|rename|delete|remove|sync`.
- `Output/XMLOutput.swift`: the `<album>` block and the new result documents.
- `Tests/ImporterTests/`: extend `MockPhotoLibrary`, add the album suites.

Docs: the `README.md` usage section, and `DEVELOPMENT.md` for the probe and the test files.

## Test plan

`lua tests/album-tests.lua` covers the mapping with stand-ins for the SDK objects: the index,
whether an asset is current, stale collections, supersession including an asset two photos
publish, re-pointing in one ordinary transaction, the private write that only happens when
the identifier changed, and reconcile following the photos rather than the collection.

Helper coverage follows the existing mock pattern: manifest parsing with and without an album,
ensure-album across the found, dangling and created paths, membership dedupe, reconcile adding
and removing, deleting an already-absent asset treated as success, reuse with and without a
rendered file to fall back to, and capability refusal mapped to its error code.

Manual scenarios against a real library:

- Publish a new collection and confirm the album appears with the right photos.
- Publish the built-in `Apple Photos` collection and confirm no album is created.
- Rename a collection and confirm Photos follows.
- Delete a collection and confirm the album goes and the assets survive, and that refusing the
  confirmation dialog leaves both alone.
- Add a published photo to a second collection and confirm no re-import happens, the asset is
  shared and both collections still resolve.
- Edit a photo published by two collections, publish one of them, and confirm one asset
  survives, both collections name it and neither is left asking to republish.
- Remove the photo from one collection and confirm the asset stays with no dialog, then remove
  it from the last one and confirm it is deleted.
- Delete the asset in Photos, add the photo to another collection, and confirm the publish
  fails with a message rather than an empty import, then succeeds on a second publish.
- Delete the album in Photos and republish to confirm the recreate path.
- Edit an album in Photos and run reconcile.
- Upgrade an established catalog and confirm reconcile backfills the existing album.

## Deferred

Collection sets as Photos folders. The implementation existed and worked; it was removed in
favor of a simpler model, and the commit before its removal still has it. Bringing it back
means solving the recursive folder delete first: relocate a folder's unrecognized children to
the top level before deleting it, so only the albums Lightroom owns go with it.

Custom sort order through `supportsCustomSortOrder` and `imposeSortOrderOnPublishedCollection`
backed by `moveAssetsAtIndexes:toIndex:`. The probe reported `rearrangeContent` as available on
albums, so the PhotoKit side is permitted; what remains unknown is whether iCloud Photos
preserves the ordering across devices.
