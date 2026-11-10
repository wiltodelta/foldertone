# Verification

## Completed checks

The app and test bundles build for the iOS simulator. A signing-disabled Release device build also passes; this does not mean the app has been signed or installed on a physical iPhone.

The XCTest suite passes on a clean iPhone 17e simulator. The shared engine scenarios also pass through `scripts/check-engine.sh` in an isolated macOS home. Coverage includes:

- Recursive additions, removals, renames, moves into nested folders, replacement audio, and hidden subfolders.
- Independent source snapshots, offline roots, reconnecting sources, incomplete traversal, and unreadable existing files.
- Original bookmark and index migration, overlapping selections, persistent flat folder playlists, and single-file playback routing.
- Event-driven updates through actual coordinated filesystem writes, presenter registration and removal, foreground reconciliation, and edits that preserve file size and modification date.
- MP3, FLAC, AAC, ALAC, WAV, and AIFF decoding readiness, with embedded title, artist, album, and artwork in tagged formats.
- FLAC PICTURE decoding and rejection of truncated metadata.
- Shuffle without unintended repeats, repeat modes, queue reconciliation, and safe cleanup of unused local copies.
- Player metadata updates after a rename and clearing playback after removal.

The UI suite passes the system picker, playlist selection, search, real synthetic-file playback, pause, next track, shuffle, repeat, Play all keeping the player's shuffle mode, Up next, library restoration, and automatic single-file playback without a folder playlist. Screens were captured from the shipping iOS renderer and inspected in light and dark appearances. Maximum accessibility text size was also exercised; the single Play all button keeps its label on one line and playback controls stay anchored below scrolling content.

Temporary negative variants confirmed the scenarios detect disabled notifications, append-only retention, broken rename identity, erased offline snapshots, skipped subfolders, incomplete traversal treated as deletion, file-created playlists, lost single-file routing, missed cache cleanup, missing FLAC tags and covers, lost legacy identities, broken shuffle/repeat, incorrect persistence, incorrect cover dimensions, and ignored malformed metadata. A preserved-date overwrite failed before the notification invalidation fix and passed after it.

Test definitions are the source of truth: `FoldertoneTests/FoldertoneTests.swift` and `FoldertoneUITests/FoldertoneUITests.swift`. Regeneration of the synthetic codec samples is documented in `FoldertoneTests/Fixtures/README.md`.

## Release readiness

A local Release archive for version 1.0.0 builds with whole-module optimization and a dSYM. It contains `PrivacyInfo.xcprivacy` and none of the Debug launch arguments. It is signed with the development identity; App Store signing and upload have not been exercised. Engine scenarios cover the iCloud Backup exclusion on local playback storage, and that check fails without the exclusion.

Version 1.0 targets iPhone only. An iPad simulator run passed the test suite but showed a stretched phone layout, so iPad is deferred and the earlier iPad references in this file do not describe a supported device.

## Simulator recovery

The original test simulator failed iOS data migration. It was removed and replaced with a clean task-owned simulator. The common CoreSimulator service was not restarted. Successful checks supersede the earlier boot-blocked results.

## Development signing

The Apple Development certificate is installed with its matching private key and the Apple WWDR G3 intermediate certificate. The identity is valid for team `K2GT9Q4S6U`; signing a temporary executable and verifying it with `codesign --verify --strict` succeeds. The project uses this team for automatic signing.

The Debug device build passes with automatic provisioning after Apple Account sign-in in Xcode and registration of the intended iPhone. The finished app passes `codesign --verify --deep --strict`. Its signed application identifier is `K2GT9Q4S6U.app.foldertone`; the generated wildcard development profile permits that identifier and includes the intended iPhone. Installation on the intended iPhone succeeds after enabling Developer Mode and unlocking the device. CoreDevice launches `app.foldertone`, and the device process list confirms the Foldertone executable is running. Real-provider import and physical playback remain separate checks.

## Physical-device checks

Real Files-provider permission grants, access after relaunch, iCloud-only downloads, external drives and network providers, device lock screen commands, background audio, and accessories still need testing on an iPhone with the user's chosen providers. Simulator results do not establish those hardware and account behaviors.

## App icon

The folder-and-Play icon was inspected in Icon Composer in Default, Dark, and Mono appearances, including the small preview strip. The signed Debug iOS build passes with `AppIcon` as its primary icon. The built app includes `Assets.car` and fallback iPhone/iPad PNGs, and its signature verifies after asset compilation. Home Screen caching and other system appearances have not been verified on the physical iPhone.

## Liquid Glass controls

The signed Debug device build and strict Swift formatting check pass after adopting native glass controls. The updated build installs over the existing app without removing its connected sources. Physical iPhone inspection covers the library and mini-player in light and dark appearances, playlist selection, playback and pause, opening and closing the expanded player, and maximum accessibility text size. The final expanded player was inspected in both appearances after restoring the opaque control-panel backing and limiting icon-only control scaling; scrolling exposes the timeline without metadata overlapping the controls. System appearance and the app's launch-time text-size override are restored after verification.

The iOS 17–25 material and button fallbacks compile behind availability checks but have not been rendered on an older physical device in this pass. Xcode 27.2 reports iOS 17.5 and 18.6 simulator runtimes as not available for download, so they cannot be rendered on a simulator on this Mac either. That earlier pass did not cover Increased Contrast, Reduce Transparency, VoiceOver, or landscape. The audit-fix simulator pass below supersedes its landscape and interaction limitations.


## UI audit fixes

The audit fixes were checked on a task-owned iPhone 17e simulator running iOS 26.5. First-boot migration completed after roughly nine minutes, including CoreLocationMigrator. The shared CoreSimulator service was not restarted. A short boot timeout was not evidence of a deadlock.

The native XCTest suite and standalone engine scenarios pass with the source-management changes. The UI suite was adapted to native search and a navigation-bar-scoped player Close button. Source-management negative variants fail when friendly source names, saved aliases, empty-name validation, source-kind validation, duplicate-source rejection, reconnect bookmarks, shared memberships, last-source cleanup, or original-file preservation are deliberately broken.

Rendered checks cover native navigation and search, the selected playlist's menu checkmark, a restored playlist selection and source alias after relaunch, source renaming, cancellation of the reconnect Files picker, and disconnect confirmation. Disconnecting a synthetic source removes its catalogue entries while retaining its original files. Engine tests cover successful reconnect, overlapping source retention, and saved-source restoration.

Library and queue share the same track-row layout. At maximum accessibility size, queue artwork is hidden and the Cyrillic artist name wraps as two complete words rather than splitting the last word across several lines. Light and dark rendering were inspected, including the dark queue at maximum accessibility size with Increase Contrast enabled. The landscape player at the largest standard text size exposes metadata, album, timeline, timestamps, and all transport controls without clipping. Close is in the leading cancellation position. Shuffle and repeat-all have explicit black or white active dots inside their glass button content, in addition to tint and accessibility values.

Raw simulator screenshot sampling found that default secondary text was too faint on the light library background. An explicit adaptive label color with controlled opacity replaces it for supporting text. The measured artist foreground in the corrected light library exceeds the normal-text contrast threshold. Queue contrast and active-mode markers are checked from the actual rendered surfaces, rather than inferred from semantic color names.

The shared native iOS design baseline is `~/Documents/GitHub/claude-config/docs/ios-apps.md`. It documents navigation, glass controls, accessibility, and verification expectations for the app family.

This pass does not establish VoiceOver operation, Reduce Transparency behavior, iPad layouts, or rendering of the iOS 17–25 fallbacks. The physical-provider and hardware limitations above still apply. No further physical-device testing was performed after the user requested simulator-only verification.
