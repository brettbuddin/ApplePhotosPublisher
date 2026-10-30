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

### Photos Library Access

The first time you publish, macOS asks whether Lightroom Classic may access your Photos library. Choose **Full Access**. The plugin requires access to previously published photos and their albums so it can replace photos and preserve album memberships.

macOS only asks once. If you chose Limited Access or Don't Allow, publishing fails with a dialog explaining the fix: open System Settings > Privacy & Security > Photos, set Lightroom Classic to Full Access, then quit and reopen Lightroom Classic.

If Lightroom Classic is missing from the Photos list, quit Lightroom and run this in Terminal to reset only its Photos permission:

```sh
tccutil reset Photos com.adobe.LightroomClassicCC7
```

Reopen Lightroom and publish a photo through Apple Photos Publisher to trigger a new request, then choose **Full Access**. The reset does not grant access itself. If no prompt appears, check the plugin log at `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/ApplePhotosPublisher.log` for an importer failure; resetting permissions cannot fix a helper that fails before requesting access.

### Delete Confirmation Dialog

When removing or republishing photos, macOS will present a system confirmation dialog asking permission to delete from Apple Photos. This is a PhotoKit requirement enforced by Apple; apps cannot silently delete photos from the user's library. The dialog is expected and unavoidable.
