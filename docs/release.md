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

   The archive must contain `PrivacyInfo.xcprivacy` and a dSYM, and its executable must not contain any Debug launch argument; `scripts/release.sh` checks all three.
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

- Register the explicit bundle ID `com.wiltodelta.foldertone` and create the app record; [verification.md](verification.md) records why the earlier `app.foldertone` record was retired.
- Sign with Xcode-managed distribution: an export with `-allowProvisioningUpdates` uses a cloud-managed Apple Distribution certificate, so no local distribution identity is needed.
- Complete agreements and EU trader status. Foldertone 1.0 is a free, iPhone-only app.
- China mainland stays unavailable until the Security Assessment and the AI-generated content declaration in App Compliance are filed; without them App Store Connect refuses to submit a version available there.
- Answer Content Rights, the age rating questionnaire, and App Privacy data collection yourself: they are legal declarations of the account holder, so an agent fills the rest of the listing but not these. An agent pressed Submit for Review for 1.1.0 at the account holder's explicit request; for 1.0.0 the account holder pressed it.
- Keep the policy from `docs/privacy.md` live at `https://wiltodelta.com/projects/foldertone/privacy/` and the support page at `https://wiltodelta.com/projects/foldertone/support/`. Both are served by the `wiltodelta-app` site and linked from the app's empty library and Sources sheet, as Guideline 5.1.1 requires.

## Listing

The App Store page lives in `metadata/`: `metadata/locales/<locale>.json` holds the name, subtitle, description and keywords of each App Store Connect locale, with `en-US.json` as the source the translations follow, and `metadata/whats-new.json` holds the release notes of every locale but en-US, whose notes come from the tag. `scripts/asc.py` writes all of them at release; there is no other copy of the page text. The app's Kazakh, Lithuanian and Hong Kong Chinese have no App Store locale of their own (Hong Kong reads `zh-Hant`), and the English storefronts other than the U.S. show `en-US`. The locale codes of the eleven languages App Store Connect added on 2026-03-31 (`bn-BD`, `gu-IN`, `kn-IN`, `ml-IN`, `mr-IN`, `or-IN`, `pa-IN`, `sl-SI`, `ta-IN`, `te-IN`, `ur-PK`) come from fastlane's list; App Store Connect accepted all of them with 1.4.1.

- **Category:** Music; secondary Productivity
- **Support, marketing and privacy URLs:** the constants at the top of `scripts/asc.py`, the same in every locale.
- **Copyright:** 2026 Victor Kuznetsov
- **Availability:** iPhone only; Apple silicon Mac and Apple Vision Pro distribution is turned off.
- **App Privacy:** Data Not Collected. Tracking: No.
- **Encryption:** `ITSAppUsesNonExemptEncryption` is `NO`.

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

`wiltodelta.com/projects/foldertone/` deploys the release's screenshots and README section by itself on the site's next scheduled refresh after the GitHub release. Regenerate those screenshots before tagging when the pictured UI changed, as `CLAUDE.md`, "Personal website", describes; catalog copy on the site still changes by hand.

## Upload and submit

`scripts/release.sh` runs the release through the App Store Connect API, so no Xcode or browser sign-in is needed:

1. Bump `MARKETING_VERSION` or `CURRENT_PROJECT_VERSION`, commit, and push. Wait for CI to pass on that commit.
2. Tag it: `git tag -a vX.Y.Z` with "Foldertone X.Y.Z" as the subject and the What's New text as the body, then push the tag. Translate that text into every locale of `metadata/whats-new.json` and set its `version` to X.Y.Z in the commit being tagged; the release refuses notes written for another version.
3. Run `scripts/release.sh --dry-run`. It refuses a dirty tree, a tag that is not on HEAD or not annotated, and a commit without passing CI; it first reads App Store Connect and logs every write it would make, then archives and checks the archive.
4. Run `scripts/release.sh`, which repeats that read-only check before building, to upload, create or reuse the App Store version (App Store Connect keeps one unreleased version, so a version pulled from review or rejected is renamed to the new number), write the page of every locale in `metadata/` with What's New from the tag and `metadata/whats-new.json` (App Store Connect has none for an app's first version, so it is skipped there), write the name and subtitle of every locale into the new version's app information, wait for processing, attach the build and prepare the review submission. Add `--submit` to send it.

The GitHub release follows the App Store on its own: `.github/workflows/publish-release.yml` runs on the schedule in its `cron` line (GitHub delays and skips scheduled runs, so the wait varies), reads the live version from the public iTunes Lookup API, and when tag `vX.Y.Z` has no GitHub release yet, `scripts/publish_release.py` publishes one titled with the tag subject and described by the tag body. It needs no App Store Connect key. Run it at once from the Actions tab (`gh workflow run publish-release.yml`), or locally with `GH_TOKEN=$(gh auth token) uv run --script scripts/publish_release.py --dry-run`. A failed run means the live version has no annotated tag. `scripts/release.sh` re-enables the workflow after an upload, because GitHub disables a public repository's schedules after 60 days without activity.

The personal website then follows on its own, as described above. Never reuse a tag once a build is public.

### API key

`scripts/release.sh` and `scripts/asc.py` read `ASC_KEY_ID`, `ASC_ISSUER_ID` and optionally `ASC_KEY_PATH` from `.env` (see `.env.example`). The key is the App Store Connect team key "Foldertone release admin" with the Admin role, created under Users and Access > Integrations > Team Keys; an App Manager key reads and prepares versions but fails App Store export with "Cloud signing permission error", so the Admin role is required for signing and upload; its `.p8` file lives at `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8` with mode 600 and never enters the repository. `uv run --script scripts/asc.py check` confirms that the key can read the app. `uv run --script scripts/test_asc.py`, also run by CI, proves that a dry run sends no writes and that only `--submit` sends the submission.
