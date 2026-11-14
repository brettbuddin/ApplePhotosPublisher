-- Run from the repository root. No Lightroom or Photos access is required.
--
-- Drives the publish service end to end: the real provider, Albums, Assets, Formats and
-- Renderer, against stand-ins for Lightroom's catalog and export pipeline and for the helper.
-- The helper stand-in keeps a small Photos library of its own, so the assertions are about
-- what a publish leaves in Photos rather than about which functions it called.
--
-- What it is here to pin down is the clustering: a photo is rendered and imported once per
-- output format, however many collections publish it, and collections in different formats
-- never share an asset.

local modules = {}
function import(name) return assert(modules[name], name) end

_PLUGIN = { id = 'org.buddin.lrphotossync', path = '/plugin' }

-- The helper, and the Photos library behind it.

local library
local function resetLibrary()
    library = { assets = {}, albums = {}, nextAsset = 0, nextAlbum = 0, imports = 0, launches = {} }
end
resetLibrary()

local function albumContents(identifier)
    local contents = {}
    for asset in pairs(library.albums[identifier] or {}) do
        table.insert(contents, asset)
    end
    table.sort(contents)
    return table.concat(contents, ' ')
end

local function assetList()
    local assets = {}
    for asset in pairs(library.assets) do
        table.insert(assets, asset)
    end
    table.sort(assets)
    return table.concat(assets, ' ')
end

local Importer = { STATUS_SUCCESS = 'success', STATUS_ERROR = 'error' }

function Importer.importPhotos(photos, album)
    table.insert(library.launches, 'import')
    local resolved
    if album then
        local identifier = album.identifier
        local created = false
        if not identifier or not library.albums[identifier] then
            library.nextAlbum = library.nextAlbum + 1
            identifier = 'album-' .. library.nextAlbum .. '/L0/040'
            library.albums[identifier] = {}
            created = true
        end
        resolved = { identifier = identifier, created = created }
    end

    local results = {}
    for _, photo in ipairs(photos) do
        local result
        if photo.reuseIdentifier then
            if library.assets[photo.reuseIdentifier] then
                result = { status = 'success', localIdentifier = photo.reuseIdentifier, reused = true }
            else
                result = { status = 'error', errorCode = 'REUSE_MISSING', errorMessage = 'deleted' }
            end
        else
            library.nextAsset = library.nextAsset + 1
            library.imports = library.imports + 1
            local identifier = 'asset-' .. library.nextAsset .. '/L0/001'
            local previous = photo.previousIdentifier and library.assets[photo.previousIdentifier]
            library.assets[identifier] = {
                path = photo.path,
                favorite = previous and previous.favorite or false,
            }
            -- Album memberships follow the asset being replaced.
            if previous then
                for _, members in pairs(library.albums) do
                    if members[photo.previousIdentifier] then
                        members[identifier] = true
                    end
                end
            end
            result = { status = 'success', localIdentifier = identifier, reused = false }
        end
        if result.status == 'success' then
            result.url = 'photos://asset?assetLocalIdentifier=' .. result.localIdentifier
            if resolved then
                library.albums[resolved.identifier][result.localIdentifier] = true
            end
        end
        results[photo.path] = result
    end
    return { status = 'success', results = results, album = resolved }
end

function Importer.deletePhotos(identifiers)
    table.insert(library.launches, 'delete')
    local deleted = 0
    for _, identifier in ipairs(identifiers) do
        if library.assets[identifier] then
            library.assets[identifier] = nil
            deleted = deleted + 1
        end
        for _, members in pairs(library.albums) do
            members[identifier] = nil
        end
    end
    return { status = 'success', deletedCount = deleted }
end

function Importer.removeFromAlbum(identifier, assetIdentifiers)
    table.insert(library.launches, 'album remove')
    for _, asset in ipairs(assetIdentifiers) do
        library.albums[identifier][asset] = nil
    end
    return { status = 'success' }
end

function Importer.deleteAlbum(identifier)
    table.insert(library.launches, 'album delete')
    library.albums[identifier] = nil
    return { status = 'success' }
end

function Importer.isAuthorizationError() return false end
function Importer.isUserCancelled() return false end
function Importer.isReuseMissing(result) return result.errorCode == 'REUSE_MISSING' end

-- Lightroom.

local logged = {}
local loaded = {
    ['lib/Logger'] = {
        info = function(_, message) table.insert(logged, message) end,
        error = function(_, message) table.insert(logged, 'ERROR ' .. message) end,
    },
    ['lib/Time'] = { nowISO8601 = function() return '2026-11-14T12:00:00Z' end },
    ['lib/Importer'] = Importer,
    ['lib/Shell'] = { openUrl = function() end },
}
package.loaded.PluginModuleLoader = function(name) return assert(loaded[name], name) end

local catalog
local renders = { lightroom = 0, plugin = 0, sessions = {} }
local deletedPaths = {}

modules.LrApplication = { activeCatalog = function() return catalog end }
modules.LrDialogs = { message = function() end }
modules.LrErrors = { throwUserError = function(message) error(message, 0) end }
modules.LrTasks = {
    pcall = pcall,
    startAsyncTask = function(fn) fn() end,
}
modules.LrView = { bind = function(key) return { boundTo = key } end }
modules.LrDate = { currentTime = function() return 1 end }
modules.LrPathUtils = {
    child = function(parent, child) return parent .. '/' .. child end,
    getStandardFilePath = function() return '/tmp' end,
}
modules.LrFileUtils = {
    chooseUniqueFileName = function(path) return path end,
    createAllDirectories = function() return true end,
    delete = function(path) deletedPaths[path] = true end,
}

--- The names of the photos the plugin's own export session should fail to render.
local failingRenders = {}

-- The plugin's own export session, as used for formats the service does not render.
modules.LrExportSession = function(params)
    table.insert(renders.sessions, params.exportSettings)
    local session = {}
    function session:renditions()
        local i = 0
        return function()
            i = i + 1
            local photo = params.photosToExport[i]
            if not photo then return nil end
            local rendition = { photo = photo }
            function rendition:waitForRender()
                if failingRenders[photo.name] then
                    return false, 'Lightroom could not render ' .. photo.name
                end
                renders.plugin = renders.plugin + 1
                local extension = ({ TIFF = 'tif', JXL = 'jxl' })[params.exportSettings.LR_format] or 'jpg'
                return true, params.exportSettings.LR_export_destinationPathPrefix
                    .. '/' .. photo.name .. '.' .. extension
            end
            return i, rendition
        end
    end
    return session
end

loaded['lib/Formats'] = dofile('ApplePhotosPublisher.lrplugin/lib/Formats.lua')
loaded['lib/Assets'] = dofile('ApplePhotosPublisher.lrplugin/lib/Assets.lua')
loaded['lib/Albums'] = dofile('ApplePhotosPublisher.lrplugin/lib/Albums.lua')
loaded['lib/Renderer'] = dofile('ApplePhotosPublisher.lrplugin/lib/Renderer.lua')
local Formats = loaded['lib/Formats']
local Assets = loaded['lib/Assets']
local provider = dofile('ApplePhotosPublisher.lrplugin/PhotosServiceProvider.lua')

-- Whether a photo waiting for its first publish in a collection shows up in
-- getPublishedPhotos. The SDK reference does not say, so the scenarios run both ways.
local listUnpublished = false

local nextId = 0
local function newId()
    nextId = nextId + 1
    return nextId
end

local function newPhoto(name)
    local photo = { localIdentifier = newId(), name = name, properties = {} }
    function photo:getPropertyForPlugin(_, key) return self.properties[key] end
    function photo:setPropertyForPlugin(_, key, value) self.properties[key] = value end
    return photo
end

local function newRow(photo)
    local row = { photo = photo, published = false, edited = false }
    function row:getPhoto() return self.photo end
    function row:getRemoteId() return self.remoteId end
    function row:setRemoteId(value) self.remoteId = value end
    function row:setRemoteUrl(value) self.url = value end
    function row:getEditedFlag() return self.edited end
    function row:setEditedFlag(value) self.edited = value end
    return row
end

local collections = {}

local function newCollection(name, options)
    options = options or {}
    local collection = {
        localIdentifier = newId(),
        name = name,
        rows = {},
        settings = { format = options.format },
        isDefault = options.isDefault == true,
    }
    function collection:getName() return self.name end
    function collection:getRemoteId() return self.remoteId end
    function collection:getPublishedPhotos()
        local rows = {}
        for _, row in ipairs(self.rows) do
            if row.published or listUnpublished then
                table.insert(rows, row)
            end
        end
        return rows
    end
    function collection:getCollectionInfoSummary()
        return { isDefaultCollection = self.isDefault, collectionSettings = self.settings }
    end
    table.insert(collections, collection)
    return collection
end

local function newCatalog()
    collections = {}
    local lightroom = {}
    function lightroom:getPublishServices()
        return { { getChildCollections = function() return collections end } }
    end
    function lightroom:getPublishedCollectionByLocalIdentifier(localIdentifier)
        for _, collection in ipairs(collections) do
            if collection.localIdentifier == localIdentifier then return collection end
        end
        return nil
    end
    function lightroom:withWriteAccessDo(_, fn) fn() return 'executed' end
    function lightroom:withPrivateWriteAccessDo(fn) fn() return 'executed' end
    return lightroom
end

local function rowFor(collection, photo)
    for _, row in ipairs(collection.rows) do
        if row.photo == photo then return row end
    end
    return nil
end

--- Add a photo to a collection, where it waits for its first publish.
local function add(collection, photo)
    collection.catalog = catalog
    table.insert(collection.rows, newRow(photo))
end

--- Edit a photo, which flags it in every collection that has published it.
local function edit(photo)
    for _, collection in ipairs(collections) do
        local row = rowFor(collection, photo)
        if row and row.published then
            row.edited = true
        end
    end
end

--- Change a collection's format the way the edit dialog does.
local function setFormat(collection, format)
    collection.catalog = catalog
    collection.settings = { format = format }
    provider.updateCollectionSettings({}, {
        collectionSettings = collection.settings,
        publishedCollection = collection,
        name = collection.name,
    })
end

--- A rendition Lightroom would hand the provider for one photo.
local function newRendition(photo, row, started)
    local rendition = {
        photo = photo,
        row = row,
        destinationPath = '/lightroom-temp/' .. photo.name .. '-' .. newId() .. '.jpg',
    }
    function rendition:skipRender()
        assert(not started(), 'skipRender after rendering started')
        self.wasSkipped = true
    end
    function rendition:waitForRender()
        return true, self.destinationPath
    end
    function rendition:recordPublishedPhotoId(value) self.recordedId = value end
    function rendition:recordPublishedPhotoUrl(value) self.recordedUrl = value end
    function rendition:uploadFailed(message) self.failure = message end
    return rendition
end

--- Run the provider over some photos, as a publish of a collection or as a plain export.
--- @param collection table|nil The collection being published, or nil for an export
--- @param photos table Array of {photo, row}
--- @return table {published, failed, failures, lightroom, plugin} for the run
local function run(collection, photos)
    local before = { lightroom = renders.lightroom, plugin = renders.plugin }

    local renderingStarted = false
    local renditions = {}
    for _, entry in ipairs(photos) do
        table.insert(renditions, newRendition(entry.photo, entry.row, function()
            return renderingStarted
        end))
    end

    local function iterate()
        local i = 0
        return function()
            i = i + 1
            if renditions[i] then return i, renditions[i] end
            return nil
        end
    end

    local exportSession = {}
    function exportSession:countRenditions() return #renditions end
    function exportSession:renditions() return iterate() end
    function exportSession:recordRemoteCollectionId(value) collection.remoteId = value end
    function exportSession:recordRemoteCollectionUrl(value) collection.remoteUrl = value end

    local exportContext = { exportSession = exportSession }
    if collection then
        exportContext.publishedCollection = collection
        exportContext.publishedCollectionInfo = {
            name = collection.name,
            isDefaultCollection = collection.isDefault,
        }
    end
    function exportContext:configureProgress()
        local scope = {}
        function scope:isCanceled() return false end
        function scope:setCaption() end
        function scope:setPortionComplete() end
        function scope:done() end
        return scope
    end
    function exportContext:renditions()
        -- Lightroom renders everything it was not told to skip, whether or not the provider
        -- goes on to wait for it.
        if not renderingStarted then
            for _, rendition in ipairs(renditions) do
                if not rendition.wasSkipped then
                    renders.lightroom = renders.lightroom + 1
                end
            end
        end
        renderingStarted = true
        return iterate()
    end

    local cleanup = {}
    local functionContext = {}
    function functionContext:addCleanupHandler(fn) table.insert(cleanup, fn) end

    provider.processRenderedPhotos(functionContext, exportContext)
    for _, fn in ipairs(cleanup) do fn() end

    -- Lightroom's own bookkeeping for the collection it was publishing.
    local outcome = { published = 0, failed = 0, failures = {} }
    for _, rendition in ipairs(renditions) do
        if rendition.failure then
            outcome.failed = outcome.failed + 1
            table.insert(outcome.failures, rendition.failure)
        elseif rendition.recordedId then
            if rendition.row then
                rendition.row.published = true
                rendition.row.remoteId = rendition.recordedId
                rendition.row.url = rendition.recordedUrl
                rendition.row.edited = false
            end
            outcome.published = outcome.published + 1
        end
    end
    outcome.lightroom = renders.lightroom - before.lightroom
    outcome.plugin = renders.plugin - before.plugin
    return outcome
end

--- Publish a collection the way Lightroom does: every new or edited photo in it.
local function publish(collection)
    collection.catalog = catalog
    local photos = {}
    for _, row in ipairs(collection.rows) do
        if not row.published or row.edited then
            table.insert(photos, { photo = row.photo, row = row })
        end
    end
    return run(collection, photos)
end

--- Export a photo through the service, which has no collection.
local function export(photo)
    return run(nil, { { photo = photo } })
end

--- Take a photo out of a collection and publish the removal.
local function remove(collection, photo)
    local row = assert(rowFor(collection, photo))
    local acknowledged = {}
    provider.deletePhotosFromPublishedCollection({}, { row.remoteId }, function(photoID)
        table.insert(acknowledged, photoID)
    end, collection.localIdentifier)
    assert(#acknowledged == 1 and acknowledged[1] == row.remoteId, 'the removal was not acknowledged')
    for i, candidate in ipairs(collection.rows) do
        if candidate == row then
            table.remove(collection.rows, i)
            break
        end
    end
end

--- Identifiers in the order `assetList` and `albumContents` report them.
local function listOf(...)
    local identifiers = { ... }
    table.sort(identifiers)
    return table.concat(identifiers, ' ')
end

local function jpegOf(photo) return Assets.identifier(photo, 'JPEG') end
local function tiffOf(photo) return Assets.identifier(photo, 'TIFF') end
local function jxlOf(photo) return Assets.identifier(photo, 'JXL') end

-- The whole life of one photo across two JPEG albums and two TIFF albums.
local function clusteringScenario()
    resetLibrary()
    renders = { lightroom = 0, plugin = 0, sessions = {} }
    catalog = newCatalog()

    local family = newCollection('Family')
    local trips = newCollection('Trips')
    local prints = newCollection('Prints', { format = 'TIFF' })
    local portfolio = newCollection('Portfolio', { format = 'TIFF' })
    local photo = newPhoto('IMG_0001')

    -- First JPEG album: Lightroom renders it, as it always did.
    add(family, photo)
    local run = publish(family)
    assert(run.published == 1 and run.lightroom == 1 and run.plugin == 0)
    local jpeg = assert(jpegOf(photo))
    assert(tiffOf(photo) == nil)
    assert(albumContents(family.remoteId) == jpeg)

    -- Second JPEG album: nothing is rendered or imported, the asset is filed again.
    add(trips, photo)
    run = publish(trips)
    assert(run.published == 1 and run.lightroom == 0 and run.plugin == 0)
    assert(library.imports == 1, 'two JPEG albums should share one import')
    assert(albumContents(trips.remoteId) == jpeg and rowFor(trips, photo).remoteId == jpeg)

    -- First TIFF album: a separate render, by the plugin and not by Lightroom, and a second
    -- asset. The JPEG is neither reused nor replaced.
    add(prints, photo)
    run = publish(prints)
    assert(run.published == 1 and run.lightroom == 0 and run.plugin == 1)
    local tiff = assert(tiffOf(photo))
    assert(tiff ~= jpeg and jpegOf(photo) == jpeg)
    assert(library.assets[tiff].path:match('%.tif$'), library.assets[tiff].path)
    assert(albumContents(prints.remoteId) == tiff)
    assert(albumContents(family.remoteId) == jpeg, 'the JPEG album should not gain the TIFF')
    local settings = renders.sessions[#renders.sessions]
    assert(settings.LR_format == 'TIFF' and settings.LR_export_bitDepth == 16)
    assert(settings.LR_export_destinationType == 'specificFolder')
    assert(settings.LR_collisionHandling == 'rename' and settings.LR_embeddedMetadataOption == 'all')
    assert(deletedPaths[settings.LR_export_destinationPathPrefix], 'the render directory is removed')

    -- Second TIFF album: shares the TIFF.
    add(portfolio, photo)
    run = publish(portfolio)
    assert(run.published == 1 and run.lightroom == 0 and run.plugin == 0)
    assert(library.imports == 2, 'four albums in two formats should be two imports')
    assert(albumContents(portfolio.remoteId) == tiff)
    assert(assetList() == listOf(jpeg, tiff))

    -- An edit flags all four. Publishing one TIFF album renders the TIFF once, brings the
    -- other TIFF album along, and leaves the JPEG albums waiting with their asset intact.
    edit(photo)
    run = publish(prints)
    assert(run.published == 1 and run.plugin == 1 and run.lightroom == 0)
    local tiff2 = tiffOf(photo)
    assert(tiff2 ~= tiff and not library.assets[tiff], 'the old TIFF should be replaced')
    assert(albumContents(prints.remoteId) == tiff2 and albumContents(portfolio.remoteId) == tiff2)
    assert(rowFor(portfolio, photo).remoteId == tiff2 and rowFor(portfolio, photo).edited == false)
    assert(rowFor(family, photo).edited == true and rowFor(trips, photo).edited == true)
    assert(jpegOf(photo) == jpeg and library.assets[jpeg])

    -- Nothing is left to do for the other TIFF album.
    run = publish(portfolio)
    assert(run.published == 0 and run.plugin == 0)

    -- Publishing one JPEG album does the same on the JPEG side.
    run = publish(family)
    assert(run.published == 1 and run.lightroom == 1 and run.plugin == 0)
    local jpeg2 = jpegOf(photo)
    assert(jpeg2 ~= jpeg and not library.assets[jpeg])
    assert(albumContents(family.remoteId) == jpeg2 and albumContents(trips.remoteId) == jpeg2)
    assert(rowFor(trips, photo).edited == false and tiffOf(photo) == tiff2)
    assert(assetList() == listOf(jpeg2, tiff2))
    assert(library.imports == 4, 'one edit across four albums should be two more imports')

    -- Trips becomes a TIFF album. Its photo is flagged, and publishing moves it onto the
    -- TIFF that already exists. The JPEG leaves the album but survives, because Family still
    -- publishes it.
    setFormat(trips, 'TIFF')
    assert(rowFor(trips, photo).edited == true, 'changing format should flag the photo')
    assert(rowFor(family, photo).edited == false)
    run = publish(trips)
    assert(run.published == 1 and run.lightroom == 0 and run.plugin == 0)
    assert(albumContents(trips.remoteId) == tiff2, albumContents(trips.remoteId))
    assert(rowFor(trips, photo).remoteId == tiff2)
    assert(assetList() == listOf(jpeg2, tiff2) and albumContents(family.remoteId) == jpeg2)

    -- Family follows. Now nothing publishes the JPEG, so it goes.
    setFormat(family, 'TIFF')
    run = publish(family)
    assert(run.published == 1 and run.lightroom == 0 and run.plugin == 0)
    assert(assetList() == tiff2, assetList())
    assert(jpegOf(photo) == nil and tiffOf(photo) == tiff2)
    assert(albumContents(family.remoteId) == tiff2)
    assert(library.imports == 4, 'moving albums onto an existing format imports nothing')

    -- And back again. The JPEG has to be rendered, by Lightroom this time, and the TIFF
    -- stays for the three albums still publishing it.
    setFormat(family, 'JPEG')
    assert(rowFor(family, photo).edited == true)
    run = publish(family)
    assert(run.published == 1 and run.lightroom == 1 and run.plugin == 0)
    local jpeg3 = assert(jpegOf(photo))
    assert(albumContents(family.remoteId) == jpeg3, albumContents(family.remoteId))
    assert(assetList() == listOf(jpeg3, tiff2))
    for _, album in ipairs({ trips, prints, portfolio }) do
        assert(albumContents(album.remoteId) == tiff2)
    end

    -- Removing it from one TIFF album only empties that album.
    remove(prints, photo)
    assert(albumContents(prints.remoteId) == '' and library.assets[tiff2])

    -- Removing it from the only JPEG album deletes the JPEG, whatever the TIFF albums hold.
    remove(family, photo)
    assert(assetList() == tiff2 and jpegOf(photo) == nil and tiffOf(photo) == tiff2)

    -- Deleting a TIFF album keeps the asset while another one publishes it.
    provider.deletePublishedCollection({}, {
        remoteId = portfolio.remoteId,
        photoIds = { tiff2 },
        publishedCollection = portfolio,
    })
    assert(library.albums[portfolio.remoteId] == nil and library.assets[tiff2])
    portfolio.rows = {}

    -- The last TIFF album takes the asset with it.
    remove(trips, photo)
    assert(assetList() == '' and tiffOf(photo) == nil)
    assert(photo.properties[Assets.PROP_SYNC_DATE] == nil)
end

listUnpublished = false
clusteringScenario()
listUnpublished = true
clusteringScenario()
print('PASS: one render and one asset per format, shared by every album in it')

-- The only album a photo is in changes format. The new asset takes over from the old one, so
-- what the user did with it in Photos survives the change, and the old one is deleted.
for _, listed in ipairs({ false, true }) do
    listUnpublished = listed
    resetLibrary()
    renders = { lightroom = 0, plugin = 0, sessions = {} }
    catalog = newCatalog()
    local solo = newCollection('Solo')
    local photo = newPhoto('IMG_0002')
    add(solo, photo)
    publish(solo)
    local jpeg = jpegOf(photo)
    library.assets[jpeg].favorite = true
    library.albums['hand-made/L0/040'] = { [jpeg] = true }

    setFormat(solo, 'TIFF')
    local run = publish(solo)
    assert(run.published == 1 and run.plugin == 1 and run.lightroom == 0)
    local tiff = assert(tiffOf(photo))
    assert(assetList() == tiff and jpegOf(photo) == nil)
    assert(library.assets[tiff].favorite == true, 'favorite status should follow the photo')
    assert(albumContents('hand-made/L0/040') == tiff, 'and so should an album it was filed in by hand')
    assert(albumContents(solo.remoteId) == tiff)
    assert(rowFor(solo, photo).edited == false)

    -- Saving the settings again without changing anything is not a reason to republish.
    setFormat(solo, 'TIFF')
    assert(rowFor(solo, photo).edited == false)
    assert(publish(solo).published == 0)
end
print('PASS: changing the only album\'s format replaces the asset and keeps its place in Photos')

-- The built-in collection has no album but does have a format, and shares like any other.
listUnpublished = false
resetLibrary()
renders = { lightroom = 0, plugin = 0, sessions = {} }
catalog = newCatalog()
local default = newCollection('Apple Photos', { isDefault = true })
local keepers = newCollection('Keepers')
local masters = newCollection('Masters', { format = 'TIFF' })
local unfiled = newPhoto('IMG_0003')
add(default, unfiled)
add(keepers, unfiled)
add(masters, unfiled)
assert(publish(default).lightroom == 1)
local unfiledJpeg = jpegOf(unfiled)
assert(default.remoteId == nil, 'the default collection gets no album')
local keepersRun = publish(keepers)
assert(keepersRun.lightroom == 0 and albumContents(keepers.remoteId) == unfiledJpeg)
assert(publish(masters).plugin == 1)
-- Out of the JPEG album: the default collection still publishes the JPEG, so it stays.
remove(keepers, unfiled)
assert(library.assets[unfiledJpeg] and albumContents(keepers.remoteId) == '')
-- Out of the default collection too: only the TIFF album is left, and it has its own asset.
remove(default, unfiled)
assert(assetList() == tiffOf(unfiled) and jpegOf(unfiled) == nil)
print('PASS: the default collection shares its format\'s asset and keeps it alive')

-- Three formats are three assets. JPEG XL is rendered by the plugin like TIFF, shares among
-- its own albums, and has nothing to do with the JPEG beyond the name.
resetLibrary()
renders = { lightroom = 0, plugin = 0, sessions = {} }
catalog = newCatalog()
local threeJpeg = newCollection('Family')
local threeJxl = newCollection('Modern', { format = 'JXL' })
local threeJxlToo = newCollection('Sharing', { format = 'JXL' })
local threeTiff = newCollection('Prints', { format = 'TIFF' })
local trio = newPhoto('IMG_0008')
for _, album in ipairs({ threeJpeg, threeJxl, threeJxlToo, threeTiff }) do
    add(album, trio)
end
assert(publish(threeJpeg).lightroom == 1)
local trioRun = publish(threeJxl)
assert(trioRun.published == 1 and trioRun.lightroom == 0 and trioRun.plugin == 1)
local jxlSession = renders.sessions[#renders.sessions]
assert(jxlSession.LR_format == 'JXL' and jxlSession.LR_jxl_quality == 1)
assert(jxlSession.LR_jxl_losslessQuality == false and jxlSession.LR_export_bitDepth == 16)
assert(library.assets[jxlOf(trio)].path:match('%.jxl$'))
trioRun = publish(threeJxlToo)
assert(trioRun.published == 1 and trioRun.lightroom == 0 and trioRun.plugin == 0,
    'the second JPEG XL album should share the first one\'s asset')
assert(publish(threeTiff).plugin == 1)
assert(library.imports == 3, 'four albums in three formats should be three imports')
assert(assetList() == listOf(jpegOf(trio), jxlOf(trio), tiffOf(trio)))
assert(albumContents(threeJpeg.remoteId) == jpegOf(trio))
assert(albumContents(threeJxl.remoteId) == jxlOf(trio) and albumContents(threeJxlToo.remoteId) == jxlOf(trio))
assert(albumContents(threeTiff.remoteId) == tiffOf(trio))

-- An edit, published from one JPEG XL album: one render, both JPEG XL albums updated, the
-- JPEG and the TIFF untouched and their albums still waiting.
edit(trio)
local trioJpeg, trioJxl, trioTiff = jpegOf(trio), jxlOf(trio), tiffOf(trio)
trioRun = publish(threeJxlToo)
assert(trioRun.published == 1 and trioRun.plugin == 1 and trioRun.lightroom == 0)
assert(jxlOf(trio) ~= trioJxl and not library.assets[trioJxl])
assert(jpegOf(trio) == trioJpeg and tiffOf(trio) == trioTiff)
assert(albumContents(threeJxl.remoteId) == jxlOf(trio) and rowFor(threeJxl, trio).edited == false)
assert(rowFor(threeJpeg, trio).edited == true and rowFor(threeTiff, trio).edited == true)

-- The JPEG album becomes a JPEG XL album: it joins the existing asset and the JPEG goes.
setFormat(threeJpeg, 'JXL')
trioRun = publish(threeJpeg)
assert(trioRun.published == 1 and trioRun.lightroom == 0 and trioRun.plugin == 0)
assert(jpegOf(trio) == nil and assetList() == listOf(jxlOf(trio), tiffOf(trio)))
assert(albumContents(threeJpeg.remoteId) == jxlOf(trio))
print('PASS: JPEG XL is a format of its own, rendered once and shared by its albums')

-- Export has no collection, so it renders what the service renders. It replaces the photo's
-- JPEG, brings the JPEG albums along and leaves the TIFF alone.
resetLibrary()
renders = { lightroom = 0, plugin = 0, sessions = {} }
catalog = newCatalog()
local exportFamily = newCollection('Family')
local exportPrints = newCollection('Prints', { format = 'TIFF' })
local exported = newPhoto('IMG_0007')
add(exportFamily, exported)
add(exportPrints, exported)
publish(exportFamily)
publish(exportPrints)
local exportedTiff = tiffOf(exported)
local exportRun = export(exported)
assert(exportRun.published == 1 and exportRun.lightroom == 1 and exportRun.plugin == 0)
assert(tiffOf(exported) == exportedTiff)
assert(assetList() == listOf(jpegOf(exported), exportedTiff))
assert(albumContents(exportFamily.remoteId) == jpegOf(exported))
assert(rowFor(exportFamily, exported).remoteId == jpegOf(exported))
assert(albumContents(exportPrints.remoteId) == exportedTiff)
print('PASS: an export is a JPEG, and only the JPEG albums follow it')

-- A TIFF deleted in Photos behind the plugin's back. The skipped render leaves nothing to
-- import, so the photo fails once, the TIFF is forgotten and the JPEG is left alone.
resetLibrary()
renders = { lightroom = 0, plugin = 0, sessions = {} }
catalog = newCatalog()
local jpegAlbum = newCollection('Family')
local tiffAlbum = newCollection('Prints', { format = 'TIFF' })
local secondTiffAlbum = newCollection('Portfolio', { format = 'TIFF' })
local missing = newPhoto('IMG_0004')
add(jpegAlbum, missing)
add(tiffAlbum, missing)
publish(jpegAlbum)
publish(tiffAlbum)
local survivingJpeg = jpegOf(missing)
library.assets[tiffOf(missing)] = nil
add(secondTiffAlbum, missing)
local missingRun = publish(secondTiffAlbum)
assert(missingRun.failed == 1 and missingRun.published == 0)
assert(tiffOf(missing) == nil and jpegOf(missing) == survivingJpeg)
missingRun = publish(secondTiffAlbum)
assert(missingRun.published == 1 and missingRun.plugin == 1 and tiffOf(missing) ~= nil)
print('PASS: a deleted TIFF is forgotten without disturbing the JPEG')

-- A photo the plugin's own session cannot render is reported on that photo, and the rest of
-- the batch still goes through.
resetLibrary()
renders = { lightroom = 0, plugin = 0, sessions = {} }
catalog = newCatalog()
local batch = newCollection('Prints', { format = 'TIFF' })
local good = newPhoto('IMG_0005')
local bad = newPhoto('IMG_0006')
add(batch, good)
add(batch, bad)
failingRenders = { IMG_0006 = true }
local batchRun = publish(batch)
assert(batchRun.published == 1 and batchRun.failed == 1)
assert(batchRun.failures[1] == 'Lightroom could not render IMG_0006')
assert(tiffOf(good) and not tiffOf(bad))
failingRenders = {}
batchRun = publish(batch)
assert(batchRun.published == 1 and batchRun.plugin == 1 and tiffOf(bad))
print('PASS: a failed render in another format fails that photo alone')

-- The edit dialog offers the formats and shows JPEG for a collection that has no setting.
local factory = setmetatable({}, {
    __index = function(_, kind)
        return function(_, arguments) return { kind = kind, arguments = arguments } end
    end,
})
local dialogSettings = {}
local view = provider.viewForCollectionSettings(factory, {}, { collectionSettings = dialogSettings })
assert(dialogSettings.format == 'JPEG')
assert(view.kind == 'group_box' and view.arguments.bind_to_object == dialogSettings)
local menu = view.arguments[1].arguments[1].arguments[2]
assert(menu.kind == 'popup_menu' and menu.arguments.value.boundTo == Formats.SETTING)
assert(#menu.arguments.items == 3)
assert(menu.arguments.items[1].value == 'JPEG' and menu.arguments.items[2].value == 'JXL')
assert(menu.arguments.items[2].title == 'JPEG XL' and menu.arguments.items[3].value == 'TIFF')
dialogSettings = { format = 'TIFF' }
provider.viewForCollectionSettings(factory, {}, { collectionSettings = dialogSettings })
assert(dialogSettings.format == 'TIFF')

-- The service itself still only ever renders JPEG.
local exportSettings = { LR_format = 'TIFF', LR_jpeg_quality = 0.5 }
provider.updateExportSettings(exportSettings)
assert(exportSettings.LR_format == 'JPEG' and exportSettings.LR_jpeg_quality == 1)
assert(exportSettings.LR_export_colorSpace == 'sRGB')
print('PASS: collection settings view and the service\'s own render settings')
