--[[
    Photos Metadata Definition

    Defines custom metadata fields stored per-photo in the Lightroom catalog.
    These fields track the Apple Photos local identifier and sync timestamp,
    replacing the external SQLite database approach.

    Fields:
      - photosLocalIdentifier: The Apple Photos localIdentifier for this photo's JPEG
      - photosLocalIdentifierJXL: The Apple Photos localIdentifier for this photo's JPEG XL
      - photosLocalIdentifierTIFF: The Apple Photos localIdentifier for this photo's TIFF
      - photosSyncDate: When this photo was last synced to Apple Photos

    A photo has one asset per output format, so there is an identifier field for each
    format in lib/Formats.lua. Adding a field means raising schemaVersion, which makes
    Lightroom offer to update the catalog the next time the plugin loads.
]]

return {
    metadataFieldsForPhotos = {
        {
            id = 'photosLocalIdentifier',
            title = 'Photos Identifier',
            dataType = 'string',
            searchable = true,
            browsable = true,
        },
        {
            id = 'photosLocalIdentifierJXL',
            title = 'Photos Identifier (JPEG XL)',
            dataType = 'string',
            searchable = true,
            browsable = true,
        },
        {
            id = 'photosLocalIdentifierTIFF',
            title = 'Photos Identifier (TIFF)',
            dataType = 'string',
            searchable = true,
            browsable = true,
        },
        {
            id = 'photosSyncDate',
            title = 'Photos Sync Date',
            dataType = 'string',
            searchable = true,
            browsable = true,
        },
    },
    schemaVersion = 2,
}
