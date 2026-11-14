--[[
    Formats

    The output formats a collection can publish in.

    A photo has one asset in Photos for each format it is published in, not one for each
    collection. Collections that share a format share the asset, so a photo in three JPEG
    albums is rendered and imported once. Collections in different formats cannot share one,
    because the file is the asset: a photo in a JPEG album and a TIFF album is two assets.

    Everything about the output apart from the format is fixed, so the format alone decides
    whether two collections can share. Adding one takes an entry here and a metadata field
    in PhotosMetadataDefinition.lua for the identifier to be recorded under.
]]

local M = {}

--- The format the publish service renders itself, and the one a collection publishes in
--- until it is given another.
M.DEFAULT = 'JPEG'

--- Collection setting the format is stored under.
M.SETTING = 'format'

--- Output settings every format shares.
--- Metadata is embedded in full because Photos reads title, caption, keywords, location and
--- date from the file.
local SHARED_SETTINGS = {
    LR_export_colorSpace = 'sRGB',
    LR_size_doConstrain = false,
    LR_outputSharpeningOn = false,
    LR_includeFaceTagsInIptc = true,
    LR_metadata_keywordOptions = 'flat',
    LR_embeddedMetadataOption = 'all',
    LR_removeLocationMetadata = false,
    LR_useWatermark = false,
}

--- The formats on offer, in the order the menu lists them.
local FORMATS = {
    {
        id = 'JPEG',
        title = 'JPEG',
        -- Carries no suffix because it predates the others: every asset published before
        -- formats existed is a JPEG recorded under this key.
        property = 'photosLocalIdentifier',
        settings = {
            LR_format = 'JPEG',
            LR_jpeg_quality = 1,
            LR_jpeg_useLimitSize = false,
        },
    },
    {
        id = 'JXL',
        title = 'JPEG XL',
        property = 'photosLocalIdentifierJXL',
        settings = {
            LR_format = 'JXL',
            -- Full quality the way the JPEG is: the most the lossy encoder gives. Lossless
            -- is a separate switch, left off because TIFF is there for that and a lossless
            -- file is several times the size.
            LR_jxl_quality = 1,
            LR_jxl_losslessQuality = false,
            -- Lightroom offers 8 or 16 here. The extra depth costs a lossy file next to
            -- nothing, and spares smooth gradients the banding 8 bits can give them.
            LR_export_bitDepth = 16,
        },
    },
    {
        id = 'TIFF',
        title = 'TIFF',
        property = 'photosLocalIdentifierTIFF',
        settings = {
            LR_format = 'TIFF',
            LR_export_bitDepth = 16,
            -- LZW is not offered at 16 bits, and uncompressed files are twice the size for
            -- the same pixels.
            LR_tiff_compressionMethod = 'compressionMethod_ZIP',
        },
    },
}

local BY_ID = {}
for _, format in ipairs(FORMATS) do
    BY_ID[format.id] = format
end

--- A format name that is safe to act on.
---
--- Anything unrecognized is the default, which covers both a collection that has never had
--- the setting and one saved by a version that knew a format this one does not.
---
--- @param value any A stored setting, or nil
--- @return string A format name
function M.resolve(value)
    if value and BY_ID[value] then
        return value
    end
    return M.DEFAULT
end

--- Every format name, in menu order.
--- @return table Array of format names
function M.names()
    local names = {}
    for _, format in ipairs(FORMATS) do
        table.insert(names, format.id)
    end
    return names
end

--- The format a collection publishes in.
--- @param collection LrPublishedCollection
--- @return string A format name
function M.forCollection(collection)
    local summary = collection:getCollectionInfoSummary()
    local settings = summary and summary.collectionSettings
    return M.resolve(settings and settings[M.SETTING])
end

--- The plugin metadata key a photo's asset in this format is recorded under.
--- @param format string|nil A format name
--- @return string
function M.property(format)
    return BY_ID[M.resolve(format)].property
end

--- The export settings that render this format, as a table the caller may add to.
--- @param format string|nil A format name
--- @return table Lightroom export settings
function M.exportSettings(format)
    local settings = {}
    for key, value in pairs(SHARED_SETTINGS) do
        settings[key] = value
    end
    for key, value in pairs(BY_ID[M.resolve(format)].settings) do
        settings[key] = value
    end
    return settings
end

--- The formats as popup menu items.
--- @return table Array of {title, value}
function M.menuItems()
    local items = {}
    for _, format in ipairs(FORMATS) do
        table.insert(items, { title = format.title, value = format.id })
    end
    return items
end

return M
