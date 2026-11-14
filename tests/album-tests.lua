-- Run from the repository root. No Lightroom or Photos access is required.
--
-- Covers the mapping between Lightroom's published photos and Apple Photos assets: which
-- collections publish a photo, which asset that photo has, which assets are left over, and
-- what reconciling an album sets it to. These are the answers that used to be derived from
-- one collection's identifier at a time, which is what let two collections drift onto two
-- copies of the same photo.
--
-- Also covers output formats: a photo has one asset per format, shared by every collection in
-- that format, so each of those answers is given one format at a time.

local loaded = {}
local logged = {}
local stubs = {
    ['lib/Logger'] = {
        info = function(_, message) table.insert(logged, message) end,
        error = function(_, message) table.insert(logged, message) end,
    },
    ['lib/Time'] = { nowISO8601 = function() return '2026-11-08T12:00:00Z' end },
}
package.loaded.PluginModuleLoader = function(name)
    return assert(stubs[name] or loaded[name], name)
end

_PLUGIN = { id = 'org.buddin.lrphotossync' }

local importerCalls = {}
stubs['lib/Importer'] = {
    STATUS_SUCCESS = 'success',
    ensureAlbum = function(name, identifier)
        table.insert(importerCalls, { command = 'ensure', name = name, identifier = identifier })
        return { status = 'success', identifier = 'new-album/L0/040' }
    end,
    syncAlbum = function(identifier, identifiers)
        table.insert(importerCalls, { command = 'sync', identifier = identifier, assets = identifiers })
        return { status = 'success' }
    end,
    deletePhotos = function(identifiers)
        table.insert(importerCalls, { command = 'delete', assets = identifiers })
        return { status = 'success', deletedCount = #identifiers }
    end,
}

--- The last call the helper stub saw for a command, or nil.
local function called(command)
    for i = #importerCalls, 1, -1 do
        if importerCalls[i].command == command then
            return importerCalls[i]
        end
    end
    return nil
end

local Formats = dofile('ApplePhotosPublisher.lrplugin/lib/Formats.lua')
loaded['lib/Formats'] = Formats
local Assets = dofile('ApplePhotosPublisher.lrplugin/lib/Assets.lua')
loaded['lib/Assets'] = Assets
local Albums = dofile('ApplePhotosPublisher.lrplugin/lib/Albums.lua')

-- Stand-ins for the SDK objects, duck-typed to the calls these modules make.

local nextPhotoId = 0
local function newPhoto(identifier, tiffIdentifier)
    nextPhotoId = nextPhotoId + 1
    local photo = { localIdentifier = nextPhotoId, properties = {} }
    function photo:getPropertyForPlugin(_, key) return self.properties[key] end
    function photo:setPropertyForPlugin(_, key, value) self.properties[key] = value end
    photo.properties[Formats.property('JPEG')] = identifier
    photo.properties[Formats.property('TIFF')] = tiffIdentifier
    return photo
end

local function newPublishedPhoto(photo, remoteId, edited)
    local published = { remoteId = remoteId, url = nil, edited = edited or false, writes = 0 }
    function published:getPhoto() return photo end
    function published:getRemoteId() return self.remoteId end
    function published:setRemoteId(value)
        self.remoteId = value
        self.writes = self.writes + 1
    end
    function published:setRemoteUrl(value) self.url = value end
    function published:getEditedFlag() return self.edited end
    function published:setEditedFlag(value) self.edited = value end
    return published
end

local nextCollectionId = 100
local function newCollection(name, publishedPhotos, options)
    options = options or {}
    nextCollectionId = nextCollectionId + 1
    local collection = {
        localIdentifier = nextCollectionId,
        published = publishedPhotos or {},
        remoteId = options.remoteId,
    }
    function collection:getName() return name end
    function collection:getPublishedPhotos() return self.published end
    function collection:getRemoteId() return self.remoteId end
    function collection:setRemoteId(value) self.remoteId = value end
    function collection:getCollectionInfoSummary()
        return {
            isDefaultCollection = options.isDefault == true,
            collectionSettings = { format = options.format },
        }
    end
    return collection
end

local function newCatalog(collections)
    local catalog = { writes = {}, privateWrites = 0, publicWrites = 0 }
    function catalog:getPublishServices()
        return { { getChildCollections = function() return collections end } }
    end
    function catalog:withWriteAccessDo(name, fn, timeoutParams)
        self.publicWrites = self.publicWrites + 1
        table.insert(self.writes, name)
        self.lastTimeout = timeoutParams and timeoutParams.timeout
        if self.busy then
            return 'aborted'
        end
        fn()
        return 'executed'
    end
    function catalog:withPrivateWriteAccessDo(fn)
        self.privateWrites = self.privateWrites + 1
        fn()
    end
    for _, collection in ipairs(collections) do
        collection.catalog = catalog
    end
    return catalog
end

-- The shape today's bug left behind: one photo, published by two collections, each naming a
-- different asset, with the asset on the photo agreeing with only one of them.
local function splitFixture()
    local photo = newPhoto('edited/L0/001')
    local inDefault = newPublishedPhoto(photo, 'edited/L0/001', true)
    local inAlbum = newPublishedPhoto(photo, 'pre-edit/L0/001', true)
    local other = newPhoto('other/L0/001')
    local otherPublished = newPublishedPhoto(other, 'other/L0/001')
    local default = newCollection('Apple Photos', { inDefault, otherPublished },
        { isDefault = true })
    local album = newCollection('Disney 2026', { inAlbum },
        { remoteId = 'disney-album/L0/040' })
    local catalog = newCatalog({ default, album })
    return {
        catalog = catalog,
        index = Albums.buildIndex(catalog),
        photo = photo,
        other = other,
        default = default,
        album = album,
        inDefault = inDefault,
        inAlbum = inAlbum,
    }
end

local fixture = splitFixture()
assert(fixture.index.collections == 2)
assert(fixture.index.photos == 3)
assert(#Albums.entries(fixture.index, fixture.photo) == 2)
assert(#Albums.entries(fixture.index, fixture.other) == 1)
assert(Albums.describeIndex(fixture.index) == '2 collections, 3 published photos')

-- A removal names an asset, so every identifier the catalog holds has to lead back to its
-- photo, including the one a collection drifted onto.
assert(Albums.photoFor(fixture.index, 'pre-edit/L0/001') == fixture.photo)
assert(Albums.photoFor(fixture.index, 'edited/L0/001') == fixture.photo)
assert(Albums.photoFor(fixture.index, 'never-seen/L0/001') == nil)
assert(Albums.isPublishedElsewhere(fixture.index, fixture.photo, 'JPEG', fixture.album.localIdentifier))
assert(not Albums.isPublishedElsewhere(fixture.index, fixture.other, 'JPEG', fixture.default.localIdentifier))
print('PASS: index covers every collection, photo and identifier')

-- Both collections are waiting to republish, so the asset is stale however current its
-- identifier looks.
assert(not Albums.assetIsCurrent(fixture.index, fixture.photo, 'JPEG'))
fixture.inDefault.edited = false
assert(not Albums.assetIsCurrent(fixture.index, fixture.photo, 'JPEG'))
fixture.inAlbum.edited = false
assert(Albums.assetIsCurrent(fixture.index, fixture.photo, 'JPEG'))

-- Nothing publishes a photo that has only been exported, so nothing can vouch for the asset
-- recorded on it either.
local exportedOnly = newPhoto('exported/L0/001')
assert(not Albums.assetIsCurrent(Albums.buildIndex(newCatalog({})), exportedOnly, 'JPEG'))

-- A collection where the photo is still waiting for its first publish has never held an
-- asset, so it cannot vouch for one either, whether or not Lightroom lists it.
local waiting = newPhoto('exported/L0/001')
local waitingIndex = Albums.buildIndex(newCatalog({
    newCollection('Trip', { newPublishedPhoto(waiting, nil) }),
}))
assert(not Albums.assetIsCurrent(waitingIndex, waiting, 'JPEG'))
print('PASS: an asset is current only while every collection says so')

-- A publish records the collection before the photo, so a photo can be left without an
-- identifier while its collections have one. Republishing it has to inherit from that rather
-- than treat the photo as new to Photos.
fixture = splitFixture()
assert(Albums.lastKnownAsset(fixture.index, fixture.photo, 'JPEG') == 'edited/L0/001')
local halfRecorded = newPhoto()
local halfPublished = newPublishedPhoto(halfRecorded, 'only-on-the-row/L0/001')
local halfIndex = Albums.buildIndex(newCatalog({ newCollection('Trip', { halfPublished }) }))
assert(Albums.lastKnownAsset(halfIndex, halfRecorded, 'JPEG') == 'only-on-the-row/L0/001')
assert(Albums.lastKnownAsset(halfIndex, newPhoto(), 'JPEG') == nil)
print('PASS: a photo without an identifier falls back to its collections')

-- Publishing the default collection produces a new asset. The other collection has to be
-- told about it, and both of the identifiers it replaces have to go.
fixture = splitFixture()
local stale = Albums.staleEntries(fixture.index, fixture.photo, 'JPEG', 'fresh/L0/001',
    fixture.default.localIdentifier)
assert(#stale == 1 and stale[1].publishedPhoto == fixture.inAlbum)
local superseded = Albums.supersededAssets(fixture.index, fixture.photo, 'JPEG', 'fresh/L0/001')
table.sort(superseded)
assert(#superseded == 2, 'expected both old assets, got ' .. #superseded)
assert(superseded[1] == 'edited/L0/001' and superseded[2] == 'pre-edit/L0/001')

-- Reusing the asset the photo already has leaves nothing to delete but the copy the other
-- collection drifted onto.
superseded = Albums.supersededAssets(fixture.index, fixture.photo, 'JPEG', 'edited/L0/001')
assert(#superseded == 1 and superseded[1] == 'pre-edit/L0/001')

-- A collection that already names the new asset is not stale, and the asset in use is never
-- offered for deletion.
assert(#Albums.staleEntries(fixture.index, fixture.other, 'JPEG', 'other/L0/001', nil) == 0)
assert(#Albums.supersededAssets(fixture.index, fixture.other, 'JPEG', 'other/L0/001') == 0)
print('PASS: replacing an asset finds every stale collection and every leftover')

-- An identifier another photo publishes is not ours to delete, whatever this photo once
-- recorded. Virtual copies of one master are the way this happens.
local shared = newPhoto('shared/L0/001')
local sharedPublished = newPublishedPhoto(shared, 'shared/L0/001')
local twin = newPhoto('shared/L0/001')
local twinPublished = newPublishedPhoto(twin, 'shared/L0/001')
local sharedCatalog = newCatalog({ newCollection('Both', { sharedPublished, twinPublished }) })
local sharedIndex = Albums.buildIndex(sharedCatalog)
assert(#Albums.supersededAssets(sharedIndex, shared, 'JPEG', 'fresh/L0/001') == 0)
print('PASS: an asset two photos publish is left alone')

-- Re-pointing writes through the ordinary gate, in one transaction, and clears the flag it
-- would otherwise leave asking to republish work that is already done.
fixture = splitFixture()
local repoints = {}
for _, entry in ipairs(Albums.staleEntries(fixture.index, fixture.photo, 'JPEG', 'fresh/L0/001',
    fixture.default.localIdentifier)) do
    table.insert(repoints, Albums.repoint(entry, 'JPEG', 'fresh/L0/001',
        'photos:albums?albumUuid=disney-album&assetUuid=fresh'))
end
assert(repoints[1].name == 'Disney 2026' and repoints[1].pending == false)
assert(Albums.syncIdentifiers(fixture.catalog, repoints) == 1)
assert(fixture.inAlbum.remoteId == 'fresh/L0/001')
assert(fixture.inAlbum.url == 'photos:albums?albumUuid=disney-album&assetUuid=fresh')
assert(fixture.inAlbum.edited == false)
assert(fixture.catalog.publicWrites == 1 and fixture.catalog.privateWrites == 0)
assert(fixture.catalog.writes[1] == 'Update Photos identifiers')
assert(Albums.syncIdentifiers(fixture.catalog, {}) == 0)
assert(fixture.catalog.publicWrites == 1, 'nothing to do should open no transaction')
print('PASS: re-pointing is one ordinary transaction that clears the republish flag')

-- The asset on the photo is written through the private gate, which stays off the undo stack
-- and does not mark the photo as changed. Writing it when it has not changed is what used to
-- send published photos back to "needs publishing".
local catalog = newCatalog({})
local first = newPhoto()
local second = newPhoto('already/L0/001')
assert(Assets.record(catalog, {
    { photo = first, identifier = 'fresh/L0/001', format = 'JPEG' },
    { photo = second, identifier = 'already/L0/001', format = 'JPEG' },
}) == 1)
assert(catalog.privateWrites == 1 and catalog.publicWrites == 0)
assert(Assets.identifier(first, 'JPEG') == 'fresh/L0/001')
assert(first.properties[Assets.PROP_SYNC_DATE] == '2026-11-08T12:00:00Z')
assert(second.properties[Assets.PROP_SYNC_DATE] == nil, 'unchanged photos stay untouched')
assert(Assets.record(catalog, { { photo = first, identifier = 'fresh/L0/001', format = 'JPEG' } }) == 0)
assert(catalog.privateWrites == 1)

assert(Assets.forget(catalog, { { photo = first, format = 'JPEG' } }) == 1)
assert(Assets.identifier(first, 'JPEG') == nil)
assert(first.properties[Assets.PROP_SYNC_DATE] == nil)
assert(Assets.forget(catalog, {}) == 0)
assert(catalog.privateWrites == 2)
print('PASS: the asset on a photo is written privately, and only when it changes')

-- Reconciling sets the album to what the photos have, not to what the collection recorded,
-- so a collection that drifted onto its own copy is brought back in line.
fixture = splitFixture()
importerCalls = {}
local reconciled = Albums.reconcile(fixture.album)
assert(reconciled.status == 'success' and not reconciled.skipped)
local sync = called('sync')
assert(sync.identifier == 'disney-album/L0/040')
assert(#sync.assets == 1 and sync.assets[1] == 'edited/L0/001')
assert(fixture.inAlbum.remoteId == 'edited/L0/001', 'the drifted row should be re-pointed')
assert(fixture.inAlbum.url == 'photos:albums?albumUuid=disney-album&assetUuid=edited')
assert(reconciled.repointed == 1 and reconciled.adopted == 0)

-- The copy it just dropped has to go with it. Re-pointing takes away the last reference to
-- it, so leaving it behind strands it in the library with nothing able to name it again.
local deletedCall = called('delete')
assert(deletedCall and #deletedCall.assets == 1, 'the superseded copy should be deleted')
assert(deletedCall.assets[1] == 'pre-edit/L0/001')
assert(reconciled.deleted == 1)

-- The album has to be right before anything is deleted, since a failure up to that point
-- leaves assets something can still be pointed back at.
local order = {}
for _, call in ipairs(importerCalls) do table.insert(order, call.command) end
assert(table.concat(order, ' '):find('sync delete', 1, true), table.concat(order, ' '))

-- The default collection has no album to reconcile against, and is not one of the albums the
-- menu action then claims to have updated.
importerCalls = {}
local skippedResult = Albums.reconcile(fixture.default)
assert(skippedResult.status == 'success' and skippedResult.skipped == true)
assert(#importerCalls == 0)

-- A collection published before the asset moved onto the photo has nothing to read, so the
-- identifier it recorded is adopted rather than discarded.
local legacyPhoto = newPhoto()
local legacyPublished = newPublishedPhoto(legacyPhoto, 'legacy/L0/001')
local legacy = newCollection('Halloween 23', { legacyPublished }, { remoteId = 'legacy-album/L0/040' })
newCatalog({ legacy })
importerCalls = {}
local adopted = Albums.reconcile(legacy)
assert(adopted.status == 'success' and adopted.adopted == 1)
assert(Assets.identifier(legacyPhoto, 'JPEG') == 'legacy/L0/001')
assert(called('sync').assets[1] == 'legacy/L0/001')
assert(legacyPublished.writes == 0, 'the row already agreed, so it should not be written')
assert(called('delete') == nil, 'adopting an identifier supersedes nothing')

-- A collection that has never been published has no album yet, so one is made and recorded.
local fresh = newCollection('Food Truck', {})
newCatalog({ fresh })
importerCalls = {}
assert(Albums.reconcile(fresh).status == 'success')
assert(importerCalls[1].command == 'ensure' and importerCalls[1].identifier == nil)
assert(fresh.remoteId == 'new-album/L0/040')
assert(called('delete') == nil)
print('PASS: reconcile follows the photos, adopts legacy rows and creates a missing album')

-- Re-pointing is not limited to the collection being reconciled. The copy being dropped is
-- about to be deleted, so a sibling left holding it would be the next thing to break.
local shared2 = newPhoto('current/L0/001')
local inFirst = newPublishedPhoto(shared2, 'current/L0/001')
local inSecond = newPublishedPhoto(shared2, 'older/L0/001')
local first = newCollection('Trip', { inFirst }, { remoteId = 'trip-album/L0/040' })
local second = newCollection('Favorites', { inSecond }, { remoteId = 'favorites-album/L0/040' })
newCatalog({ first, second })
importerCalls = {}
local spread = Albums.reconcile(first)
assert(spread.status == 'success' and spread.repointed == 1)
assert(inSecond.remoteId == 'current/L0/001', 'the sibling collection should be re-pointed too')
assert(inSecond.edited == false)
assert(called('delete').assets[1] == 'older/L0/001')
print('PASS: reconcile re-points every collection and deletes what it orphans')

-- Deep links name the album the asset was published through, falling back to the library.
assert(Albums.assetUrl('album-uuid/L0/040', 'asset-uuid/L0/001')
    == 'photos:albums?albumUuid=album-uuid&assetUuid=asset-uuid')
assert(Albums.assetUrl(nil, 'asset-uuid/L0/001')
    == 'photos://asset?assetLocalIdentifier=asset-uuid')
assert(Albums.albumUuid('') == nil and Albums.albumUuid(nil) == nil)
assert(Albums.isDefaultCollection(fixture.default))
assert(not Albums.isDefaultCollection(fixture.album))
assert(Albums.albumTarget(fixture.default) == nil)
assert(Albums.albumTarget(fixture.album).name == 'Disney 2026')
print('PASS: deep links, album targets and the default collection')

-- Formats. Everything about the output but the format is fixed, so the format alone decides
-- whether two collections can share an asset.
assert(Formats.resolve(nil) == 'JPEG' and Formats.resolve('TIFF') == 'TIFF')
assert(Formats.resolve('PSD') == 'JPEG', 'a format this version does not know is the default')
assert(Formats.forCollection(newCollection('Unset', {})) == 'JPEG')
assert(Formats.forCollection(newCollection('Prints', {}, { format = 'TIFF' })) == 'TIFF')
local tiffSettings = Formats.exportSettings('TIFF')
assert(tiffSettings.LR_format == 'TIFF' and tiffSettings.LR_export_bitDepth == 16)
assert(tiffSettings.LR_embeddedMetadataOption == 'all', 'the shared settings apply to every format')
assert(tiffSettings.LR_jpeg_quality == nil)
tiffSettings.LR_format = 'changed'
assert(Formats.exportSettings('TIFF').LR_format == 'TIFF', 'callers get a table of their own')
assert(Formats.exportSettings(nil).LR_format == 'JPEG')

-- JPEG XL is full quality the way the JPEG is: lossy at the top of the scale, not lossless.
local jxlSettings = Formats.exportSettings('JXL')
assert(jxlSettings.LR_format == 'JXL' and jxlSettings.LR_jxl_quality == 1)
assert(jxlSettings.LR_jxl_losslessQuality == false and jxlSettings.LR_export_bitDepth == 16)
assert(jxlSettings.LR_export_colorSpace == 'sRGB' and jxlSettings.LR_tiff_compressionMethod == nil)
assert(Formats.forCollection(newCollection('Modern', {}, { format = 'JXL' })) == 'JXL')
assert(table.concat(Formats.names(), ' ') == 'JPEG JXL TIFF')

-- An identifier is recorded per format, and Lightroom only stores fields the plugin declares.
local declared = {}
for _, field in ipairs(dofile('ApplePhotosPublisher.lrplugin/PhotosMetadataDefinition.lua').metadataFieldsForPhotos) do
    declared[field.id] = true
end
local properties = {}
for _, name in ipairs(Formats.names()) do
    local property = Formats.property(name)
    assert(declared[property], name .. ' has no metadata field for ' .. property)
    assert(not properties[property], 'two formats share ' .. property)
    properties[property] = true
end
assert(#Formats.menuItems() == #Formats.names())
print('PASS: formats resolve, carry their own settings and have a metadata field each')

-- One photo in two JPEG albums and two TIFF albums: two assets, not four and not one.
local function formatFixture()
    local photo = newPhoto('jpeg/L0/001', 'tiff/L0/001')
    local rows = {
        family = newPublishedPhoto(photo, 'jpeg/L0/001'),
        trips = newPublishedPhoto(photo, 'jpeg/L0/001'),
        prints = newPublishedPhoto(photo, 'tiff/L0/001'),
        portfolio = newPublishedPhoto(photo, 'tiff/L0/001'),
    }
    local collections = {
        family = newCollection('Family', { rows.family }, { remoteId = 'family-album/L0/040' }),
        trips = newCollection('Trips', { rows.trips }, { remoteId = 'trips-album/L0/040' }),
        prints = newCollection('Prints', { rows.prints },
            { remoteId = 'prints-album/L0/040', format = 'TIFF' }),
        portfolio = newCollection('Portfolio', { rows.portfolio },
            { remoteId = 'portfolio-album/L0/040', format = 'TIFF' }),
    }
    local catalog = newCatalog({
        collections.family, collections.trips, collections.prints, collections.portfolio,
    })
    return {
        photo = photo,
        rows = rows,
        collections = collections,
        catalog = catalog,
        index = Albums.buildIndex(catalog),
    }
end

local formats = formatFixture()
assert(Assets.formatOf(formats.photo, 'jpeg/L0/001') == 'JPEG')
assert(Assets.formatOf(formats.photo, 'tiff/L0/001') == 'TIFF')
assert(Assets.formatOf(formats.photo, 'unknown/L0/001') == nil and Assets.formatOf(formats.photo, '') == nil)
assert(Albums.lastKnownAsset(formats.index, formats.photo, 'JPEG') == 'jpeg/L0/001')
assert(Albums.lastKnownAsset(formats.index, formats.photo, 'TIFF') == 'tiff/L0/001')

-- A collection in the other format publishes the photo, but not this asset, so it does not
-- keep it alive.
local familyId = formats.collections.family.localIdentifier
local printsId = formats.collections.prints.localIdentifier
assert(Albums.isPublishedElsewhere(formats.index, formats.photo, 'JPEG', familyId))
formats.collections.trips.published = {}
local withoutTrips = Albums.buildIndex(formats.catalog)
assert(not Albums.isPublishedElsewhere(withoutTrips, formats.photo, 'JPEG', familyId),
    'two TIFF albums are no reason to keep the JPEG')
assert(Albums.isPublishedElsewhere(withoutTrips, formats.photo, 'TIFF', printsId))

-- Republishing the TIFF touches nothing on the JPEG side: its albums are not re-pointed and
-- its asset is not a leftover.
formats = formatFixture()
printsId = formats.collections.prints.localIdentifier
local tiffStale = Albums.staleEntries(formats.index, formats.photo, 'TIFF', 'tiff-2/L0/001', printsId)
assert(#tiffStale == 1 and tiffStale[1].publishedPhoto == formats.rows.portfolio)
local tiffLeftovers = Albums.supersededAssets(formats.index, formats.photo, 'TIFF', 'tiff-2/L0/001')
assert(#tiffLeftovers == 1 and tiffLeftovers[1] == 'tiff/L0/001')
assert(#Albums.supersededAssets(formats.index, formats.photo, 'JPEG', 'jpeg/L0/001') == 0)

-- A TIFF album waiting to republish says nothing about the JPEG, and the other way round.
formats.rows.prints.edited = true
assert(Albums.assetIsCurrent(formats.index, formats.photo, 'JPEG'))
assert(not Albums.assetIsCurrent(formats.index, formats.photo, 'TIFF'))

-- A third format is a third asset, and no closer to JPEG for sharing most of its name.
local three = newPhoto('jpeg/L0/001', 'tiff/L0/001')
three.properties[Formats.property('JXL')] = 'jxl/L0/001'
local jxlRow = newPublishedPhoto(three, 'jxl/L0/001')
local jxlAlbum = newCollection('Modern', { jxlRow }, { format = 'JXL' })
local threeIndex = Albums.buildIndex(newCatalog({
    newCollection('Family', { newPublishedPhoto(three, 'jpeg/L0/001') }),
    newCollection('Prints', { newPublishedPhoto(three, 'tiff/L0/001') }, { format = 'TIFF' }),
    jxlAlbum,
}))
assert(Assets.formatOf(three, 'jxl/L0/001') == 'JXL')
assert(Albums.lastKnownAsset(threeIndex, three, 'JXL') == 'jxl/L0/001')
assert(not Albums.isPublishedElsewhere(threeIndex, three, 'JXL', jxlAlbum.localIdentifier))
assert(Albums.isPublishedElsewhere(threeIndex, three, 'JPEG', jxlAlbum.localIdentifier))
local jxlLeftovers = Albums.supersededAssets(threeIndex, three, 'JXL', 'jxl-2/L0/001')
assert(#jxlLeftovers == 1 and jxlLeftovers[1] == 'jxl/L0/001')
assert(#Albums.staleEntries(threeIndex, three, 'JXL', 'jxl-2/L0/001', jxlAlbum.localIdentifier) == 0)
print('PASS: a photo has one asset per format, and each format keeps to itself')

-- Joining a third TIFF album reuses the TIFF. Joining the first album of a format has
-- nothing to reuse, however many assets the photo has in other formats.
formats = formatFixture()
assert(Albums.assetIsCurrent(formats.index, formats.photo, 'TIFF'))
local jpegOnly = newPhoto('only-jpeg/L0/001')
local jpegOnlyIndex = Albums.buildIndex(newCatalog({
    newCollection('Family', { newPublishedPhoto(jpegOnly, 'only-jpeg/L0/001') }),
    newCollection('Prints', {}, { format = 'TIFF' }),
}))
assert(Albums.lastKnownAsset(jpegOnlyIndex, jpegOnly, 'TIFF') == nil)
assert(not Albums.assetIsCurrent(jpegOnlyIndex, jpegOnly, 'TIFF'))
assert(Albums.predecessor(jpegOnlyIndex, jpegOnly, 'TIFF', nil) == nil,
    'a new format starts clean while the JPEG is still published')
print('PASS: collections in a format share its asset, and a new format renders its own')

-- Changing a collection's format. It goes on naming what it published in the old one until
-- each photo is published again, and Lightroom will not offer them unless they are flagged.
local function switchFixture(others)
    local photo = newPhoto('jpeg/L0/001', others and others.tiff)
    local switched = newPublishedPhoto(photo, 'jpeg/L0/001')
    local collections = {
        newCollection('Family', { switched }, { remoteId = 'family-album/L0/040', format = 'TIFF' }),
    }
    local rows = { switched = switched }
    local trips
    if others and others.jpegAlbum then
        rows.jpeg = newPublishedPhoto(photo, 'jpeg/L0/001')
        trips = newCollection('Trips', { rows.jpeg })
        table.insert(collections, trips)
    end
    if others and others.tiff then
        rows.tiff = newPublishedPhoto(photo, others.tiff)
        table.insert(collections, newCollection('Prints', { rows.tiff }, { format = 'TIFF' }))
    end
    local catalog = newCatalog(collections)
    return {
        photo = photo,
        rows = rows,
        family = collections[1],
        trips = trips,
        catalog = catalog,
        index = Albums.buildIndex(catalog),
    }
end

local switch = switchFixture()
assert(Albums.flagForFormat(switch.family, 'TIFF') == 1)
assert(switch.rows.switched.edited == true)
assert(switch.catalog.writes[1] == 'Mark to Republish' and switch.catalog.lastTimeout == 30)
assert(Albums.flagForFormat(switch.family, 'TIFF') == 0, 'already flagged, so nothing to write')
assert(switch.catalog.publicWrites == 1)

-- Saving the settings without changing the format flags nothing.
local unchanged = formatFixture()
assert(Albums.flagForFormat(unchanged.collections.family, 'JPEG') == 0)
assert(Albums.flagForFormat(unchanged.collections.prints, 'TIFF') == 0)
assert(unchanged.catalog.publicWrites == 0)

-- A catalog that stays busy is reported rather than passed off as done.
local busy = switchFixture()
busy.catalog.busy = true
assert(not pcall(Albums.flagForFormat, busy.family, 'TIFF'))
assert(busy.rows.switched.edited == false)
print('PASS: changing format flags the photos published in the old one, and only those')

-- Nothing else publishes the JPEG, so the switch drops it. The TIFF takes over from it, which
-- is what carries an album the user filed it in by hand across the change.
switch = switchFixture()
local familyLocalId = switch.family.localIdentifier
local outgoing, outgoingFormat = Albums.outgoingAsset(switch.index, switch.photo, 'TIFF', familyLocalId)
assert(outgoing == 'jpeg/L0/001' and outgoingFormat == 'JPEG')
assert(not Albums.isPublishedElsewhere(switch.index, switch.photo, 'JPEG', familyLocalId))
assert(Albums.predecessor(switch.index, switch.photo, 'TIFF', familyLocalId) == 'jpeg/L0/001')
assert(Albums.lastKnownAsset(switch.index, switch.photo, 'TIFF') == nil,
    'the JPEG is not mistaken for a TIFF to reuse')
assert(#Albums.supersededAssets(switch.index, switch.photo, 'TIFF', 'tiff-new/L0/001') == 0,
    'and is not swept up as a stale TIFF either')
local droppedJpegs = Albums.supersededAssets(switch.index, switch.photo, 'JPEG', nil)
assert(#droppedJpegs == 1 and droppedJpegs[1] == 'jpeg/L0/001')

-- Another album still publishes the JPEG, so it survives and only leaves this album. The
-- TIFF starts clean, since inheriting the JPEG's albums would file it in that other album.
switch = switchFixture({ jpegAlbum = true })
familyLocalId = switch.family.localIdentifier
assert(Albums.outgoingAsset(switch.index, switch.photo, 'TIFF', familyLocalId) == 'jpeg/L0/001')
assert(Albums.isPublishedElsewhere(switch.index, switch.photo, 'JPEG', familyLocalId))
assert(Albums.predecessor(switch.index, switch.photo, 'TIFF', familyLocalId) == nil)

-- A collection that did not change format has nothing outgoing.
assert(Albums.outgoingAsset(switch.index, switch.photo, 'JPEG', switch.trips.localIdentifier) == nil)
print('PASS: a changed collection lets go of the old format, deleting it only when orphaned')

-- Another TIFF album already has the photo, so the switched one reuses its asset. Its own
-- flag is the mark that it changed, not a report that the TIFF is stale.
switch = switchFixture({ tiff = 'tiff/L0/001' })
switch.rows.switched.edited = true
assert(Albums.assetIsCurrent(switch.index, switch.photo, 'TIFF'))
assert(Albums.lastKnownAsset(switch.index, switch.photo, 'TIFF') == 'tiff/L0/001')
-- An edit flags every collection, and then the TIFF really is stale.
switch.rows.tiff.edited = true
assert(not Albums.assetIsCurrent(switch.index, switch.photo, 'TIFF'))

-- Replacing the JPEG while a changed collection is still naming it. The collection is told
-- where the asset went, so that it lets go of the right one later, but it keeps its flag:
-- it has not published the photo in its own format yet.
switch = switchFixture({ jpegAlbum = true })
switch.rows.switched.edited = true
local moved = {}
for _, entry in ipairs(Albums.staleEntries(switch.index, switch.photo, 'JPEG', 'jpeg-2/L0/001',
    switch.trips.localIdentifier)) do
    table.insert(moved, Albums.repoint(entry, 'JPEG', 'jpeg-2/L0/001'))
end
assert(#moved == 1 and moved[1].publishedPhoto == switch.rows.switched and moved[1].pending == true)
assert(Albums.syncIdentifiers(switch.catalog, moved) == 1)
assert(switch.rows.switched.remoteId == 'jpeg-2/L0/001')
assert(switch.rows.switched.edited == true, 'still waiting to publish as TIFF')
print('PASS: a changed collection reuses the new format, and follows the old one until it does')

-- A removal names an asset, and its format is the asset's rather than the collection's.
switch = switchFixture({ tiff = 'tiff/L0/001' })
assert(Albums.formatOf(switch.index, switch.photo, 'jpeg/L0/001') == 'JPEG')
assert(Albums.formatOf(switch.index, switch.photo, 'tiff/L0/001') == 'TIFF')
local driftedPhoto = newPhoto()
local driftedIndex = Albums.buildIndex(newCatalog({
    newCollection('Prints', { newPublishedPhoto(driftedPhoto, 'drifted/L0/001') }, { format = 'TIFF' }),
}))
assert(Albums.formatOf(driftedIndex, driftedPhoto, 'drifted/L0/001') == 'TIFF',
    'an asset the photo does not have is taken to be in its collection\'s format')
assert(Albums.formatOf(driftedIndex, driftedPhoto, 'never-seen/L0/001') == 'JPEG')
print('PASS: an asset knows its format whatever its collection has become')

-- Forgetting one format leaves the other, and the sync date with it.
local both = newPhoto('jpeg/L0/001', 'tiff/L0/001')
both.properties[Assets.PROP_SYNC_DATE] = '2026-11-08T12:00:00Z'
local forgetCatalog = newCatalog({})
assert(Assets.forget(forgetCatalog, { { photo = both, format = 'TIFF' } }) == 1)
assert(Assets.identifier(both, 'TIFF') == nil and Assets.identifier(both, 'JPEG') == 'jpeg/L0/001')
assert(both.properties[Assets.PROP_SYNC_DATE] == '2026-11-08T12:00:00Z')
assert(Assets.forget(forgetCatalog, { { photo = both, format = 'JPEG' } }) == 1)
assert(both.properties[Assets.PROP_SYNC_DATE] == nil, 'the date goes with the last asset')

-- Recording is per format too, and leaves the other alone.
local recordCatalog = newCatalog({})
local recorded = newPhoto('jpeg/L0/001')
assert(Assets.record(recordCatalog, { { photo = recorded, identifier = 'tiff/L0/001', format = 'TIFF' } }) == 1)
assert(Assets.identifier(recorded, 'JPEG') == 'jpeg/L0/001' and Assets.identifier(recorded, 'TIFF') == 'tiff/L0/001')
print('PASS: assets are recorded and forgotten one format at a time')

-- Reconciling a TIFF album sets it to the TIFFs. The JPEGs belong to other albums.
formats = formatFixture()
formats.rows.portfolio.remoteId = 'tiff-old/L0/001'
formats.index = Albums.buildIndex(formats.catalog)
importerCalls = {}
local tiffReconciled = Albums.reconcile(formats.collections.prints)
assert(tiffReconciled.status == 'success' and tiffReconciled.repointed == 1)
assert(called('sync').identifier == 'prints-album/L0/040')
assert(#called('sync').assets == 1 and called('sync').assets[1] == 'tiff/L0/001')
assert(formats.rows.portfolio.remoteId == 'tiff/L0/001', 'the drifted TIFF album is re-pointed')
assert(formats.rows.family.remoteId == 'jpeg/L0/001' and formats.rows.family.writes == 0)
assert(#called('delete').assets == 1 and called('delete').assets[1] == 'tiff-old/L0/001')

-- A collection that changed format and has not published since keeps what its album has.
-- The JPEG it names is not adopted as the photo's TIFF, and is not deleted.
switch = switchFixture()
importerCalls = {}
local pendingReconcile = Albums.reconcile(switch.family)
assert(pendingReconcile.status == 'success' and pendingReconcile.adopted == 0)
assert(called('sync').assets[1] == 'jpeg/L0/001')
assert(Assets.identifier(switch.photo, 'TIFF') == nil)
assert(called('delete') == nil)
print('PASS: reconcile works in the collection\'s format and waits out a format change')
