# Output Formats Design

Let a published collection choose its output format, without publishing a copy of a photo for
every collection it is in.

## Goal

Every photo used to be published as a JPEG. This change lets an album publish JPEG XL or
TIFF instead.

The obvious way to do it is to give each collection its own render of each photo, which is
what treating Lightroom's per-collection identifier as the asset amounts to. A photo in five
albums is then five assets in Photos, five renders on every edit and five entries in every
Memories and search result. [Album sync](album-sync.md) had already moved away from that for
other reasons, and this change keeps to it: collections are clustered by format, and a photo
has one asset per cluster.

## Decisions

A photo has one asset in Photos for each format it is published in. Collections in the same
format share it. A photo in three JPEG albums and two TIFF albums is two assets, rendered
twice, not five and not one.

Collections in different formats never share. The file is the asset as far as Photos is
concerned, so a TIFF album showing a JPEG would simply be wrong.

The format is a setting on the collection, chosen when it is created or edited, and JPEG
when it has never been set. Existing collections therefore carry on exactly as they were.

Everything about the output apart from the format stays fixed: full size, sRGB and all
metadata embedded, with the settings below for each format. That is what makes the format a
sufficient key. If quality or bit depth were adjustable per collection, two JPEG
albums could want different files and the cluster would have to be keyed on every setting
that changes the bytes. See [Deferred](#deferred).

Changing a collection's format is supported, and publishing is what carries it out. The
photos published in the old format are flagged, and the next publish moves each one onto the
asset in the new format, rendering it only when no other collection already has it.

## One asset per photo per format

[One asset per photo](album-sync.md#one-asset-per-photo) recorded the asset on the photo as
`photosLocalIdentifier` and made Lightroom's per-collection `remoteId` a mirror of it. There
is now an identifier on the photo for each format, and every question that used to be asked
about "the photo's asset" is asked about its asset in one format.

| Format | Fixed settings | Recorded on the photo as |
| --- | --- | --- |
| JPEG | quality 100 | `photosLocalIdentifier` |
| JPEG XL | quality 100, not lossless, 16-bit | `photosLocalIdentifierJXL` |
| TIFF | 16-bit, ZIP | `photosLocalIdentifierTIFF` |

JPEG XL is full quality in the sense the JPEG is: the top of the lossy scale. Lightroom has a
separate lossless switch, which is left off. TIFF is the lossless choice, and a lossless
16-bit JPEG XL came out around seven times the size of the lossy one when a sample image was
encoded both ways with `cjxl`. The 16 bits cost the lossy file nothing measurable in the same
test, which is why it does not stop at Lightroom's default of 8.

JPEG XL needs Lightroom Classic 13 to render and macOS 14 for Photos to read. Neither is
enforced: on anything older the photos fail with whatever Lightroom or Photos reports.

The JPEG key is the one that already existed, so there is no migration: every asset published
before formats is a JPEG recorded where JPEGs are still looked for.

What follows, per format:

- Reuse. A photo whose asset in the collection's format is current keeps it. Adding a photo
  to a second TIFF album files the existing TIFF and renders nothing. Adding it to its first
  TIFF album renders one, however many JPEG albums it is in.
- Currency. An asset is current when a collection in its format has published it and none of
  them has it flagged for republish. An edit flags the photo in every collection, so those are
  the flags that speak for the asset. A TIFF album waiting to republish says nothing about the
  JPEG.
- Supersession. Publishing deletes what the plugin held for the photo in that format apart
  from the asset it now has. The other format's asset is not a leftover.
- Re-pointing. The other collections in the format are set to the new identifier and have
  their edited flag cleared. Collections in the other format keep theirs and stay flagged.
- Removal. An asset is deleted once no collection in its format still publishes the photo.
  Taking a photo out of its last TIFF album deletes the TIFF whatever JPEG albums it is in.
- Reconcile. An album is set to the assets its photos have in the collection's format.

An export through the service has no collection, so it is a JPEG and behaves as a JPEG
publish with no album.

### Which format a collection is holding

A collection's row names an asset without saying what it is. Its format is worked out from
the photo: whichever of the photo's assets the row names is the one it holds.

That matters in one case. A collection whose format was changed goes on naming the asset in
the old format until the photo is published again, and that asset is the one its album still
contains. So a row in a TIFF collection that names the photo's JPEG is holding a JPEG, and it
counts as a JPEG publisher: the JPEG is not deleted from under it when the last real JPEG
album lets go.

A row naming none of the photo's assets has either never been published or has drifted onto a
copy of its own. It says nothing either way and is taken to be in its collection's format,
which is what every such row was before formats existed.

## Rendering

A publish service has one set of output settings, and Lightroom renders every collection in
it with them. `updateExportSettings` is the only hook that can change them, and nothing the
SDK documents tells it which collection is being published.

So the service itself always renders JPEG, and a collection in another format has its photos
rendered separately:

1. Before rendering starts, every rendition in the publish is told to `skipRender`. That is
   the same call reuse already makes, and it has the same deadline.
2. The photos that are not being reused are rendered in an `LrExportSession` of the plugin's
   own, in one batch, with the format's settings and a temporary directory that the publish's
   function context removes when it ends.
3. The rendered files go into the import manifest in place of the ones Lightroom would have
   produced. Everything after that is the same path as a JPEG publish.

The alternative is to let Lightroom render the JPEG it was going to render anyway and then
render again in the wanted format. That costs two renders for every photo and throws the
first away, which is the price of not skipping.

A JPEG collection is untouched by any of this and is rendered by Lightroom as before.

One effect worth knowing: the plugin's own session does not run the publish service's
post-process actions, since it is a plain export to disk.

## Changing a collection's format

`viewForCollectionSettings` adds the format to the dialog for creating or editing a
collection. `updateCollectionSettings` runs when it is saved, and when a change to it is
undone.

Nothing in Photos changes at that point. Lightroom only offers a photo for publishing when it
is new or flagged as edited, and a changed setting makes it neither, so the plugin flags the
photos itself. Only rows naming an asset in a format other than the collection's new one are
flagged, which means saving the dialog without changing the format flags nothing.

The flagging runs in a task of its own and waits up to 30 seconds for the catalog. Lightroom
may still be inside the transaction that saved the settings, and a write without a timeout
fails immediately when the catalog is busy.

The next publish then treats each photo as it would any other in the new format, with two
additions for the asset the row was naming in the old one.

**It leaves this album, and is deleted if nothing else publishes it.** Moving off it is a
removal like any other and uses the same rule. An asset other collections still publish in
the old format is taken out of this collection's album with `album remove`, which is silent.
An asset nothing else publishes is deleted with the other leftovers, and the photo's
identifier for that format is forgotten once the deletion has succeeded.

**The new asset takes over from it, when it is about to be deleted.** The helper copies album
memberships and favorite status from the `previousIdentifier` in the manifest. Normally that
is the photo's asset in the same format. A photo being rendered in a format for the first
time has none, so the outgoing asset is offered instead, and an album the user filed it in by
hand still has the photo after the change. An outgoing asset that survives is not offered:
its albums include the ones still publishing it in the old format, and the new asset does
not belong in those.

A collection in the middle of a change keeps its flag when another collection replaces the
asset it is naming. It is re-pointed, so that it lets go of the right asset later, but it has
not published the photo in its own format yet and must not be marked up to date.

Reconcile leaves a change in progress alone. A row still naming the old format's asset keeps
that asset in the album when the photo has nothing in the new format yet, and the identifier
is not adopted as the photo's asset in the new one.

## A fix that came with it

Reuse skips the render on the strength of an identifier. When the asset turns out to have
been deleted in Photos the plugin forgets the identifier, so that the next publish renders.

It did not, though. The reuse decision read the identifier through `lastKnownAsset`, which
falls back to whatever a collection is holding, and the collection that originally published
the photo was still holding the deleted asset. Every publish after the first therefore
offered the same missing asset again and failed the same way.

Reuse now reads the identifier from the photo alone. The fallback stays where it is wanted,
in choosing the asset a new render takes over from.

A collection where a photo is still waiting for its first publish also no longer vouches for
an asset. It never held one, and whether Lightroom lists such a row is not documented, so the
answer no longer depends on it.

## Still open

None of this has been run in Lightroom. The Lua tests drive the real provider against
stand-ins, which settles what the plugin asks for and not how Lightroom answers.

1. Whether an `LrExportSession` started inside `processRenderedPhotos` behaves. It is
   documented and widely used from menu commands. A second progress bar may appear beside
   the publish's own while it renders.
2. Whether `updateCollectionSettings` is called with the write gate free. The task and the
   timeout are there in case it is not. If the flagging fails it is logged, and Lightroom's
   own Mark to Republish command does the same job by hand.
3. Whether Lightroom offers the edit dialog on the built-in `Apple Photos` collection. The
   code treats it like any other collection. If it does not, that collection stays JPEG.
4. Whether Photos is content with what Lightroom writes. ImageIO decodes a 16-bit ZIP TIFF
   written by ImageMagick with the same compression and predictor, and 16-bit JPEG XL files
   written by `cjxl`, lossy and lossless. That is as far as this was checked.
5. Whether Lightroom's JPEG XL at quality 100 without the lossless switch is what the
   settings table assumes. The keys are the ones its own export module reads
   (`jxl_quality`, `jxl_losslessQuality`, `export_bitDepth`), but no file has been rendered.

## Work breakdown

Plugin:

- `lib/Formats.lua` (new): the formats, their export settings, the metadata key each is
  recorded under and the collection setting.
- `lib/Renderer.lua` (new): the plugin's own export session for formats the service does not
  render.
- `lib/Assets.lua`: an identifier per format, and which format an identifier is.
- `lib/Albums.lua`: every per-photo question takes a format, plus the outgoing asset of a
  collection that changed, the asset a render takes over from and the flagging.
- `PhotosServiceProvider.lua`: the collection settings view and callback, the skipped render
  and separate batch, eviction and deletion of an outgoing asset, per-format removal.
- `PhotosMetadataDefinition.lua`: `photosLocalIdentifierJXL` and
  `photosLocalIdentifierTIFF`, and `schemaVersion` 2, which makes Lightroom offer to update
  the catalog.

The helper is unchanged. It imports whatever file it is given, and album removal already had
a command.

Adding a format takes an entry in `Formats.lua` and a metadata field for its identifier.

## Test plan

`lua tests/album-tests.lua` covers the per-format answers with stand-ins for the SDK objects:
which collections hold an asset, when it is current, what a publish supersedes and re-points,
what a changed collection lets go of and inherits from, the flagging and reconcile.

`lua tests/publish-tests.lua` runs the provider end to end against a simulated Photos library
and counts renders. Its main scenario takes one photo through two JPEG albums and two TIFF
albums: publish, join, edit, change formats both ways, remove and delete, asserting after
each step how many assets exist and what each album holds. It runs twice, once for each
answer to whether Lightroom lists a photo that is waiting for its first publish.

Manual scenarios against a real library:

- Publish a photo to a JPEG album, a JPEG XL album and a TIFF album, and confirm Photos has
  three assets of the right types and each album shows its own.
- Add the photo to a second TIFF album and confirm nothing is rendered or imported.
- Edit it, publish one TIFF album, and confirm both TIFF albums show the new version while
  the JPEG albums still wait.
- Change a JPEG album to TIFF and confirm its photos move to "Modified Photos to Re-Publish"
  without being touched. Publish and confirm the album holds TIFFs.
- Do that for the only album a favorited photo is in, and confirm the TIFF is a favorite and
  the JPEG is gone.
- Do it for an album whose photos another JPEG album also publishes, and confirm the JPEGs
  survive in the other album and are gone from this one.
- Remove a photo from its last TIFF album while it is still in a JPEG album, and confirm
  only the TIFF is deleted.
- Cancel a TIFF publish while it is rendering and confirm the photos stay waiting.

## Deferred

Options within a format, such as JPEG quality or TIFF bit depth per collection. The cluster
key would become the format plus every option that changes the file, and the identifier on
the photo would have to be recorded per key rather than per format.

More formats. Lightroom can also export PNG and AVIF. Each needs an entry, a metadata field
and a check that Photos imports what Lightroom writes.
