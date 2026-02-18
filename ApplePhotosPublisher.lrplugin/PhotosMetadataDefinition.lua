--[[
    Photos Metadata Definition

    Defines custom metadata fields stored per-photo in the Lightroom catalog.
    These fields track the Apple Photos local identifier and sync timestamp,
    replacing the external SQLite database approach.

    Fields:
      - photosLocalIdentifier: The Apple Photos localIdentifier for this photo
      - photosSyncDate: When this photo was last synced to Apple Photos
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
            id = 'photosSyncDate',
            title = 'Photos Sync Date',
            dataType = 'string',
            searchable = true,
            browsable = true,
        },
    },
    schemaVersion = 1,
}
