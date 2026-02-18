--[[
    Lightroom Classic Plugin: Apple Photos Publisher

    Publish service for Apple Photos. Publishes photos from Lightroom Classic
    to Apple Photos, preserving album memberships and favorite status on
    republish.

    Photos are rendered as full-quality JPEGs and imported into Apple Photos
    via the bundled lrphotosimporter binary. The Apple Photos identifier for
    each photo is stored as plugin metadata in the Lightroom catalog.

    Author: Brett Buddin <brett@buddin.org>
    Version: 1.0.0
]]

return {
    LrSdkVersion = 10.0,
    LrSdkMinimumVersion = 6.0,
    LrToolkitIdentifier = 'org.buddin.lrphotossync',
    LrPluginName = 'Apple Photos Publisher',
    LrPluginInfoUrl = 'https://github.com/brettbuddin/ApplePhotosPublisher',
    LrInitPlugin = 'PluginInit.lua',
    LrMetadataProvider = 'PhotosMetadataDefinition.lua',

    LrExportServiceProvider = {
        title = 'Apple Photos',
        file = 'PhotosServiceProvider.lua',
        small_icon = 'resources/icon.png',
    },
    LrPublishServiceProvider = {
        title = 'Apple Photos',
        file = 'PhotosServiceProvider.lua',
        small_icon = 'resources/icon.png',
    },

    VERSION = {
        major = 1,
        minor = 0,
        revision = 0,
    },
}
