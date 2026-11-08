-- Run from the repository root. No Lightroom or Photos access is required.
--
-- Covers the mapping between Lightroom's published photos and Apple Photos assets: which
-- collections publish a photo, which asset that photo has, which assets are left over, and
-- what reconciling an album sets it to. These are the answers that used to be derived from
-- one collection's identifier at a time, which is what let two collections drift onto two
-- copies of the same photo.

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
}

local Assets = dofile('ApplePhotosPublisher.lrplugin/lib/Assets.lua')
loaded['lib/Assets'] = Assets
local Albums = dofile('ApplePhotosPublisher.lrplugin/lib/Albums.lua')

-- Stand-ins for the SDK objects, duck-typed to the calls these modules make.

local nextPhotoId = 0
local function newPhoto(identifier)
    nextPhotoId = nextPhotoId + 1
    local photo = { localIdentifier = nextPhotoId, properties = {} }
    function photo:getPropertyForPlugin(_, key) return self.properties[key] end
    function photo:setPropertyForPlugin(_, key, value) self.properties[key] = value end
    if identifier then
        photo.properties[Assets.PROP_IDENTIFIER] = identifier
    end
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
        return { isDefaultCollection = options.isDefault == true }
    end
    return collection
end

local function newCatalog(collections)
    local catalog = { writes = {}, privateWrites = 0, publicWrites = 0 }
    function catalog:getPublishServices()
        return { { getChildCollections = function() return collections end } }
    end
    function catalog:withWriteAccessDo(name, fn)
        self.publicWrites = self.publicWrites + 1
        table.insert(self.writes, name)
        fn()
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
assert(Albums.isPublishedElsewhere(fixture.index, fixture.photo, fixture.album.localIdentifier))
assert(not Albums.isPublishedElsewhere(fixture.index, fixture.other, fixture.default.localIdentifier))
print('PASS: index covers every collection, photo and identifier')

-- Both collections are waiting to republish, so the asset is stale however current its
-- identifier looks.
assert(not Albums.assetIsCurrent(fixture.index, fixture.photo))
fixture.inDefault.edited = false
assert(not Albums.assetIsCurrent(fixture.index, fixture.photo))
fixture.inAlbum.edited = false
assert(Albums.assetIsCurrent(fixture.index, fixture.photo))

-- Nothing publishes a photo that has only been exported, so nothing can vouch for the asset
-- recorded on it either.
local exportedOnly = newPhoto('exported/L0/001')
assert(not Albums.assetIsCurrent(Albums.buildIndex(newCatalog({})), exportedOnly))
print('PASS: an asset is current only while every collection says so')

-- A publish records the collection before the photo, so a photo can be left without an
-- identifier while its collections have one. Republishing it has to inherit from that rather
-- than treat the photo as new to Photos.
fixture = splitFixture()
assert(Albums.lastKnownAsset(fixture.index, fixture.photo) == 'edited/L0/001')
local halfRecorded = newPhoto()
local halfPublished = newPublishedPhoto(halfRecorded, 'only-on-the-row/L0/001')
local halfIndex = Albums.buildIndex(newCatalog({ newCollection('Trip', { halfPublished }) }))
assert(Albums.lastKnownAsset(halfIndex, halfRecorded) == 'only-on-the-row/L0/001')
assert(Albums.lastKnownAsset(halfIndex, newPhoto()) == nil)
print('PASS: a photo without an identifier falls back to its collections')

-- Publishing the default collection produces a new asset. The other collection has to be
-- told about it, and both of the identifiers it replaces have to go.
fixture = splitFixture()
local stale = Albums.staleEntries(fixture.index, fixture.photo, 'fresh/L0/001',
    fixture.default.localIdentifier)
assert(#stale == 1 and stale[1].publishedPhoto == fixture.inAlbum)
local superseded = Albums.supersededAssets(fixture.index, fixture.photo, 'fresh/L0/001')
table.sort(superseded)
assert(#superseded == 2, 'expected both old assets, got ' .. #superseded)
assert(superseded[1] == 'edited/L0/001' and superseded[2] == 'pre-edit/L0/001')

-- Reusing the asset the photo already has leaves nothing to delete but the copy the other
-- collection drifted onto.
superseded = Albums.supersededAssets(fixture.index, fixture.photo, 'edited/L0/001')
assert(#superseded == 1 and superseded[1] == 'pre-edit/L0/001')

-- A collection that already names the new asset is not stale, and the asset in use is never
-- offered for deletion.
assert(#Albums.staleEntries(fixture.index, fixture.other, 'other/L0/001', nil) == 0)
assert(#Albums.supersededAssets(fixture.index, fixture.other, 'other/L0/001') == 0)
print('PASS: replacing an asset finds every stale collection and every leftover')

-- An identifier another photo publishes is not ours to delete, whatever this photo once
-- recorded. Virtual copies of one master are the way this happens.
local shared = newPhoto('shared/L0/001')
local sharedPublished = newPublishedPhoto(shared, 'shared/L0/001')
local twin = newPhoto('shared/L0/001')
local twinPublished = newPublishedPhoto(twin, 'shared/L0/001')
local sharedCatalog = newCatalog({ newCollection('Both', { sharedPublished, twinPublished }) })
local sharedIndex = Albums.buildIndex(sharedCatalog)
assert(#Albums.supersededAssets(sharedIndex, shared, 'fresh/L0/001') == 0)
print('PASS: an asset two photos publish is left alone')

-- Re-pointing writes through the ordinary gate, in one transaction, and clears the flag it
-- would otherwise leave asking to republish work that is already done.
fixture = splitFixture()
local repoints = {}
for _, entry in ipairs(Albums.staleEntries(fixture.index, fixture.photo, 'fresh/L0/001',
    fixture.default.localIdentifier)) do
    table.insert(repoints, {
        publishedPhoto = entry.publishedPhoto,
        identifier = 'fresh/L0/001',
        url = 'photos:albums?albumUuid=disney-album&assetUuid=fresh',
    })
end
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
    { photo = first, identifier = 'fresh/L0/001' },
    { photo = second, identifier = 'already/L0/001' },
}) == 1)
assert(catalog.privateWrites == 1 and catalog.publicWrites == 0)
assert(Assets.identifier(first) == 'fresh/L0/001')
assert(first.properties[Assets.PROP_SYNC_DATE] == '2026-11-08T12:00:00Z')
assert(second.properties[Assets.PROP_SYNC_DATE] == nil, 'unchanged photos stay untouched')
assert(Assets.record(catalog, { { photo = first, identifier = 'fresh/L0/001' } }) == 0)
assert(catalog.privateWrites == 1)

assert(Assets.forget(catalog, { first }) == 1)
assert(Assets.identifier(first) == nil)
assert(first.properties[Assets.PROP_SYNC_DATE] == nil)
assert(Assets.forget(catalog, {}) == 0)
assert(catalog.privateWrites == 2)
print('PASS: the asset on a photo is written privately, and only when it changes')

-- Reconciling sets the album to what the photos have, not to what the collection recorded,
-- so a collection that drifted onto its own copy is brought back in line.
fixture = splitFixture()
importerCalls = {}
assert(Albums.reconcile(fixture.album).status == 'success')
local sync = importerCalls[#importerCalls]
assert(sync.command == 'sync' and sync.identifier == 'disney-album/L0/040')
assert(#sync.assets == 1 and sync.assets[1] == 'edited/L0/001')
assert(fixture.inAlbum.remoteId == 'edited/L0/001', 'the drifted row should be re-pointed')
assert(fixture.inAlbum.url == 'photos:albums?albumUuid=disney-album&assetUuid=edited')

-- The default collection has no album to reconcile against.
importerCalls = {}
assert(Albums.reconcile(fixture.default).status == 'success')
assert(#importerCalls == 0)

-- A collection published before the asset moved onto the photo has nothing to read, so the
-- identifier it recorded is adopted rather than discarded.
local legacyPhoto = newPhoto()
local legacyPublished = newPublishedPhoto(legacyPhoto, 'legacy/L0/001')
local legacy = newCollection('Halloween 23', { legacyPublished }, { remoteId = 'legacy-album/L0/040' })
newCatalog({ legacy })
importerCalls = {}
assert(Albums.reconcile(legacy).status == 'success')
assert(Assets.identifier(legacyPhoto) == 'legacy/L0/001')
assert(importerCalls[#importerCalls].assets[1] == 'legacy/L0/001')
assert(legacyPublished.writes == 0, 'the row already agreed, so it should not be written')

-- A collection that has never been published has no album yet, so one is made and recorded.
local fresh = newCollection('Food Truck', {})
newCatalog({ fresh })
importerCalls = {}
assert(Albums.reconcile(fresh).status == 'success')
assert(importerCalls[1].command == 'ensure' and importerCalls[1].identifier == nil)
assert(fresh.remoteId == 'new-album/L0/040')
print('PASS: reconcile follows the photos, adopts legacy rows and creates a missing album')

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
