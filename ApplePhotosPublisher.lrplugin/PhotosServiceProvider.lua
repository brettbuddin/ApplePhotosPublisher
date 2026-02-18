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

local PROP_LOCAL_IDENTIFIER = 'photosLocalIdentifier'
local PROP_SYNC_DATE = 'photosSyncDate'

local provider = {}

provider.canExportToTemporaryLocation = true
provider.supportsIncrementalPublish = 'only'
provider.hideSections = {
    'exportLocation',
    'fileNaming',
    'postProcessing',
}
provider.allowFileFormats = { 'JPEG' }

-- Allow any color space by emptying allowed color spaces.
provider.allowColorSpaces = nil

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

function provider.getCollectionBehaviorInfo(publishSettings)
    return {
        defaultCollectionName = 'Apple Photos',
        defaultCollectionCanBeDeleted = false,
        canAddCollection = true,
        maxCollectionSetDepth = 0,
    }
end

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
