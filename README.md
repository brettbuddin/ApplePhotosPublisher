<img src="ApplePhotosPublisher.lrplugin/resources/icon-large.png" width="128" alt="ApplePhotosPublisher icon">

# ApplePhotosPublisher

Lightroom Classic Publish Service plugin for Apple Photos. Publish photos to Apple Photos and republish to update them with new edits. Album memberships and favorite status in Apple Photos is preserved when images are republished, but all edits are replaced.

I use this plugin to manage edits shared with family and to have edits show up in Apple Photos Memories widgets across the ecosystem.

## Installation

### From Release

Download the latest release from the [Releases](https://github.com/brettbuddin/ApplePhotosPublisher/releases) page.

Place the `.lrplugin` file in `~/Library/Application Support/Adobe/Lightroom/Modules`. Restart Lightroom Classic and it should be ready to go.

### From Source

```sh
; git clone https://github.com/brettbuddin/ApplePhotosPublisher.git
; cd ApplePhotosPublisher
; script/release.sh --skip-sign --install
```

This builds a universal binary (arm64 + x86_64) and installs the plugin to Lightroom Classic. 

## Usage

1. In the **Publish Services** panel (bottom-left of Library module), click **Set Up** next to **Apple Photos**
2. Configure settings and click **Save**
3. Add photos to the publish collection, then click **Publish**

When publishing, the plugin renders photos as full-quality JPEGs and imports them into Apple Photos in a single batch. The Apple Photos identifier for each photo is stored as plugin metadata in the Lightroom catalog.

When republishing, album memberships and favorite status in Apple Photos are preserved and the old version is replaced. Changes to title, caption, keywords, GPS, date, or rating will mark a photo for republish.

Removing a photo from the publish collection deletes it from Apple Photos.

### Delete Confirmation Dialog

When removing or republishing photos, macOS will present a system confirmation dialog asking permission to delete from Apple Photos. This is a PhotoKit requirement enforced by Apple; apps cannot silently delete photos from the user's library. The dialog is expected and unavoidable.
