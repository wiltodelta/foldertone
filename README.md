# Foldertone

A simple iOS player for your own audio files. A folder becomes a playlist.

## Listening flow

1. Choose a music folder through the system Files picker.
2. Its audio files, including every nested subfolder, appear in one flat playlist.
3. Press **Play all** or **Shuffle**. The compact player stays at the bottom; tap it for playback position, repeat, and the queue.

Each connected folder has a separate playlist. Choose among them with the playlist selector. Selecting one audio file starts it playing after its local copy is ready and does not create a playlist. Audio files can also open in Foldertone through the system document-opening flow.

The app supports multiple files and folders from On My iPhone, iCloud Drive, and connected Files providers, subject to the access those providers expose. It remembers the selected sources and playlist. Use Sources in the toolbar or Manage Sources in the playlist menu to rename, reconnect, or disconnect a source. Disconnecting leaves the original files in Files and keeps tracks shared with other sources.

## Playback and metadata

The AVFoundation player handles MP3, FLAC, AAC/M4A, ALAC, WAV, and AIFF. The test bundle includes real synthetic samples for these codecs, including tagged MP3, FLAC, AAC, and ALAC. Codec decoding and tags are checked separately from physical-device playback.

Track titles, artists, albums, and embedded covers are read from file metadata. A file without a title uses its filename. A file without cover art gets the built-in placeholder. Covers are downsampled for display. The reader uses the full AVFoundation metadata collection so Vorbis text tags in FLAC are included, with a bounded RFC 9639 PICTURE parser for embedded FLAC covers that AVFoundation omits.

Shuffle builds an order containing each track once. Repeat can be off, repeat the playlist, or repeat one track. The player supports seeking, previous/next, an editable playback position through lock screen commands, background audio, and a visible **Up next** queue. Source changes update a playing playlist’s queue as well as its visible tracks.

## Folder synchronization

Adding, deleting, renaming, moving, and replacing music anywhere in a connected folder updates its flat playlist. The index stores a complete snapshot for each source. Overlapping folder and individual-file selections share tracks without duplicating them in the combined library. Matching audio moved within the same folder tree retains its track identity and offline copy; filename-based titles update after a rename.

The app subscribes to `NSFilePresenter` changes while in the foreground, coalesces bursts into one sync, and performs a full reconciliation when returning to the foreground. There is no periodic folder polling. Pending iCloud downloads get temporary file observers so completion can trigger import. An explicit file-change notification invalidates that file’s cached fingerprint even when its size and modification date are unchanged. Pull down to request an immediate retry.

A successful complete scan removes missing tracks. A failed root or incomplete directory traversal keeps the previous snapshot; temporary loss of access is not treated as deletion. If an existing file cannot be decoded, its last playable copy is kept and the source status reports the failure. Unused local audio and cover copies are cleaned up after playback state is reconciled. Local copies and the index are excluded from iCloud Backup because the originals stay in Files. Original files are only read.

Previously saved single-folder bookmarks, multi-source bookmarks, and the original array-based track index are migrated. Their tracks remain available if a source is unavailable during the first reconciliation.

## Run

Open `Foldertone.xcodeproj` in Xcode, choose scheme `Foldertone` and an iPhone simulator, then run. The deployment target is iOS 17.0. The app has no external dependencies or environment variables.

The project uses automatic signing with development team `K2GT9Q4S6U` for the app and test targets. An iPhone build requires an Apple Development signing identity and a matching provisioning profile for the selected device. Sign in to this team in Xcode Settings > Apple Accounts, connect the iPhone, and select it as the run destination so Xcode can manage the profile. Signing is not required for a simulator build.

## App icon

The icon follows the other apps’ visual style: a violet vertical gradient, a white glass folder, and one purple Play symbol. `scripts/draw-icon.py` generates the closed SVG layers and `Foldertone/AppIcon.icon` document. Regenerate with `python3 scripts/draw-icon.py`; edit the generator rather than its output. Xcode compiles the layered icon and fallback images for the existing deployment target.

## Verify

```sh
scripts/check-ui.sh
```

The runner creates a unique device from an installed iOS runtime, runs without opening Simulator.app, and deletes only its own device afterward. Use `--dry-run` to inspect the selection, `--only-testing FoldertoneUITests/FoldertoneUITests/testEmptyLibraryAndMusicPicker` for a focused UI check, and `--out PATH` to retain logs and the result bundle in a chosen folder. `IOS_UI_RUNNER` overrides the shared runner path. `FoldertoneTests` covers recursive synchronization, source failures, legacy migration, cache safety, folder playlists, single-file routing, codec metadata, event delivery, shuffle, repeat, and queue reconciliation. Run `scripts/check-engine.sh` for isolated macOS engine checks using the same shared scenarios. An optional scenario name limits the check, for example `scripts/check-engine.sh formats`. It creates and removes its own temporary workspace and never uses a personal music folder. The UI tests cover the system picker and playback flows. See [verification status](docs/verification.md) for completed and blocked checks.

For a populated simulator preview, add `--sample-library` to the scheme's launch arguments. This Debug-only option creates synthetic tones without personal music or an iCloud account.

## Release

See the [App Store release procedure](docs/release.md) and the [privacy policy](docs/privacy.md).

## Device behavior

File presenters are unregistered when the app enters the background, as required by iOS. Reopening the app reconciles changes made while it was suspended. Background audio operates separately from source monitoring. File-provider notification delivery, security-scoped bookmark persistence, iCloud downloads, lock screen commands, and accessory playback need verification on an iPhone.

Apple references: [file presenters](https://developer.apple.com/documentation/foundation/nsfilepresenter), [iOS presenter lifecycle](https://developer.apple.com/documentation/foundation/nsfilecoordinator), [directory access](https://developer.apple.com/documentation/uikit/providing-access-to-directories), [media metadata](https://developer.apple.com/documentation/avfoundation/retrieving-media-metadata), and [background playback](https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback).
