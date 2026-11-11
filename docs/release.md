# App Store release

The procedure for shipping Foldertone. Current verification evidence lives in [verification.md](verification.md); limits and required fields come from Apple's live App Store Connect help, not from this file.

## Before each release

1. Confirm `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `Foldertone.xcodeproj/project.pbxproj`. Every upload needs a new build number.
2. Run `scripts/check-engine.sh` and the XCTest suite from `README.md`.
3. Archive Release locally and inspect the result:

   ```sh
   xcodebuild archive -project Foldertone.xcodeproj -scheme Foldertone \
     -configuration Release -destination 'generic/platform=iOS' \
     -archivePath "$TMPDIR/Foldertone.xcarchive"
   ```

   The archive must contain `PrivacyInfo.xcprivacy` and a dSYM, and its executable must not contain `--sample-library`, `--sample-file`, or `--empty-library`.
4. Recheck `Foldertone/PrivacyInfo.xcprivacy` whenever the app starts using another required-reason API or any data leaves the device. File timestamps use reason `3B52.1` because the app reads only user-selected items. User defaults use `CA92.1`.
5. Run the physical checks below on the build being submitted.

## Physical checks

These depend on real hardware and accounts, so simulator results do not count.

- Connect a folder from iCloud Drive, On My iPhone, and each other provider being advertised. Force quit, relaunch, and confirm access survives.
- Choose an iCloud folder whose files are not downloaded. Confirm they download and appear.
- Add, rename, move into a subfolder, and delete a file from the Files app. Confirm the playlist follows.
- Lock the phone during playback. Confirm background audio, lock screen play, pause, previous, next, and seeking.
- Test headphones or CarPlay controls where available.
- Check VoiceOver and Reduce Transparency on the main flow.

## App Store Connect

An Account Holder or Admin completes these once:

- Register the explicit bundle ID `app.foldertone` and create the app record.
- Sign with Xcode-managed distribution: an export with `-allowProvisioningUpdates` uses a cloud-managed Apple Distribution certificate, so no local distribution identity is needed.
- Complete agreements and EU trader status. Foldertone 1.0 is a free, iPhone-only app.
- Answer Content Rights, the age rating questionnaire, and App Privacy data collection yourself: they are legal declarations of the account holder, so an agent fills the rest of the listing but not these. An agent pressed Submit for Review for 1.1.0 at the account holder's explicit request; for 1.0.0 the account holder pressed it.
- Keep the policy from `docs/privacy.md` live at `https://wiltodelta.com/projects/foldertone/privacy/` and the support page at `https://wiltodelta.com/projects/foldertone/support/`. Both are served by the `wiltodelta-app` site and linked from the app's empty library and Sources sheet, as Guideline 5.1.1 requires.

## Listing

- **Name:** Foldertone
- **Subtitle:** Your folders, your playlists
- **Category:** Music; secondary Productivity
- **Support URL:** `https://wiltodelta.com/projects/foldertone/support/`
- **Marketing URL:** `https://wiltodelta.com/projects/foldertone/`
- **Copyright:** 2026 Victor Kuznetsov
- **Availability:** iPhone only; Apple silicon Mac and Apple Vision Pro distribution is turned off.
- **Keywords:** audio player,flac,mp3,alac,folder,playlist,files,icloud drive,local music,offline
- **App Privacy:** Data Not Collected. Tracking: No.
- **Encryption:** `ITSAppUsesNonExemptEncryption` is `NO`.

**Description:**

```text
Foldertone plays the audio files you already own. Choose a folder in Files and it becomes a playlist, with every track from its subfolders in one flat list.

Add, rename, move, or delete music in that folder and the playlist follows. Changes appear as they happen while the app is open, and when you come back to it.

- Folders and songs from iCloud Drive, On My iPhone, and other Files locations
- MP3, FLAC, AAC/M4A, ALAC, WAV, and AIFF
- Titles, artists, albums, and cover art read from your files
- Shuffle, repeat, and a visible Up next queue
- Background playback and lock screen controls
- Open a single song and it starts playing, without creating a playlist

Foldertone only reads your music. It never changes or deletes your original files. No account, no ads, no tracking.
```

**Notes for App Review:**

```text
Foldertone plays audio files the user already has. It has no account or server, and it opens with an empty library until music is chosen.

To review: unzip the attached Foldertone Sample Music folder into Files (On My iPhone or iCloud Drive), tap + in Foldertone, and choose that folder. It becomes one playlist, including its subfolders. Press Play all, then tap the mini-player for the full player, shuffle, repeat, and Up next. Adding or deleting a file in that folder updates the playlist.

Background audio is used only to continue playback of the user's chosen music. The sample files are synthetic tones created for testing.
```

Attach or link a small sample set generated from `FoldertoneTests/Fixtures`, because a review device may have no audio files.

## Screenshots

Capture them last, from the submitted build, using the Debug-only `--sample-library` launch argument described in `README.md`. Use the iPhone device classes App Store Connect currently requires. The project targets iPhone only, so no iPad set is needed.

## Personal website

Update `wiltodelta.com/projects/foldertone/` at every release, as `CLAUDE.md`, "Personal website", describes.

## Upload

Upload from Xcode Organizer after the checks above pass on the exact archive. Tag the release only after that exact commit passes, and never reuse a tag once a build is public.
