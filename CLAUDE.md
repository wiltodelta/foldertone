Act as a principal iOS engineer building Foldertone, a music player for files and folders selected through iOS Files.

## Project scope

- Read `README.md` for the product goal and initial scope.
- Open `Foldertone.xcodeproj`, scheme `Foldertone`. The deployment target is iOS 17.0; there are no external dependencies.
- `FolderImporter` persists per-source synchronization snapshots and coordinates read-only access. `MusicLibrary` owns observable library state; `MusicPlayer` owns AVPlayer and remote commands.
- Follow `docs/product.md` for folder playlists, single-file playback, metadata, and queue behavior.
- Follow `~/Documents/GitHub/claude-config/docs/ios-apps.md` for the shared native iOS appearance and accessibility conventions.
- Follow `docs/release.md` for App Store releases; keep `Foldertone/PrivacyInfo.xcprivacy` and `docs/privacy.md` true to the code.
- Use the checks in `README.md`; `scripts/check-engine.sh` runs shared scenarios in an isolated temporary home. Sample playback hooks are Debug-only; codec fixtures are synthetic.
- UI tests launch the app only through their `launch` helper, which adds `--isolated-storage`, so a run on the owner's iPhone never touches the real library.
- `scripts/check-ui.sh` boots a fresh simulator every run, and first-boot migration can exceed five minutes, so run even a focused check detached.
- Preserve the one-screen library and native multi-selection file and folder picker. Keep file presenters active only in the foreground; background audio is separate. Use events and foreground reconciliation rather than periodic polling.
- Validate file and folder permissions across Files providers, cloud downloads, and physical playback controls on an iPhone; simulator success does not prove these behaviors.
- `scripts/draw-icon.py` generates `Foldertone/AppIcon.icon`; change its geometry and appearance in the generator, never in the generated layers.

## Personal website

The personal website (`wiltodelta/wiltodelta-app`, page `/projects/foldertone/`, plus the `privacy/` and `support/` pages the app links to) shows a library screenshot in both appearances, taken from `screenshots/library.png` and `library-dark.png`. At every release, regenerate them with `scripts/capture-screenshots.sh` when the pictured UI changed, never rename or remove them without updating that repository in the same change, and follow its `docs/product-updates.md`, "What product repositories owe the site".

Website copy highlights only the main use cases and benefits; follow the site's `docs/product-updates.md`, "Visitor copy selection".
