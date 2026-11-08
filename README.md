<img src="ApplePhotosPublisher.lrplugin/resources/icon-large.png" width="128" alt="ApplePhotosPublisher icon">

# ApplePhotosPublisher

Lightroom Classic Publish Service plugin for Apple Photos. Publish photos to Apple Photos and republish to update them with new edits. Published collections appear as albums in Apple Photos, and collection sets appear as folders. Album memberships and favorite status in Apple Photos is preserved when images are republished, but all edits are replaced.

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

### Albums and Folders

Collections you add are mirrored as albums in Apple Photos, and collection sets become folders, so the shape of the Publish Services panel carries over.

The built-in **Apple Photos** collection is the exception and gets no album. Publishing there means "put this in my Photos library without filing it anywhere". Use it for photos you want in Photos but not organized, and use collections for the ones you want gathered into albums.

Renaming a collection renames its album. Deleting one deletes the album but keeps the photos, unless no other collection still publishes them. Dragging a collection into a folder moves its album to match.

A photo added to a second collection keeps the asset it already has rather than being imported again, so both albums show the same photo and neither collection is left pointing at a replaced version.

Album deletion goes through the same macOS confirmation dialog as photo deletion, so deleting a collection asks before changing anything in Photos. Declining leaves Photos untouched and Lightroom offers to undo the change.

### Reconciling Albums

Lightroom only reports what changed, so an album can drift out of step with its collection: one created for a collection whose photos were published earlier starts out empty, and editing an album directly in Photos is invisible to Lightroom.

**Library > Plug-in Extras > Reconcile Apple Photos Albums** sets each album's photos to exactly what its collection holds. It reconciles the published collections selected in the panel, or every one of them when nothing is selected.

### Removing Photos

Removing a photo from a collection takes it out of that collection's album. The photo is only deleted from Apple Photos once no collection in the service still publishes it, so moving a photo between albums never destroys it.

That gives two outcomes worth knowing. A photo published only through a collection, removed from it, is deleted from Apple Photos. The same photo also in the **Apple Photos** collection is kept instead, and simply becomes an unfiled photo in your library.

Moving an album in Photos is up to you and does not break anything. Lightroom decides where an album is first created, from the collection's place in the panel, and leaves it alone afterwards.

### Photos Library Access

The first time you publish, macOS asks whether **Apple Photos Publisher for Lightroom Classic** may access your Photos library. Choose **Full Access**. The plugin's bundled helper app owns this permission. It requires access to previously published photos and their albums so it can replace photos and preserve album memberships.

macOS only asks once. If you chose Limited Access or Don't Allow, publishing fails with a dialog explaining the fix: open System Settings > Privacy & Security > Photos, set **Apple Photos Publisher for Lightroom Classic** to Full Access, then retry publishing in Lightroom Classic.

To repeat the permission prompt, wait for any publish operation to finish, quit Lightroom, and run this in Terminal to reset only the helper's Photos permission:

```sh
tccutil reset Photos org.buddin.lrphotossync.lrphotosimporter
```

Reopen Lightroom and publish a photo through Apple Photos Publisher to trigger a new request, then choose **Full Access**. The reset does not grant access itself. If macOS reports that the bundle identifier is unknown, launch the helper by publishing once before trying the reset. If no prompt appears, check the plugin log at `~/Library/Logs/Adobe/Lightroom/LrClassicLogs/ApplePhotosPublisher.log` for an importer failure; resetting permissions cannot fix a helper that fails before requesting access.

Older versions ran the importer directly under Lightroom. Any existing Lightroom Photos permission is separate from the helper's permission; the updated plugin may ask for access again.

### Delete Confirmation Dialog

When removing or republishing photos, macOS will present a system confirmation dialog asking permission to delete from Apple Photos. This is a PhotoKit requirement enforced by Apple; apps cannot silently delete photos from the user's library. The dialog is expected and unavoidable.
