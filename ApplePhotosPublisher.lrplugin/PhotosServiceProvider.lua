--[[
    Photos Publish Service Provider

    Publish service provider for Apple Photos. Appears in Lightroom's
    Publish Services panel with change tracking and republish support.
]]

local LrApplication = import 'LrApplication'

local pluginLoad = require 'PluginModuleLoader'
local Importer = pluginLoad 'lib/Importer'
local Time = pluginLoad 'lib/Time'
local logger = pluginLoad 'lib/Logger'

--- Plugin metadata key for the Apple Photos localIdentifier.
local PROP_LOCAL_IDENTIFIER = 'photosLocalIdentifier'
--- Plugin metadata key for the last sync timestamp.
local PROP_SYNC_DATE = 'photosSyncDate'

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
                    title = 'Photos will be published to Apple Photos.\n\nPreviously published photos will be replaced and their album memberships restored.',
                    fill_horizontal = 1,
                },
            },
        },
    }
end

--- Configures collection behavior for the publish service.
--- Creates a non-deletable default collection named "Apple Photos".
--- Users can add collections but not collection sets (depth 0).
--- @param publishSettings table Current publish settings
--- @return table Collection behavior configuration
function provider.getCollectionBehaviorInfo(publishSettings)
    return {
        defaultCollectionName = 'Apple Photos',
        defaultCollectionCanBeDeleted = false,
        canAddCollection = true,
        maxCollectionSetDepth = 0,
    }
end

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
--- @param progressScope LrProgressScope Active progress scope for cancellation and status
--- @param renditionPhotos table Array of {rendition, photo, path, previousIdentifier}
--- @param catalog LrCatalog The active Lightroom catalog
--- @return table Array of old Apple Photos identifiers that were replaced
local function importPhotoBatch(progressScope, renditionPhotos, catalog)
    local batchPhotos = {}
    for _, rp in ipairs(renditionPhotos) do
        table.insert(batchPhotos, {
            path = rp.path,
            previousIdentifier = rp.previousIdentifier,
        })
    end

    if progressScope:isCanceled() then
        return {}
    end

    progressScope:setCaption('Importing to Apple Photos...')
    logger:info('Starting batch import of ' .. #batchPhotos .. ' photos')
    local batchResult = Importer.importPhotos(batchPhotos)

    local oldIdentifiers = {}

    if batchResult.status == Importer.STATUS_SUCCESS then
        for _, rp in ipairs(renditionPhotos) do
            local result = batchResult.results[rp.path]

            if result and result.status == 'success' then
                catalog:withWriteAccessDo('Store Photos identifier', function()
                    rp.photo:setPropertyForPlugin(_PLUGIN, PROP_LOCAL_IDENTIFIER, result.localIdentifier)
                    rp.photo:setPropertyForPlugin(_PLUGIN, PROP_SYNC_DATE, Time.nowISO8601())
                end)

                rp.rendition:recordPublishedPhotoId(result.localIdentifier)
                rp.rendition:recordPublishedPhotoUrl(result.url)

                if rp.previousIdentifier and rp.previousIdentifier ~= '' then
                    table.insert(oldIdentifiers, rp.previousIdentifier)
                end

                logger:info('Published photo -> ' .. result.localIdentifier)
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
        for _, rp in ipairs(renditionPhotos) do
            rp.rendition:uploadFailed(errorMsg)
        end
    end

    return oldIdentifiers
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
--- Waits for each rendition to finish rendering, collects successful results
--- with their file paths and previous identifiers, batch-imports them into
--- Apple Photos, then deletes any old versions that were replaced.
--- @param functionContext LrFunctionContext Lightroom function context for cleanup
--- @param exportContext LrExportContext Context providing renditions and progress
function provider.processRenderedPhotos(functionContext, exportContext)
    local nPhotos = exportContext.exportSession:countRenditions()
    local progressScope = exportContext:configureProgress({
        title = string.format('Publishing %d photos to Apple Photos', nPhotos),
    })

    -- Render Exports
    local renditions = {}
    for i, rendition in exportContext:renditions({ stopIfCanceled = true }) do
        if progressScope:isCanceled() then
            break
        end
        progressScope:setPortionComplete(i - 1, nPhotos)

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
    if #renditions == 0 or progressScope:isCanceled() then
        return
    end

    -- Import into Apple Photos
    local catalog = LrApplication.activeCatalog()
    local oldIdentifiers = importPhotoBatch(progressScope, renditions, catalog)
    deleteOldVersions(progressScope, oldIdentifiers)

    progressScope:done()
end

--- Called when the user removes photos from a published collection.
--- Deletes the photos from Apple Photos, clears plugin metadata
--- (photosLocalIdentifier and photosSyncDate) from the catalog, and
--- notifies Lightroom of each successful deletion via deletedCallback.
--- @param publishSettings table Current publish settings
--- @param photoIDs table Array of Apple Photos local identifiers to delete
--- @param deletedCallback function Called with each photoID after successful deletion
--- @param localCollectionID number Lightroom local identifier for the published collection
function provider.deletePhotosFromPublishedCollection(publishSettings, photoIDs, deletedCallback,
                                                      localCollectionID)
    if #photoIDs == 0 then
        return
    end

    logger:info('Deleting ' .. #photoIDs .. ' photos from published collection')
    local deleteResult = Importer.deletePhotos(photoIDs)

    if deleteResult.status == Importer.STATUS_SUCCESS then
        local photoIDSet = {}
        for _, id in ipairs(photoIDs) do
            photoIDSet[id] = true
        end

        local catalog = LrApplication.activeCatalog()
        local collection = catalog:getPublishedCollectionByLocalIdentifier(localCollectionID)
        if collection then
            local publishedPhotos = collection:getPublishedPhotos()
            catalog:withWriteAccessDo('Clear Photos metadata', function()
                for _, publishedPhoto in ipairs(publishedPhotos) do
                    if photoIDSet[publishedPhoto:getRemoteId()] then
                        local photo = publishedPhoto:getPhoto()
                        photo:setPropertyForPlugin(_PLUGIN, PROP_LOCAL_IDENTIFIER, nil)
                        photo:setPropertyForPlugin(_PLUGIN, PROP_SYNC_DATE, nil)
                    end
                end
            end)
        end

        for _, photoID in ipairs(photoIDs) do
            deletedCallback(photoID)
        end
        logger:info('Deleted ' .. deleteResult.deletedCount .. ' photos')
    else
        local errorMsg = deleteResult.errorMessage or deleteResult.errorCode or 'Delete failed'
        logger:error('Failed to delete photos: ' .. errorMsg)
        error(errorMsg)
    end
end

return provider
