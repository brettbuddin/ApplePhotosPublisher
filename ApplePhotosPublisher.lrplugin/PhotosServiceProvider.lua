--[[
    Photos Publish Service Provider

    Publish service provider for Apple Photos. Appears in Lightroom's
    Publish Services panel with change tracking and republish support.
]]

local LrApplication = import 'LrApplication'
local LrDialogs = import 'LrDialogs'
local LrErrors = import 'LrErrors'
local LrTasks = import 'LrTasks'

local pluginLoad = require 'PluginModuleLoader'
local Albums = pluginLoad 'lib/Albums'
local Importer = pluginLoad 'lib/Importer'
local Shell = pluginLoad 'lib/Shell'
local Time = pluginLoad 'lib/Time'
local logger = pluginLoad 'lib/Logger'

--- Plugin metadata key for the Apple Photos localIdentifier.
local PROP_LOCAL_IDENTIFIER = 'photosLocalIdentifier'
--- Plugin metadata key for the last sync timestamp.
local PROP_SYNC_DATE = 'photosSyncDate'

--- Title of the dialog shown when Photos library access is missing.
local AUTHORIZATION_DIALOG_TITLE = 'Apple Photos Publisher for Lightroom Classic needs Full Access to Photos'

--- Tell the user that Photos library access is missing and how to fix it.
--- The importer's message names the current setting (Limited Access, no
--- access, or restricted) and the System Settings path to change it.
--- @param result table An error result from the importer
local function showAuthorizationError(result)
    LrDialogs.message(AUTHORIZATION_DIALOG_TITLE, result.errorMessage, 'critical')
end

--- Fail a collection lifecycle callback so Lightroom offers to revert the change.
---
--- The SDK responds to an error here by asking whether to undo the local change or keep it
--- while warning that the service was not updated. That is the right question for both a
--- genuine failure and a refused confirmation dialog, so the difference is only in the
--- wording, which the helper already supplies.
---
--- @param result table A result table from the helper
--- @param what string What could not be done, for the fallback message
local function failCollectionOperation(result, what)
    if Importer.isAuthorizationError(result) then
        showAuthorizationError(result)
    end
    local message = result.errorMessage or result.errorCode or ('Could not ' .. what)
    if Importer.isUserCancelled(result) then
        logger:info('User cancelled: ' .. what)
    else
        logger:error('Failed to ' .. what .. ': ' .. message)
    end
    error(message, 0)
end

--- Require a successful helper result, or fail the callback.
local function requireSuccess(result, what)
    if result.status ~= Importer.STATUS_SUCCESS then
        failCollectionOperation(result, what)
    end
end

--- Lightroom publish/export service provider table.
--- @class PhotosServiceProvider
local provider = {}

--- Render to a temporary location; Lightroom manages cleanup.
provider.canExportToTemporaryLocation = true
--- Only incremental (change-tracked) publishing is supported.
provider.supportsIncrementalPublish = 'only'
--- Hide irrelevant export dialog sections (location, naming, post-processing).
provider.hideSections = {
    'exportLocation',
    'fileNaming',
    'postProcessing',
}
--- Only JPEG output is supported.
provider.allowFileFormats = { 'JPEG' }
--- Allow any color space (nil removes the restriction).
provider.allowColorSpaces = nil

--- Called when the publish/export dialog opens.
--- Sets default export properties for Apple Photos output.
--- @param propertyTable table Lightroom export property table
function provider.startDialog(propertyTable)
    propertyTable.LR_jpeg_quality = 1
    propertyTable.LR_size_doConstrain = false
    propertyTable.LR_outputSharpeningOn = false
    propertyTable.LR_includeFaceTagsInIptc = true
    propertyTable.LR_metadata_keywordOptions = 'flat'
    propertyTable.LR_embeddedMetadataOption = 'all'
    propertyTable.LR_removeLocationMetadata = false
    propertyTable.LR_useWatermark = false
end

--- Returns UI sections displayed at the top of the publish/export dialog.
--- Shows a single "Apple Photos" section with a description of the service.
--- @param f table Lightroom view factory
--- @param propertyTable table Lightroom export property table
--- @return table Array of dialog section descriptors
function provider.sectionsForTopOfDialog(f, propertyTable)
    return {
        {
            title = 'Apple Photos',
            f:row {
                f:static_text {
                    title = 'Photos will be published to Apple Photos.\n\nCollections you add become albums. The built-in Apple Photos collection files nothing: it just gets photos into your library. Previously published photos will be replaced and their album memberships restored.',
                    fill_horizontal = 1,
                },
            },
        },
    }
end

--- Configures collection behavior for the publish service.
--- Creates a non-deletable default collection named "Apple Photos". Users can add
--- collections, which mirror to albums in Photos.
--- @param publishSettings table Current publish settings
--- @return table Collection behavior configuration
function provider.getCollectionBehaviorInfo(publishSettings)
    return {
        defaultCollectionName = 'Apple Photos',
        defaultCollectionCanBeDeleted = false,
        canAddCollection = true,
        -- Collection sets are not offered. They would mirror to Photos folders, and
        -- deleting a folder in Photos is recursive: it takes every album inside with it,
        -- including one the user had dragged in that belongs to a collection still being
        -- published. Albums all sit at the top level instead.
        maxCollectionSetDepth = 0,
    }
end

--- Photos calls these albums, so the panel's menus should too.
provider.titleForPublishedCollection = 'Album'
provider.titleForPublishedCollection_standalone = 'Album'
provider.titleForPublishedSmartCollection = 'Smart Album'
provider.titleForPublishedSmartCollection_standalone = 'Smart Album'
provider.titleForGoToPublishedCollection = 'Show in Photos'

--- Declares which metadata changes should mark a photo for republish.
--- Triggers on: title, caption, keywords, GPS, date created, rating.
--- All other metadata fields are ignored.
--- @param publishSettings table Current publish settings
--- @return table Map of metadata field names to boolean
function provider.metadataThatTriggersRepublish(publishSettings)
    return {
        default = false,
        title = true,
        caption = true,
        keywords = true,
        gps = true,
        dateCreated = true,
        rating = true,
    }
end

--- Batch-imports rendered photos into Apple Photos.
--- For each successful import, stores the Photos identifier and sync timestamp
--- as plugin metadata, records the published photo ID/URL on the rendition,
--- and collects previous identifiers for later cleanup.
---
--- The batch carries its album, so the helper creates the album, imports the photos and
--- sets their membership within the single launch publishing already costs.
---
--- @param progressScope LrProgressScope Active progress scope for cancellation and status
--- @param renditionPhotos table Array of {rendition, photo, path, previousIdentifier, reuseIdentifier}
--- @param catalog LrCatalog The active Lightroom catalog
--- @param context table {album, publishService, collection, localCollectionId}
--- @return table Array of old Apple Photos identifiers that were replaced
--- @return table|nil The album the helper resolved, as {identifier, created}
local function importPhotoBatch(progressScope, renditionPhotos, catalog, context)
    local batchPhotos = {}
    for _, rp in ipairs(renditionPhotos) do
        table.insert(batchPhotos, {
            path = rp.path,
            previousIdentifier = rp.previousIdentifier,
            reuseIdentifier = rp.reuseIdentifier,
        })
    end

    if progressScope:isCanceled() then
        return {}, nil
    end

    progressScope:setCaption('Importing to Apple Photos...')
    logger:info('Starting batch import of ' .. #batchPhotos .. ' photos')
    local batchResult = Importer.importPhotos(batchPhotos, context.album)

    local oldIdentifiers = {}

    if batchResult.status == Importer.STATUS_SUCCESS then
        for _, rp in ipairs(renditionPhotos) do
            local result = batchResult.results[rp.path]

            if result and result.status == 'success' then
                rp.rendition:recordPublishedPhotoId(result.localIdentifier)
                rp.rendition:recordPublishedPhotoUrl(result.url)

                -- Plugin metadata goes through the private gate, and only when something
                -- actually changed.
                --
                -- Writing to a photo marks it changed for every collection publishing it,
                -- not just this one. The collection being published clears that with
                -- recordPublishedPhotoId above, but the others cannot, so they were left
                -- showing photos as needing a republish. An ordinary write also lands on the
                -- undo stack, which defeats recordPublishedPhotoId for this collection too.
                -- photosSyncDate was a fresh timestamp every run, so both happened on every
                -- publish rather than settling.
                local stored = rp.photo:getPropertyForPlugin(_PLUGIN, PROP_LOCAL_IDENTIFIER)
                if stored ~= result.localIdentifier then
                    catalog:withPrivateWriteAccessDo(function()
                        rp.photo:setPropertyForPlugin(_PLUGIN, PROP_LOCAL_IDENTIFIER, result.localIdentifier)
                        rp.photo:setPropertyForPlugin(_PLUGIN, PROP_SYNC_DATE, Time.nowISO8601())
                    end)
                end

                if rp.previousIdentifier and rp.previousIdentifier ~= ''
                    and rp.previousIdentifier ~= result.localIdentifier then
                    table.insert(oldIdentifiers, rp.previousIdentifier)
                    -- Other collections still name the asset we just replaced. Point them at
                    -- the new one before it is deleted out from under them.
                    --
                    -- Guarded because this is bookkeeping, and letting it abort the publish
                    -- costs far more than getting it wrong: the run would stop before
                    -- deleting the replaced assets, leaving duplicates in Photos.
                    --
                    -- LrTasks.pcall rather than Lua's own: the write gate inside yields, and
                    -- yielding across a plain pcall is not allowed.
                    local ok, err = LrTasks.pcall(Albums.repointSiblings, catalog,
                        context.publishService, rp.previousIdentifier, result.localIdentifier,
                        result.url, context.localCollectionId)
                    if not ok then
                        logger:error('Could not update other collections for '
                            .. result.localIdentifier .. ': ' .. tostring(err))
                    end
                end

                if result.reused then
                    logger:info('Reused existing asset -> ' .. result.localIdentifier)
                else
                    logger:info('Published photo -> ' .. result.localIdentifier)
                end
            else
                local errorMsg = 'Unknown error'
                if result then
                    errorMsg = result.errorMessage or result.errorCode or 'Unknown error'
                end
                rp.rendition:uploadFailed(errorMsg)
                logger:error('Failed to import photo: ' .. errorMsg)
            end
        end
    else
        local errorMsg = batchResult.errorMessage or batchResult.errorCode or 'Batch import failed'
        logger:error('Batch import failed: ' .. errorMsg)
        if Importer.isAuthorizationError(batchResult) then
            showAuthorizationError(batchResult)
        end
        for _, rp in ipairs(renditionPhotos) do
            rp.rendition:uploadFailed(errorMsg)
        end
    end

    return oldIdentifiers, batchResult.album
end

--- Deletes previously-published photo versions from Apple Photos.
--- Called after a batch import to clean up photos that were replaced.
--- @param progressScope LrProgressScope Active progress scope for status updates
--- @param oldIdentifiers table Array of Apple Photos local identifiers to delete
local function deleteOldVersions(progressScope, oldIdentifiers)
    if #oldIdentifiers == 0 then
        return
    end

    progressScope:setCaption('Cleaning up old versions...')
    logger:info('Deleting ' .. #oldIdentifiers .. ' old photo versions')
    local deleteResult = Importer.deletePhotos(oldIdentifiers)
    if deleteResult.status == Importer.STATUS_SUCCESS then
        logger:info('Deleted ' .. deleteResult.deletedCount .. ' old versions')
    else
        logger:error('Failed to delete old versions: ' ..
            (deleteResult.errorMessage or deleteResult.errorCode or 'Unknown error'))
    end
end

--- Main publish entry point called by Lightroom after photos are rendered.
---
--- Runs two passes over the renditions. The first decides which photos can keep the asset
--- they already have, because `skipRender` has to be called before rendering starts. The
--- second collects the rendered files and hands the batch, with its album, to the helper.
---
--- @param functionContext LrFunctionContext Lightroom function context for cleanup
--- @param exportContext LrExportContext Context providing renditions and progress
function provider.processRenderedPhotos(functionContext, exportContext)
    local nPhotos = exportContext.exportSession:countRenditions()
    local progressScope = exportContext:configureProgress({
        title = string.format('Publishing %d photos to Apple Photos', nPhotos),
    })

    local catalog = LrApplication.activeCatalog()
    local publishService = exportContext.publishService
    local collection = exportContext.publishedCollection
    local info = exportContext.publishedCollectionInfo
    local localCollectionId = collection and collection.localIdentifier

    -- Decide reuse before rendering begins, since skipRender is only honored until then.
    -- A photo that is merely joining another collection keeps its asset: replacing it would
    -- leave the collections already publishing it pointing at something deleted.
    local reuseByPhoto = {}
    if publishService then
        for _, rendition in exportContext.exportSession:renditions() do
            if not rendition.publishedPhotoId then
                local recorded = rendition.photo:getPropertyForPlugin(_PLUGIN, PROP_LOCAL_IDENTIFIER)
                local reusable = Albums.reusableIdentifier(publishService, recorded, localCollectionId)
                if reusable then
                    reuseByPhoto[rendition.photo.localIdentifier] = reusable
                    rendition:skipRender()
                end
            end
        end
    end

    -- Render Exports
    local renditions = {}
    for i, rendition in exportContext:renditions({ stopIfCanceled = true }) do
        if progressScope:isCanceled() then
            break
        end
        progressScope:setPortionComplete(i - 1, nPhotos)

        local reuseIdentifier = reuseByPhoto[rendition.photo.localIdentifier]
        if reuseIdentifier then
            -- Nothing was rendered, so there is no file; the helper files the asset instead.
            table.insert(renditions, {
                rendition = rendition,
                photo = rendition.photo,
                path = rendition.destinationPath,
                reuseIdentifier = reuseIdentifier,
            })
        else
            local success, path = rendition:waitForRender()

            if success then
                local previousIdentifier = rendition.publishedPhotoId
                if not previousIdentifier or previousIdentifier == '' then
                    previousIdentifier = rendition.photo:getPropertyForPlugin(_PLUGIN, PROP_LOCAL_IDENTIFIER)
                end

                table.insert(renditions, {
                    rendition = rendition,
                    photo = rendition.photo,
                    path = path,
                    previousIdentifier = previousIdentifier,
                })
            else
                rendition:uploadFailed(path)
            end
        end
    end
    if #renditions == 0 or progressScope:isCanceled() then
        return
    end

    -- Import into Apple Photos
    local oldIdentifiers, album = importPhotoBatch(progressScope, renditions, catalog, {
        album = collection and Albums.albumTarget(collection) or nil,
        publishService = publishService,
        collection = collection,
        localCollectionId = localCollectionId,
    })

    -- Record where Photos put things, so the next publish finds the same album rather than
    -- building another one beside it.
    if album and album.identifier then
        exportContext.exportSession:recordRemoteCollectionId(album.identifier)
        local uuid = Albums.albumUuid(album.identifier)
        if uuid then
            exportContext.exportSession:recordRemoteCollectionUrl('photos:albums?albumUuid=' .. uuid)
        end
        if album.created then
            logger:info('Created album for ' .. info.name .. ' -> ' .. album.identifier)
        else
            logger:info('Using existing album for ' .. info.name .. ' -> ' .. album.identifier)
        end
        if #oldIdentifiers > 0 then
            logger:info('Replaced ' .. #oldIdentifiers .. ' assets; sibling lookup '
                .. Albums.describeLastScan())
        end
    end

    deleteOldVersions(progressScope, oldIdentifiers)

    progressScope:done()
end

--- Called when the user removes photos from a published collection.
---
--- Removal is partitioned rather than applied uniformly. A photo still published by another
--- collection only leaves this collection's album, which is silent. A photo nothing else
--- publishes has its asset deleted, which removes it from every album anyway, so there is no
--- membership step and no way for a refused deletion to leave it stripped from an album it is
--- still published in.
---
--- @param publishSettings table Current publish settings
--- @param photoIDs table Array of Apple Photos local identifiers
--- @param deletedCallback function Called with each photoID once it is dealt with
--- @param localCollectionID number Lightroom local identifier for the published collection
function provider.deletePhotosFromPublishedCollection(publishSettings, photoIDs, deletedCallback,
                                                      localCollectionID)
    if #photoIDs == 0 then
        return
    end

    local catalog = LrApplication.activeCatalog()
    local collection = catalog:getPublishedCollectionByLocalIdentifier(localCollectionID)
    local publishService = collection and collection:getService()

    -- The default collection has no album, whatever identifier it may still carry from
    -- before it stopped mirroring. Reading that stale identifier here would try to remove
    -- photos from an album nothing manages, and fail outright once it is deleted in Photos.
    local albumIdentifier = nil
    if collection and not Albums.isDefaultCollection(collection) then
        albumIdentifier = collection:getRemoteId()
    end

    local orphaned = {}
    local stillPublished = {}
    for _, photoID in ipairs(photoIDs) do
        if publishService
            and Albums.isPublishedElsewhere(publishService, photoID, localCollectionID) then
            table.insert(stillPublished, photoID)
        else
            table.insert(orphaned, photoID)
        end
    end
    logger:info('Removing ' .. #photoIDs .. ' photos: ' .. #orphaned .. ' orphaned, '
        .. #stillPublished .. ' published elsewhere')

    -- Photos that live on elsewhere only leave this album.
    if #stillPublished > 0 and albumIdentifier and albumIdentifier ~= '' then
        local removeResult = Importer.removeFromAlbum(albumIdentifier, stillPublished)
        if removeResult.status ~= Importer.STATUS_SUCCESS then
            local message = removeResult.errorMessage or removeResult.errorCode or 'Remove failed'
            logger:error('Failed to remove photos from the album: ' .. message)
            if Importer.isAuthorizationError(removeResult) then
                showAuthorizationError(removeResult)
                return
            end
            LrErrors.throwUserError(message)
        end
        for _, photoID in ipairs(stillPublished) do
            deletedCallback(photoID)
        end
    elseif #stillPublished > 0 then
        -- No album to remove them from, so there is nothing to do but acknowledge.
        for _, photoID in ipairs(stillPublished) do
            deletedCallback(photoID)
        end
    end

    if #orphaned == 0 then
        return
    end

    local deleteResult = Importer.deletePhotos(orphaned)
    if deleteResult.status == Importer.STATUS_SUCCESS then
        local photoIDSet = {}
        for _, id in ipairs(orphaned) do
            photoIDSet[id] = true
        end

        if collection then
            local publishedPhotos = collection:getPublishedPhotos()
            catalog:withPrivateWriteAccessDo(function()
                for _, publishedPhoto in ipairs(publishedPhotos) do
                    if photoIDSet[publishedPhoto:getRemoteId()] then
                        local photo = publishedPhoto:getPhoto()
                        photo:setPropertyForPlugin(_PLUGIN, PROP_LOCAL_IDENTIFIER, nil)
                        photo:setPropertyForPlugin(_PLUGIN, PROP_SYNC_DATE, nil)
                    end
                end
            end)
        end

        for _, photoID in ipairs(orphaned) do
            deletedCallback(photoID)
        end
        logger:info('Deleted ' .. deleteResult.deletedCount .. ' photos')
    else
        local errorMsg = deleteResult.errorMessage or deleteResult.errorCode or 'Delete failed'
        logger:error('Failed to delete photos: ' .. errorMsg)
        if Importer.isAuthorizationError(deleteResult) or Importer.isUserCancelled(deleteResult) then
            -- Nothing was passed to deletedCallback for these, so Lightroom keeps them in
            -- the collection for a retry once access is granted or the user agrees.
            if Importer.isAuthorizationError(deleteResult) then
                showAuthorizationError(deleteResult)
            end
            return
        end
        LrErrors.throwUserError(errorMsg)
    end
end

--- Called when the user renames a published collection.
--- @param publishSettings table Current publish settings
--- @param info table Lifecycle info, including remoteId and the new name
function provider.renamePublishedCollection(publishSettings, info)
    if not info.remoteId or info.remoteId == '' then
        -- Never published, so Photos has nothing under this name yet.
        return
    end

    requireSuccess(Importer.renameAlbum(info.remoteId, info.name),
        'rename the album in Apple Photos')
    logger:info('Renamed Photos album to ' .. info.name)
end

--- Called when the user deletes a published collection.
---
--- Only the album goes; its photos stay in the library unless nothing else publishes them.
---
--- @param publishSettings table Current publish settings
--- @param info table Lifecycle info, including remoteId
function provider.deletePublishedCollection(publishSettings, info)
    if not info.remoteId or info.remoteId == '' then
        return
    end

    -- Lightroom hands over the photos it published through this collection. The field is
    -- undocumented but the Flickr sample relies on it, so use it when it is there and settle
    -- for removing only the container when it is not.
    if info.photoIds and #info.photoIds > 0 then
        local publishService = info.publishService
        local localId = info.publishedCollection and info.publishedCollection.localIdentifier
        local orphaned = {}
        for _, photoID in ipairs(info.photoIds) do
            if not (publishService
                and Albums.isPublishedElsewhere(publishService, photoID, localId)) then
                table.insert(orphaned, photoID)
            end
        end
        if #orphaned > 0 then
            logger:info('Deleting ' .. #orphaned .. ' photos with the collection')
            requireSuccess(Importer.deletePhotos(orphaned), 'delete the photos from Apple Photos')
        end
    end

    requireSuccess(Importer.deleteAlbum(info.remoteId),
        'delete the album from Apple Photos')
    logger:info('Deleted Photos album ' .. info.remoteId)
end

--- Called for the "Show in Photos" context-menu item.
--- @param publishSettings table Current publish settings
--- @param info table Lifecycle info, including remoteId
function provider.goToPublishedCollection(publishSettings, info)
    if info.isDefaultCollection then
        LrDialogs.message('No album for this collection',
            'Publishing here puts photos in your Photos library without filing them in an '
            .. 'album. Add them to a collection to get an album.', 'info')
        return
    end

    local uuid = Albums.albumUuid(info.remoteId)
    if not uuid then
        LrDialogs.message('Not published yet',
            'Publish this album once and Apple Photos will have something to show.', 'info')
        return
    end
    Shell.openUrl('photos:albums?albumUuid=' .. uuid)
end

--- Validates a collection name before Lightroom accepts it.
--- Only cheap checks belong here; anything Photos might reject is reported when we try.
--- @param proposedName string The name as typed
--- @return boolean Whether the name is acceptable
--- @return string|nil Why it is not
function provider.validatePublishedCollectionName(proposedName)
    if not proposedName or proposedName:match('^%s*$') then
        return false, 'An album needs a name.'
    end
    return true
end

return provider
